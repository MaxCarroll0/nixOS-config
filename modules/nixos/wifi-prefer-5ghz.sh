W=fi.w1.wpa_supplicant1

prop() { busctl --json=short get-property "$W" "$1" "$2" "$3" | jq -r "$4"; }
bss() { busctl --json=short call "$W" "$1" org.freedesktop.DBus.Properties GetAll s "$W.BSS" | jq -c '.data[0]'; }

for iface in $(prop /fi/w1/wpa_supplicant1 "$W" Interfaces '.data[]'); do
  [ "$(prop "$iface" "$W.Interface" State .data)" = completed ] || continue
  current=$(bss "$(prop "$iface" "$W.Interface" CurrentBSS .data)")
  [ "$(jq '.Frequency.data' <<<"$current")" -lt 5000 ] || continue

  busctl call "$W" "$iface" "$W.Interface" Scan 'a{sv}' 1 Type s active || true
  sleep 6

  target=$(
    for b in $(prop "$iface" "$W.Interface" BSSs '.data[]'); do bss "$b"; done |
      jq -rs --argjson cur "$current" --argjson min "$MIN_SIGNAL" '
        map(select(.SSID.data == $cur.SSID.data
          and .Frequency.data >= 5000
          and .Signal.data >= $min
          and .Age.data <= 15))
        | max_by(.Signal.data) // empty
        | .BSSID.data | map([(. / 16 | floor), . % 16] | map("0123456789abcdef"[.:. + 1]) | add) | join(":")'
  )
  [ -n "$target" ] || continue

  echo "roaming $(prop "$iface" "$W.Interface" Ifname .data) to $target"
  busctl call "$W" "$iface" "$W.Interface" Roam s "$target"
done
