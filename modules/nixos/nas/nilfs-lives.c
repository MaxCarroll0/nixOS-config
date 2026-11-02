/* nilfs-lives: block runs of a NILFS2 log with their exact DAT lifetimes. */

#include <endian.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <nilfs.h>
#include "segment.h"

#define VINFO_BATCH 4096

struct blk {
	uint64_t ino, vblk, blocknr, cno;
	int64_t off;
	uint64_t s, e;
};

struct vec {
	struct blk *b;
	size_t n, cap;
};

static struct nilfs *nilfs;

static int push(struct vec *v, struct blk b)
{
	if (v->n == v->cap) {
		v->cap = v->cap ? v->cap * 2 : 4096;
		v->b = realloc(v->b, v->cap * sizeof(*v->b));
		if (!v->b)
			return -1;
	}
	v->b[v->n++] = b;
	return 0;
}

static int lifetimes(struct vec *v)
{
	struct nilfs_vinfo vi[VINFO_BATCH];

	for (size_t i = 0; i < v->n; i += VINFO_BATCH) {
		size_t n = v->n - i < VINFO_BATCH ? v->n - i : VINFO_BATCH;

		for (size_t j = 0; j < n; j++)
			vi[j].vi_vblocknr = v->b[i + j].vblk;
		if (nilfs_get_vinfo(nilfs, vi, n) < 0)
			return -1;
		for (size_t j = 0; j < n; j++) {
			struct blk *b = &v->b[i + j];
			int current = !b->blocknr || vi[j].vi_blocknr == b->blocknr;

			b->s = current ? vi[j].vi_start : 0;
			b->e = current ? vi[j].vi_end : 0;
		}
	}
	return 0;
}

static int continues(const struct blk *run, uint64_t n, const struct blk *b)
{
	return b->ino == run->ino && b->vblk == run->vblk + n && b->s == run->s && b->e == run->e &&
	       (run->off < 0 ? b->off < 0 : b->off == run->off + (int64_t)n);
}

static void emit(const char *tag, uint64_t seg, struct vec *v)
{
	for (size_t i = 0; i < v->n;) {
		const struct blk *run = &v->b[i];
		uint64_t n = 1;

		while (i + n < v->n && continues(run, n, &v->b[i + n]))
			n++;
		if (run->s < run->e)
			printf("%s %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRId64
			       " %" PRIu64 "\n",
			       tag, seg, run->ino, run->vblk, n, run->s, run->e, run->off, run->cno);
		i += n;
	}
	v->n = 0;
}

static int collect(struct nilfs_psegment *pseg, struct vec *v)
{
	struct nilfs_file file;
	struct nilfs_block blk;

	nilfs_file_for_each(&file, pseg) {
		uint64_t ino = le64toh(file.finfo->fi_ino);
		uint64_t cno = le64toh(file.finfo->fi_cno);

		if (nilfs_file_use_real_blocknr(&file) || (ino < NILFS_USER_INO && ino != NILFS_ROOT_INO))
			continue;
		nilfs_block_for_each(&blk, &file) {
			struct blk b = { .ino = ino, .blocknr = blk.blocknr, .cno = cno, .off = -1 };

			if (nilfs_block_is_data(&blk)) {
				const struct nilfs_binfo_v *bi = blk.binfo;

				b.vblk = le64toh(bi->bi_vblocknr);
				b.off = (int64_t)le64toh(bi->bi_blkoff);
			} else {
				b.vblk = le64toh(*(const __le64 *)blk.binfo);
			}
			if (push(v, b) < 0)
				return -1;
		}
	}
	return nilfs_file_is_error(&file, NULL) ? -1 : 0;
}

