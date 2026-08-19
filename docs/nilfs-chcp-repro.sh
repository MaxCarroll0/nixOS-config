#!/usr/bin/env bash
# Reproduce the chcp [DEVICE] argument bug on two loopback NILFS2 filesystems.
set -u

W=/tmp/nilfsrepro
sudo umount "$W/mnt_a" "$W/mnt_b" 2>/dev/null
sudo rm -rf "$W"; mkdir -p "$W/mnt_a" "$W/mnt_b"

truncate -s 256M "$W/a.img" "$W/b.img"


DA=$(sudo losetup --find --show "$W/a.img")
DB=$(sudo losetup --find --show "$W/b.img")
for d in "$DA" "$DB"; do sudo mkfs.nilfs2 -q "$d" >/dev/null; done
echo "loop A = $DA   loop B = $DB"

sudo mount -t nilfs2 "$DA" "$W/mnt_a"
sudo mount -t nilfs2 "$DB" "$W/mnt_b"

# Make several checkpoints on each; each sync closes a segment.
for i in 1 2 3; do
  echo "a$i" | sudo tee "$W/mnt_a/file_a" >/dev/null; sync; sleep 1
  echo "b$i" | sudo tee "$W/mnt_b/file_b" >/dev/null; sync; sleep 1
done

echo
echo "### /proc/mounts order (this is what chcp falls back to)"
grep nilfs2 /proc/mounts

echo
echo "### checkpoints on A"; sudo lscp "$DA"
echo "### checkpoints on B"; sudo lscp "$DB"

CA=$(sudo lscp "$DA" | awk '$4=="cp"' | tail -1 | awk '{print $1}')
CB=$(sudo lscp "$DB" | awk '$4=="cp"' | tail -1 | awk '{print $1}')
echo
echo "newest checkpoint: A=$CA  B=$CB"

echo
echo "### 1. lscp accepts a device (control: the device argument is valid elsewhere)"
echo "\$ lscp $DA | tail -1"; sudo lscp "$DA" | tail -1

echo
echo "### 2. rmcp accepts a device (same [DEVICE] CNO grammar, works correctly)"
echo "\$ rmcp $DA 999999"; sudo rmcp "$DA" 999999; echo "  rc=$?"

echo
echo "### 3. BUG a: chcp rejects the device path as a checkpoint number"
echo "\$ chcp ss $DA $CA"; sudo chcp ss "$DA" "$CA"; echo "  rc=$?"

echo
echo "### 4. BUG b: chcp takes a numeric checkpoint as the device"
echo "\$ chcp ss $CA $CB"; sudo chcp ss "$CA" "$CB"; echo "  rc=$?"

echo
echo "### 5. IMPACT: with no usable device argument, chcp hits the wrong filesystem."
echo "    cwd is B's mountpoint, and we ask to promote checkpoint $CB."
echo "\$ cd $W/mnt_b && chcp ss $CB"
sudo sh -c "cd $W/mnt_b && chcp ss $CB"; echo "  rc=$?"
echo "  snapshots on A: $(sudo lscp -s "$DA" | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
echo "  snapshots on B: $(sudo lscp -s "$DB" | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
echo "  ^ the snapshot lands on A (first rw nilfs2 line in /proc/mounts), not on B."

echo
echo "### cleanup"
sudo umount "$W/mnt_a" "$W/mnt_b"
sudo losetup -d "$DA" "$DB"
sudo rm -rf "$W"
echo "done"
