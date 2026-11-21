pid=$(/usr/bin/systemctl show -P MainPID minecraft)
[ "${pid:-0}" -gt 0 ] || exit 0
read -r up _ < /proc/uptime
ticks=0
for task in /proc/"$pid"/task/*; do
  if [ "$(/usr/bin/cat "$task"/comm 2>/dev/null)" = "Server thread" ]; then
    ticks=$(/usr/bin/sed 's/^.*) //' "$task"/stat | /usr/bin/awk '{ print $12 + $13 }')
    break
  fi
done
echo "u $up $ticks $(/usr/bin/getconf CLK_TCK)"
/usr/sbin/ss -Htin state established '( sport = :@minecraftPort@ )' | /usr/bin/awk '
  /^[0-9]/ || /^\[/ { peer = $NF; next }
  {
    sent = 0; retrans = 0; rtt = 0
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^bytes_sent:/) { sub(/^bytes_sent:/, "", $i); sent = $i }
      else if ($i ~ /^bytes_retrans:/) { sub(/^bytes_retrans:/, "", $i); retrans = $i }
      else if ($i ~ /^rtt:/) { sub(/^rtt:/, "", $i); split($i, r, "/"); rtt = r[1] }
    }
    print "c", peer, sent, retrans, rtt
  }'
