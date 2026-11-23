def parse:
  split("\n")
  | map(select(length > 0) | split(" ")) as $rows
  | ($rows | map(select(.[0] == "u")) | first) as $u
  | {
      up: ($u[1] | tonumber),
      ticks: ($u[2] | tonumber),
      hz: ($u[3] | tonumber),
      conns: (
        $rows
        | map(select(.[0] == "c") | {key: .[1], value: {sent: (.[2] | tonumber), retrans: (.[3] | tonumber), rtt: (.[4] | tonumber)}})
        | from_entries
      )
    };
def mean: if length == 0 then null else add / length end;
def round1: . * 10 | round / 10;

($raw | parse) as $sample
| ($previous.sample // null) as $last
| (
    if $last != null and $sample.up > $last.up and $sample.ticks >= $last.ticks then
      [
        $sample.conns | to_entries[]
        | $last.conns[.key] as $was
        | select($was != null)
        | {sent: (.value.sent - $was.sent), retrans: (.value.retrans - $was.retrans)}
        | select(.sent >= 0 and .retrans >= 0)
      ] as $deltas
      | [{
          at: $now,
          busy: (($sample.ticks - $last.ticks) / $sample.hz / ($sample.up - $last.up)),
          sent: ($deltas | map(.sent) | add // 0),
          retrans: ($deltas | map(.retrans) | add // 0),
          rtt: ($sample.conns | map(.rtt) | mean)
        }]
    else [] end
  ) as $minute
| ((($previous.window // []) + $minute) | map(select(.at > $now - $span))) as $window
| ($window | map(.busy) | mean) as $busy
| ($window | map(.sent) | add // 0) as $sent
| ($window | map(.retrans) | add // 0) as $retrans
| ($window | map(.rtt | select(. != null)) | mean) as $rtt
| (if $sent > 0 then $retrans / $sent * 100 else null end) as $loss
| [
    (if $busy != null and $busy >= $busyLimit then "The server is struggling to keep up." else empty end),
    (if $loss != null and $sent >= $lossMinBytes and $loss >= $lossLimit then "Network packets are being lost." else empty end),
    (if $rtt != null and $rtt >= $rttLimit then "Network latency is high." else empty end)
  ] as $reasons
| {
    state: {sample: $sample, window: $window},
    status: {
      updated: $now,
      minutes: ($window | length),
      msPerTick: (if $busy == null then null else [$busy * 50, 50] | min | round1 end),
      saturated: ($busy != null and $busy >= 0.95),
      lossPercent: (if $loss == null then null else $loss | round1 end),
      rttMs: (if $rtt == null then null else $rtt | round end),
      players: ($sample.conns | length),
      health: (if $window == [] then "unknown" elif $reasons == [] then "ok" else "degraded" end),
      reasons: $reasons
    }
  }
