# Solve Cloudflare for curd's providers via FlareSolverr; seed cookie/UA files.
FS_URL="${FLARESOLVERR_URL:-http://127.0.0.1:8191/v1}"
STORAGE="${CURD_STORAGE:-$HOME/.local/share/curd}"
MAX_AGE="${CURD_CF_MAX_AGE:-1500}" # seconds; skip refresh if session is newer
SESSION="$STORAGE/cf_session.json"

mkdir -p "$STORAGE"

if [[ "${1:-}" != "--force" && -f "$SESSION" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$SESSION") ))
  if (( age < MAX_AGE )); then
    exit 0
  fi
fi

solve() { # url -> FlareSolverr solution JSON
  curl -s -X POST "$FS_URL" -H 'Content-Type: application/json' -m 120 \
    -d "$(jq -nc --arg url "$1" '{cmd:"request.get",url:$url,maxTimeout:90000}')"
}

AA_URL='https://api.allanime.day/api?variables=%7B%22search%22%3A%7B%22query%22%3A%22a%22%7D%2C%22limit%22%3A1%2C%22translationType%22%3A%22sub%22%2C%22countryOrigin%22%3A%22ALL%22%7D&query=query(%24search%3ASearchInput%2C%24limit%3AInt%2C%24translationType%3AVaildTranslationTypeEnumType%2C%24countryOrigin%3AVaildCountryOriginEnumType)%7Bshows(search%3A%24search%2Climit%3A%24limit%2CtranslationType%3A%24translationType%2CcountryOrigin%3A%24countryOrigin)%7Bedges%7B_id%20name%7D%7D%7D'
AP_URL='https://animepahe.pw/api?m=search&q=a'

aa=$(solve "$AA_URL")
ap=$(solve "$AP_URL")

aa_cookie=$(jq -r '.solution.cookies | map("\(.name)=\(.value)") | join("; ")' <<<"$aa")
ap_cookie=$(jq -r '.solution.cookies | map("\(.name)=\(.value)") | join("; ")' <<<"$ap")
ua=$(jq -r '.solution.userAgent' <<<"$ap")

jq -nc --arg ua "$ua" --arg aa "$aa_cookie" --arg ap "$ap_cookie" \
  '{userAgent:$ua, hosts:{"allanime.day":$aa, "animepahe.pw":$ap}}' >"$SESSION"

# curd's animepahe path gates on a non-empty native cookie file before trusting the session.
jq -c '[.solution.cookies[] | {Name:.name, Value:.value}]' <<<"$ap" >"$STORAGE/animepahe_cookies.json"
