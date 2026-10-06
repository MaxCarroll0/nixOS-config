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
         nas-prefetch-disk2 samba-smbd nginx grafana; do
  [ "$(systemctl is-active $u.service)" = active ] && ok "$u" || bad "$u inactive"
done

# A completed oneshot without RemainAfterExit reads as inactive, so judge these
# by their last result instead. `show -p Result` prints "success" for a unit that
# does not exist at all, so existence has to be checked separately.
for u in nas-smb-passwords flight-recorder tailscale-identity; do
  systemctl cat "$u.service" >/dev/null 2>&1 || { bad "$u does not exist"; continue; }
  [ "$(systemctl show -p Result --value "$u.service")" = success ] \
    && ok "$u ran" || bad "$u did not succeed"
done

[ "$(systemctl list-units --failed --all --no-legend | wc -l)" = 0 ] && ok "no failed units" \
  || { systemctl list-units --failed --all --no-legend | sed 's/^/    /'; bad "failed units present"; }

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
  t=$((t + $(grep -c -F 'host:uptime_seconds' "$f")))
  g=$((g + $(grep -c -F 'host:up_observed_seconds' "$f")))
  u=$((u + $(grep -c -F 'equivalent_power' "$f")))
done; done
[ "$t" -gt 0 ] && ok "uptime series x$t"       || bad "uptime series missing"
[ "$g" -gt 0 ] && ok "observed-coverage x$g"   || bad "observed-coverage missing"
[ "$u" -gt 0 ] && ok "equivalent power x$u"    || bad "equivalent power missing"

echo
echo "########## $pass passed, $fail failed"
