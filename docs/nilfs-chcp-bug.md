# `chcp` ignores its `[DEVICE]` argument (nilfs-utils 2.2.12)

**Status: fixed upstream**, by commit
[`27bfa50c4`](https://github.com/nilfs-dev/nilfs-utils/commit/27bfa50c4) — *"chcp: fix inverted
logic in argument parsing"*, 2026-01-21 — first released in **v2.3.0**, and present in the current **v2.3.1**. nixpkgs still ships
**2.2.12** (released before the fix), so any NixOS system using `chcp` from nixpkgs is affected
until that package is bumped.

This document exists because the bug was rediscovered here from its symptoms, and the
reproduction is worth keeping: it is the test that tells you whether the `chcp` on your `PATH`
is the broken one.

## Summary

`chcp`'s own usage string advertises a device argument:

```
Usage: chcp [OPTION]... cp|ss [DEVICE] CNO...
```

In 2.2.12 that argument cannot be used. A device *path* is rejected as a checkpoint number, and
a *numeric* argument in the device position is accepted as a device. The two cases are the two
halves of one inverted conditional.

## Reproduction

No special hardware: two loopback NILFS2 filesystems. Needs root, the `nilfs2` kernel module and
nilfs-utils.

```bash
W=/tmp/nilfsrepro
mkdir -p "$W/mnt_a" "$W/mnt_b"
truncate -s 256M "$W/a.img" "$W/b.img"          # 128M is below the NILFS2 minimum

DA=$(losetup --find --show "$W/a.img")
DB=$(losetup --find --show "$W/b.img")
mkfs.nilfs2 -q "$DA"; mkfs.nilfs2 -q "$DB"      # mkfs the loop device, not the image file

mount -t nilfs2 "$DA" "$W/mnt_a"
mount -t nilfs2 "$DB" "$W/mnt_b"

for i in 1 2 3; do                              # each sync closes a segment -> a checkpoint
  echo "a$i" > "$W/mnt_a/file_a"; sync; sleep 1
  echo "b$i" > "$W/mnt_b/file_b"; sync; sleep 1
done
```

Both filesystems now hold checkpoints 1..4.

### Control: the same grammar works in the sibling tools

`lscp` takes a device:

```
$ lscp /dev/loop1 | tail -1
                   4  2026-08-19 13:20:12   cp    -            5          2
```

`rmcp` takes `[DEVICE] CNO...` — it parses the device, then rejects the checkpoint:

```
$ rmcp /dev/loop1 999999
rmcp: invalid checkpoint: 999999
```

### Bug, first half: a device path is treated as a checkpoint number

```
$ chcp ss /dev/loop1 4
chcp: /dev/loop1: invalid checkpoint number
$ echo $?
1
```

`invalid checkpoint number` is emitted only from the loop over checkpoint numbers, so the device
path was never consumed as a device.

### Bug, second half: a checkpoint number is treated as a device

```
$ chcp ss 4 4
chcp: cannot open NILFS on 4: No such device or address
```

`cannot open NILFS on` is emitted only from `nilfs_open()`, so `4` *was* consumed as a device.

Same argument shape, opposite handling, discriminated solely by whether the argument parses as a
number.

### Cleanup

```bash
umount "$W/mnt_a" "$W/mnt_b"; losetup -d "$DA" "$DB"; rm -rf "$W"
```

## Cause

`bin/chcp.c`, argument parsing in `main()`:

```c
} else {
        modestr = argv[optind++];
        cno = nilfs_parse_cno(argv[optind], &endptr, CHCP_BASE);
        if (cno >= NILFS_CNO_MAX || *endptr != '\0')
                dev = NULL;              /* parse FAILED -> not treated as a device */
        else
                dev = argv[optind++];    /* parse SUCCEEDED -> treated as the device */
}
```

The branches are swapped. An argument that fails to parse as a checkpoint number is exactly what
a device path looks like, so it should be assigned to `dev`; one that parses as a number is a
checkpoint and should not be.

`bin/rmcp.c` performs the identical test the correct way round, which is what identifies this as
an oversight rather than an interface choice:

```c
} else {
        if (nilfs_parse_cno_range(argv[optind], &start, &end, RMCP_BASE) < 0)
                dev = argv[optind++];
        else
                dev = NULL;
}
```

Upstream's fix swaps the two assignments in `chcp.c`, making it match `rmcp.c`.

## Consequences

**Any script passing a device to `chcp` fails**, with a message that misidentifies the problem
as a bad checkpoint number rather than a rejected device. This is how the bug was found: a
promotion loop of the form

```bash
lscp -r "$device" | awk '$4=="cp" {print $1}' | xargs -r -n1 chcp ss "$device" || true
```

had never promoted a single checkpoint. Every invocation failed, and `|| true` hid it. On NILFS2
that is not cosmetic: an unpromoted checkpoint is also **unmountable**, so nothing was retained
*and* nothing was readable, while the tooling reported success.

**Without a device argument, targeting is implicit.** `chcp` then calls `nilfs_open(NULL, NULL,
…)`, which resolves through `nilfs_find_fs()` against `/proc/mounts`. Observed behaviour on two
mounted NILFS2 filesystems: with the working directory inside filesystem B, `chcp ss 4` promoted
checkpoint 4 **on B**, and with the working directory outside any NILFS2 filesystem it acted on
the only mounted one. So the working directory does select the target, and a `cd` into the
intended filesystem is a viable workaround — but it is implicit, and checkpoint numbers are
per-filesystem, so a script that gets the working directory wrong silently promotes an unrelated
checkpoint on another filesystem rather than failing.

## Fix

Upgrade to **v2.3.1** (or anything from v2.3.0 on). On nixpkgs (still 2.2.12) that means an overlay:

```nix
nilfs-utils = prev.nilfs-utils.overrideAttrs (old: rec {
  version = "2.3.1";
  src = final.fetchFromGitHub {
    owner = "nilfs-dev";
    repo = "nilfs-utils";
    tag = "v${version}";
    hash = "sha256-Sqg1pERzxc6H7eMJGv3XTgiC3/KXu/hqqZzl1vxM6E8=";
  };
  postPatch = builtins.replaceStrings [ "sbin/mkfs/mkfs.c" ] [ "sbin/mkfs.c" ] old.postPatch;
});
```

`sbin/mkfs/mkfs.c` moved to `sbin/mkfs.c` in 2.3.0, so the existing nixpkgs `postPatch` needs
redirecting or the build fails with `substitute(): ERROR: file 'sbin/mkfs/mkfs.c' does not exist`.

2.3.x also brings [`ea6b9b84f`](https://github.com/nilfs-dev/nilfs-utils/commit/ea6b9b84f),
*"bin: allow specifying filesystem node instead of device"*, so a mountpoint can be passed where
2.2.12 demanded a device — which removes the "every nilfs tool takes the device, never the
mountpoint" trap as well.

## Verifying your build

```
$ chcp ss /dev/loopX <cno>
```

Broken (2.2.12): `chcp: /dev/loopX: invalid checkpoint number`, exit 1.
Fixed (2.3.x): exits 0, and the checkpoint appears in `lscp -s /dev/loopX`.
