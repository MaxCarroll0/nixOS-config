name=$1
mirror=$2
index=$3
data=$4
streamLock=$5
nilfsLock=$6
user=$7
dailyLimit=$8
lastFile=$9
budgetFile=${10}

refuse() {
  logger -p user.err -t nas-stream-ingest "$name: $1, not ingested"
  exit 1
}

exec {pushLock}<"$streamLock"
flock -w 3600 "$pushLock" || refuse "push still running"

odd=$(find "$mirror" -mindepth 1 ! -type f ! -type d -print -quit)
[ -z "$odd" ] || refuse "non-regular file in the push"

now=$(date +%s)
size=$(du -sb "$data" | cut -f1)
start=0
base=$size
if [ -r "$budgetFile" ]; then
  read -r start base < "$budgetFile" || true
fi
if ! [[ "$start" =~ ^[0-9]+$ && "$base" =~ ^[0-9]+$ ]] || [ $((now - start)) -ge 86400 ]; then
  start=$now
  base=$size
  echo "$start $base" > "$budgetFile"
fi
[ $((size - base)) -le "$dailyLimit" ] || refuse "grew $((size - base)) bytes in 24 hours"

find "$index" "$data" \( ! -user "$user" -o ! -group "$user" \) -exec chown -h "$user:$user" {} +

flock "$nilfsLock" \
  setpriv --reuid="$user" --regid="$user" --init-groups --no-new-privs --inh-caps=-all -- \
  stream-delta --index "$index" --data "$data" ingest --mirror "$mirror" --captured "$now" --source "push:$now" \
  || refuse "ingest failed"

echo "$now" > "$lastFile"
