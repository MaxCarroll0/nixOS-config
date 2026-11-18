toplevel() {
  local p
  p=$(readlink -f "$1")
  [ -e "$p/deploy-rs-activate" ] && p=$(dirname "$(readlink "$p/activate")")
  echo "$p"
}

booted=/run/booted-system
current=/run/current-system
reasons=()
for part in kernel initrd kernel-modules; do
  [ "$(readlink -f "$booted/$part")" = "$(readlink -f "$current/$part")" ] || reasons+=("$part")
done
cmp -s "$booted/kernel-params" "$current/kernel-params" || reasons+=(kernel-params)
[ "$(toplevel /nix/var/nix/profiles/system)" = "$(toplevel "$current")" ] || reasons+=(staged)

reasonList=$(IFS=,; echo "${reasons[*]}")
if [ "${1:-}" = --metric ]; then
  printf 'node_reboot_required{reasons="%s"} %d\n' "$reasonList" "$((${#reasons[@]} > 0))"
  exit 0
fi
if [ "${#reasons[@]}" -eq 0 ]; then
  echo "no reboot needed"
  exit 1
fi
echo "reboot needed: $reasonList"