static int follow(uint64_t segnum, uint64_t seq, uint64_t from, uint64_t limit_seq, uint64_t limit_blk)
{
	struct vec v = { 0 };

	for (;;) {
		struct nilfs_segment segment;
		struct nilfs_psegment pseg;
		uint64_t next = segnum, next_seq = 0, resume = from;
		int done = seq > limit_seq;

		if (nilfs_get_segment(nilfs, segnum, &segment) < 0)
			return -1;
		if (resume < segment.blocknr)
			resume = segment.blocknr;
		nilfs_psegment_for_each(&pseg, &segment, segment.nblocks) {
			if (done || le64toh(pseg.segsum->ss_seq) != seq)
				break;
			next = le64toh(pseg.segsum->ss_next) / nilfs_get_blocks_per_segment(nilfs);
			if (pseg.blocknr < resume)
				continue;
			if (collect(&pseg, &v) < 0) {
				nilfs_put_segment(&segment);
				return -1;
			}
			resume = pseg.blocknr + le32toh(pseg.segsum->ss_nblocks);
			done = seq == limit_seq && pseg.blocknr >= limit_blk;
		}
		nilfs_put_segment(&segment);
		if (lifetimes(&v) < 0)
			return -1;
		emit("R", segnum, &v);
		if (done || next == segnum || nilfs_get_segment_seqnum(nilfs, next, &next_seq) < 0 ||
		    next_seq != seq + 1) {
			printf("END %" PRIu64 " %" PRIu64 " %" PRIu64 "\n", segnum, seq, resume);
			return 0;
		}
		segnum = next;
		seq = next_seq;
		from = 0;
	}
}

static int whole_segments(char **segnums, int n)
{
	struct vec v = { 0 };

	for (int i = 0; i < n; i++) {
		struct nilfs_segment segment;
		struct nilfs_psegment pseg;
		uint64_t segnum = strtoull(segnums[i], NULL, 10), seq = 0;

		if (nilfs_get_segment(nilfs, segnum, &segment) < 0)
			return -1;
		nilfs_psegment_for_each(&pseg, &segment, segment.nblocks) {
			if (!seq)
				seq = le64toh(pseg.segsum->ss_seq);
			else if (le64toh(pseg.segsum->ss_seq) != seq)
				break;
			if (collect(&pseg, &v) < 0) {
				nilfs_put_segment(&segment);
				return -1;
			}
		}
		nilfs_put_segment(&segment);
		if (lifetimes(&v) < 0)
			return -1;
		emit("R", segnum, &v);
	}
	return 0;
}

static int probe(void)
{
	struct vec v = { 0 };
	uint64_t vblk, n;

	while (scanf("%" SCNu64 " %" SCNu64, &vblk, &n) == 2) {
		for (uint64_t k = 0; k < n; k++) {
			struct blk b = { .vblk = vblk + k, .off = -1 };

			if (push(&v, b) < 0)
				return -1;
		}
		if (v.n >= VINFO_BATCH * 16) {
			if (lifetimes(&v) < 0)
				return -1;
			emit("V", 0, &v);
		}
	}
	if (lifetimes(&v) < 0)
		return -1;
	emit("V", 0, &v);
	return 0;
}

int main(int argc, char **argv)
{
	int ret;

	if (argc < 3 || (strcmp(argv[1], "follow") == 0 && argc != 8)) {
		fputs("usage: nilfs-lives follow DEVICE SEGNUM SEQ BLOCKNR LIMITSEQ LIMITBLOCKNR\n"
		      "       nilfs-lives segments DEVICE SEGNUM...\n"
		      "       nilfs-lives probe DEVICE < 'VBLOCKNR COUNT' lines\n",
		      stderr);
		return 2;
	}
	nilfs = nilfs_open(argv[2], NULL, NILFS_OPEN_RAW | NILFS_OPEN_RDONLY);
	if (!nilfs) {
		perror(argv[2]);
		return 1;
	}
	if (strcmp(argv[1], "follow") == 0)
		ret = follow(strtoull(argv[3], NULL, 10), strtoull(argv[4], NULL, 10), strtoull(argv[5], NULL, 10),
			     strtoull(argv[6], NULL, 10), strtoull(argv[7], NULL, 10));
	else if (strcmp(argv[1], "segments") == 0)
		ret = whole_segments(argv + 3, argc - 3);
	else
		ret = probe();
	nilfs_close(nilfs);
	if (ret < 0) {
		perror("nilfs-lives");
		return 1;
	}
	return 0;
}
