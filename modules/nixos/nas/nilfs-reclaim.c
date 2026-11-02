#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <nilfs.h>
#include <nilfs_gc.h>
#include <linux/nilfs2_ondisk.h>

#define SEGMENTS_PER_BATCH 2

struct drop {
	uint64_t ino;
	nilfs_cno_t lo, hi;
};

struct policy {
	struct drop *drops;
	size_t n;
};

static int drop_order(const void *a, const void *b)
{
	const struct drop *x = a, *y = b;

	if (x->ino != y->ino)
		return x->ino < y->ino ? -1 : 1;
	if (x->lo != y->lo)
		return x->lo < y->lo ? -1 : 1;
	return 0;
}

static int load_policy(const char *path, struct policy *p)
{
	FILE *f = fopen(path, "r");
	size_t cap = 0, merged = 0;
	struct drop d;

	if (!f)
		return -1;
	p->drops = NULL;
	p->n = 0;
	while (fscanf(f, "%" SCNu64 " %" SCNu64 " %" SCNu64, &d.ino, &d.lo, &d.hi) == 3) {
		if (d.ino < NILFS_USER_INO || d.lo >= d.hi) {
			fprintf(stderr, "nilfs-reclaim: bad policy line %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
				d.ino, d.lo, d.hi);
			fclose(f);
			errno = EINVAL;
			return -1;
		}
		if (p->n == cap) {
			cap = cap ? cap * 2 : 1024;
			p->drops = realloc(p->drops, cap * sizeof(*p->drops));
			if (!p->drops) {
				fclose(f);
				return -1;
			}
		}
		p->drops[p->n++] = d;
	}
	if (ferror(f) || !feof(f)) {
		fclose(f);
		errno = EINVAL;
		return -1;
	}
	fclose(f);
	qsort(p->drops, p->n, sizeof(*p->drops), drop_order);
	for (size_t i = 0; i < p->n; i++) {
		struct drop *last = merged ? &p->drops[merged - 1] : NULL;

		if (last && last->ino == p->drops[i].ino && p->drops[i].lo <= last->hi) {
			if (p->drops[i].hi > last->hi)
				last->hi = p->drops[i].hi;
		} else {
			p->drops[merged++] = p->drops[i];
		}
	}
	p->n = merged;
	return 0;
}

static int snapshot_within(const nilfs_cno_t *ss, size_t nss, nilfs_cno_t lo, nilfs_cno_t hi)
{
	size_t low = 0, high = nss;

	while (low < high) {
		size_t mid = low + (high - low) / 2;

		if (ss[mid] < lo)
			low = mid + 1;
		else
			high = mid;
	}
	return low < nss && ss[low] < hi;
}

static int retained(uint64_t ino, nilfs_cno_t start, nilfs_cno_t end,
		    const nilfs_cno_t *ss, size_t nss, void *arg)
{
	const struct policy *p = arg;
	size_t low = 0, high = p->n;
	nilfs_cno_t at = start;

	while (low < high) {
		size_t mid = low + (high - low) / 2;

		if (p->drops[mid].ino < ino)
			low = mid + 1;
		else
			high = mid;
	}
	for (size_t i = low; i < p->n && p->drops[i].ino == ino && at < end; i++) {
		const struct drop *d = &p->drops[i];

		if (d->hi <= at)
			continue;
		if (d->lo > at && snapshot_within(ss, nss, at, d->lo < end ? d->lo : end))
			return 1;
		at = d->hi;
	}
	return at < end && snapshot_within(ss, nss, at, end);
}

static void quiet_logger(int priority, const char *fmt, ...)
{
	va_list args;

	if (priority > LOG_WARNING)
		return;
	va_start(args, fmt);
	fputs("nilfs-reclaim: ", stderr);
	vfprintf(stderr, fmt, args);
	fputc('\n', stderr);
	va_end(args);
}

static void usage(void)
{
	fputs("usage: nilfs-reclaim [--dry-run] --policy FILE --protcno CNO DEVICE SEGNUM...\n", stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	static const struct option options[] = {
		{ "dry-run", no_argument, NULL, 'n' },
		{ "policy", required_argument, NULL, 'p' },
		{ "protcno", required_argument, NULL, 'c' },
		{ NULL, 0, NULL, 0 },
	};
	const char *policy_path = NULL;
	nilfs_cno_t protcno = 0;
	struct nilfs_reclaim_stat total = { 0 };
	struct policy policy;
	struct nilfs *nilfs;
	uint64_t *segnums;
	size_t nsegs;
	int dryrun = 0, opt;

	while ((opt = getopt_long(argc, argv, "np:c:", options, NULL)) != -1) {
		switch (opt) {
		case 'n':
			dryrun = 1;
			break;
		case 'p':
			policy_path = optarg;
			break;
		case 'c':
			protcno = strtoull(optarg, NULL, 10);
			break;
		default:
			usage();
		}
	}
	if (!policy_path || protcno == 0 || argc - optind < 2)
		usage();
	if (load_policy(policy_path, &policy) < 0) {
		perror(policy_path);
		return 1;
	}
	nsegs = argc - optind - 1;
	segnums = calloc(nsegs, sizeof(*segnums));
	if (!segnums)
		return 1;
	for (size_t i = 0; i < nsegs; i++)
		segnums[i] = strtoull(argv[optind + 1 + i], NULL, 10);

	nilfs_gc_logger = quiet_logger;
	nilfs = nilfs_open(argv[optind], NULL, NILFS_OPEN_RAW | NILFS_OPEN_RDWR | NILFS_OPEN_GCLK);
	if (!nilfs) {
		perror(argv[optind]);
		return 1;
	}
	for (size_t i = 0; i < nsegs; i += SEGMENTS_PER_BATCH) {
		size_t batch = nsegs - i < SEGMENTS_PER_BATCH ? nsegs - i : SEGMENTS_PER_BATCH;
		struct nilfs_reclaim_params params = { 0 };
		struct nilfs_reclaim_stat stat = { 0 };
		struct nilfs_sustat sustat;

		if (nilfs_get_sustat(nilfs, &sustat) < 0) {
			perror("nilfs_get_sustat");
			nilfs_close(nilfs);
			return 1;
		}
		params.flags = NILFS_RECLAIM_PARAM_PROTSEQ | NILFS_RECLAIM_PARAM_PROTCNO |
			       NILFS_RECLAIM_PARAM_LIVE_FILTER;
		params.protseq = sustat.ss_prot_seq;
		params.protcno = protcno;
		params.live_filter = retained;
		params.live_filter_arg = &policy;
		if (nilfs_xreclaim_segment(nilfs, segnums + i, batch, dryrun, &params, &stat) < 0) {
			perror("nilfs_xreclaim_segment");
			nilfs_close(nilfs);
			return 1;
		}
		total.cleaned_segs += stat.cleaned_segs;
		total.protected_segs += stat.protected_segs;
		total.live_vblks += stat.live_vblks;
		total.defunct_vblks += stat.defunct_vblks;
		total.live_pblks += stat.live_pblks;
		total.defunct_pblks += stat.defunct_pblks;
		total.freed_vblks += stat.freed_vblks;
	}
	nilfs_close(nilfs);
	printf("cleaned_segs=%zu protected_segs=%zu live_vblks=%zu defunct_vblks=%zu "
	       "live_pblks=%zu defunct_pblks=%zu freed_vblks=%zu\n",
	       total.cleaned_segs, total.protected_segs, total.live_vblks, total.defunct_vblks,
	       total.live_pblks, total.defunct_pblks, total.freed_vblks);
	return 0;
}
