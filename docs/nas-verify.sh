#!/usr/bin/env bash
# Full NAS verification, to run on the pi after a reset: sudo bash docs/nas-verify.sh
# Covers storage, services, retention, parity, dashboards, SMB and the reset forensics.

set -uo pipefail
pass=0; fail=0
ok()  { echo "  PASS $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

echo "########## why did it reboot?"
journalctl -t unclean-boot -b --no-pager -o cat 2>/dev/null | tail -3 | sed 's/^/  /'
echo "-- final samples before the previous shutdown (rails, load, memory):"
journalctl -t flight-recorder -b --no-pager -o cat 2>/dev/null | head -12 | sed 's/^/  /'
echo "-- header: epoch,load1,memAvailKB,running,blocked,EXT5V,VDD_CORE,3V3_SYS,undervolt,throttled"

echo
echo "########## storage"
for m in /mnt/disks/disk1 /mnt/disks/disk2 /mnt/parity /srv/nas; do
  mountpoint -q "$m" && ok "$m mounted" || bad "$m NOT mounted (run nas-unlock)"
done
mountpoint -q /srv/nas && echo "  pool: $(df -h /srv/nas | tail -1 | awk '{print $2" total, "$3" used ("$5")"}')"

echo
echo "########## services"
for u in nas-versions-watch-disk1 nas-versions-watch-disk2 nas-prefetch-disk1 \
         nas-prefetch-disk2 samba-smbd nas-smb-passwords flight-recorder \
         tailscale-identity nginx grafana; do
  [ "$(systemctl is-active $u.service)" = active ] && ok "$u" || bad "$u inactive"
done
[ "$(systemctl --failed --no-legend | wc -l)" = 0 ] && ok "no failed units" \
  || { systemctl --failed --no-legend | sed 's/^/    /'; bad "failed units present"; }

echo
echo "########## retention"
for b in disk1 disk2; do
  mountpoint -q "/mnt/disks/$b" || continue
  d=$(findmnt -no SOURCE "/mnt/disks/$b")
  echo "  $b: $(lscp "$d" 2>/dev/null | tail -n +2 | wc -l) checkpoints, $(lscp -s "$d" 2>/dev/null | tail -n +2 | wc -l) snapshots"
done
echo "  @GMT- generations: $(ls -d /srv/nas/snapshots/@GMT-* 2>/dev/null | wc -l)"

echo
echo "########## parity"
EXE=$(systemctl cat nas-snapraid-scrub.service 2>/dev/null | grep -oE 'ExecStart=[^ ]+' | cut -d= -f2-)
CONF=$(grep -ohE '/nix/store/[a-z0-9]+-snapraid\.conf' "$(readlink -f "$EXE")" 2>/dev/null | head -1)
if [ -n "$CONF" ] && mountpoint -q /mnt/parity; then
  s=$(timeout 180 snapraid --conf "$CONF" status 2>&1)
  echo "$s" | grep -qi "was scrubbed at least one time" && ok "full array scrubbed" || bad "array not fully scrubbed"
  echo "$s" | grep -qi "No error detected" && ok "no parity errors" || bad "parity errors present"
  echo "$s" | grep -iE "not scrubbed|scrubbed at least|No error|sync is in progress" | sed 's/^/    /'
else
  bad "cannot check parity (config or /mnt/parity missing)"
fi

echo
echo "########## SMB"
users=$(pdbedit -L 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
echo "  passdb: ${users:-none}"
if [ -r /run/secrets/smb-password-max ]; then
  PW=$(cat /run/secrets/smb-password-max)
  out=$(smbclient //127.0.0.1/max -U "max%$PW" -c 'ls' 2>&1)
  echo "$out" | grep -qiE "LOGON_FAILURE|ACCESS_DENIED|NO_SUCH_GROUP" \
    && { bad "max cannot use its share"; echo "$out" | head -2 | sed 's/^/    /'; } \
    || ok "max authenticates and can list its share"
  GEN=$(ls -d /srv/nas/snapshots/@GMT-* 2>/dev/null | tail -1 | xargs -r basename)
  if [ -n "$GEN" ]; then
    smbclient //127.0.0.1/max -U "max%$PW" -c "ls \"$GEN\\\\\"" >/dev/null 2>&1 \
      && ok "previous-versions path reachable over SMB" || bad "timewarp path failed"
  fi
  unset PW
else
  bad "smb secret missing"
fi

echo
echo "########## dashboards carry the query fixes"
CUR=$(readlink -f /run/current-system)
D=$(nix-store -qR "$CUR" 2>/dev/null | grep 'grafana-dashboards-' | grep -v '\.drv$')
t=0; g=0; u=0
for dir in $D; do for f in "$dir"/*.json; do
  t=$((t + $(grep -c -F '7d:1m' "$f")))
  g=$((g + $(grep -c -F 'min_over_time(host:up' "$f")))
  u=$((u + $(grep -c -F 'avg_over_time(host:up' "$f")))
done; done
[ "$t" -gt 0 ] && ok "uptime subquery step x$t" || bad "uptime step missing"
[ "$g" -gt 0 ] && ok "downtime guard x$g"       || bad "downtime guard missing"
[ "$u" -gt 0 ] && ok "energy up-fraction x$u"   || bad "up-fraction missing"

echo
echo "########## $pass passed, $fail failed"
