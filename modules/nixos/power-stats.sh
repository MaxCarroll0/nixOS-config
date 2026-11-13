metric_query() {
  case "$1" in
    total) echo 'avg1m:pc_power_watts' ;;
    cpu) echo 'avg1m:pc_cpu_power_watts' ;;
    gpu) echo 'avg1m:pc_gpu_power_watts' ;;
  esac
}

stat() {
  agg="$1"
  query="$2"
  range="$3"
  curl --fail --silent --show-error --get \
    --data-urlencode "query=${agg}_over_time((${query})[${range}:1m])" \
    http://127.0.0.1:9091/api/v1/query \
    | jq -r '(.data.result[0].value[1] // "n/a") as $v
             | if $v == "n/a" then $v else ($v | tonumber | (. * 100 | round) / 100 | tostring) end'
}

printf '%-12s %-6s %8s %8s %8s\n' metric range min avg max
for key in total cpu gpu; do
  query=$(metric_query "$key")
  for range in 24h 7d 30d; do
    min=$(stat min "$query" "$range")
    avg=$(stat avg "$query" "$range")
    max=$(stat max "$query" "$range")
    printf '%-12s %-6s %8s %8s %8s\n' "$key" "$range" "$min" "$avg" "$max"
  done
done
