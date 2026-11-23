name=$(basename -- "$0")
self=$(dirname -- "$0")
if [ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lockdown/active.json" ]; then
  echo "lockdown: $name is blocked in this shell until today's interviews are done" >&2
  exit 126
fi
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF -- "$self" | paste -sd:)
exec "$name" "$@"
