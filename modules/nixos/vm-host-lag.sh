sample=$(@guestLagSample@) || exit 0
if [ -z "$sample" ]; then
  rm -f @lagState@ @lagStatus@
  exit 0
fi
previous=null
[ -r @lagState@ ] && previous=$(cat @lagState@)
result=$(jq -cn -f @program@ \
  --arg raw "$sample" --argjson previous "$previous" --argjson now "$(date +%s)" \
  --argjson span @span@ --argjson busyLimit @busyLimit@ --argjson lossLimit @lossLimit@ \
  --argjson lossMinBytes @lossMinBytes@ --argjson rttLimit @rttLimit@)
jq -c .state <<<"$result" > @lagState@.tmp
mv @lagState@.tmp @lagState@
jq -c .status <<<"$result" > @lagStatus@.tmp
mv @lagStatus@.tmp @lagStatus@
