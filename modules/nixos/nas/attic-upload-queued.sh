install -d -m 0700 @stateDir@

# Recover interrupted batches first, then detach the queue without holding the build hook's lock.
(
  flock 9
  if [ -s @stateDir@/pending ]; then
    cat @stateDir@/pending >> @stateDir@/queue
    rm -f @stateDir@/pending
  fi
  if [ -s @stateDir@/queue ]; then
    mv @stateDir@/queue @stateDir@/pending
  fi
) 9> @stateDir@/queue.lock

if [ ! -s @stateDir@/pending ]; then
  exit 0
fi

# attic rejects a whole batch on one bad path, and the requeue would retry it forever.
while read -r path; do
  [ -e "$path" ] && printf '%s\n' "$path"
done < @stateDir@/pending > @stateDir@/pending.valid
mv @stateDir@/pending.valid @stateDir@/pending

if [ ! -s @stateDir@/pending ]; then
  rm -f @stateDir@/pending
  exit 0
fi

requeue() {
  (
    flock 9
    cat "$1" >> @stateDir@/queue
    rm -f "$1"
  ) 9> @stateDir@/queue.lock
}

if attic push --stdin --jobs 1 lan:@cache@ < @stateDir@/pending; then
  rm -f @stateDir@/pending
  exit 0
fi

if ! attic cache info lan:@cache@ > /dev/null; then
  requeue @stateDir@/pending
  exit 1
fi

touch @stateDir@/failures
: > @stateDir@/retry
while read -r path; do
  attempts=$(awk -v p="$path" '$1 == p { n = $2 } END { print n + 0 }' @stateDir@/failures)
  awk -v p="$path" '$1 != p' @stateDir@/failures > @stateDir@/failures.new
  mv @stateDir@/failures.new @stateDir@/failures
  if attic push --jobs 1 lan:@cache@ "$path" < /dev/null; then
    continue
  fi
  attempts=$((attempts + 1))
  if [ "$attempts" -ge @maxAttempts@ ]; then
    echo "giving up on $path after $attempts failed uploads; recorded in @stateDir@/failed" >&2
    printf '%s\n' "$path" >> @stateDir@/failed
  else
    printf '%s %s\n' "$path" "$attempts" >> @stateDir@/failures
    printf '%s\n' "$path" >> @stateDir@/retry
  fi
done < @stateDir@/pending
rm -f @stateDir@/pending

if [ -s @stateDir@/retry ]; then
  requeue @stateDir@/retry
  exit 1
fi
rm -f @stateDir@/retry
