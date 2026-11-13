interval="${1:-5}"
history="${2:-24 hours}"
declare -A before
available=0
domains=0
for d in /sys/class/powercap/*/; do
  [ -e "$d/energy_uj" ] || continue
  available=$((available + 1))
  [ -r "$d/energy_uj" ] || continue
  before["$d"]=$(cat "$d/energy_uj")
  domains=$((domains + 1))
done
if [ "$domains" -eq 0 ]; then
  if [ "$available" -eq 0 ]; then
    echo "no powercap energy counters found." >&2
  else
    echo "no readable powercap domains." >&2
    echo "energy_uj is root-only since Linux 5.10; set" >&2
    echo "local.monitoring.userReadable = true, or run this as root." >&2
  fi
  exit 1
fi
sleep "$interval"
for d in /sys/class/powercap/*/; do
  [ -r "$d/energy_uj" ] || continue
  name=$(cat "$d/name" 2>/dev/null || basename "$d")
  after=$(cat "$d/energy_uj")
  delta=$(( after - ${before["$d"]} ))
  # The counter wraps at max_energy_range_uj.
  if [ "$delta" -lt 0 ]; then
    range=$(cat "$d/max_energy_range_uj" 2>/dev/null || echo 0)
    [ "$range" -gt 0 ] || continue
    delta=$(( delta + range ))
  fi
  printf '%-24s %6.2f W\n' "$name" "$(echo "scale=2; $delta / 1000000 / $interval" | bc)"
done

start=$(date --date="$history ago" +%s)
end=$(date +%s)
reports=$(mktemp --directory)
trap 'rm -rf "$reports"' EXIT

graph() {
  key="$1"
  title="$2"
  query="$3"
  report="$reports/$key"

  if ! curl --fail --silent --show-error --get \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$start" \
    --data-urlencode "end=$end" \
    --data-urlencode "step=60" \
    http://127.0.0.1:9091/api/v1/query_range \
    | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"' > "$report"; then
    echo "could not read historical $title data" >&2
    return
  fi

  if [ ! -s "$report" ]; then
    echo "no historical $title data yet" >&2
    return
  fi

  printf '\n%s, last %s\n' "$title" "$history"
  gnuplot <<EOF
set terminal dumb 100 20
set xdata time
set timefmt "%s"
set format x "%H:%M"
set ylabel "W"
set yrange [0:*]
plot "$report" using 1:2 with lines title "$title"
EOF
}

graph total "Total" "avg1m:pc_power_watts"
graph cpu "CPU" "avg1m:pc_cpu_power_watts"
graph gpu "GPU" "avg1m:pc_gpu_power_watts"
