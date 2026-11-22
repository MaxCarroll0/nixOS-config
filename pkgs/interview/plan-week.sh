# interview week planner: has Claude plan the coming week's missing weekdays, as the configured account.
monday=$(date -d "next monday" +%F)
days=$(interview settings show --json | jq -r '.settings.days[]')
missing=()
for offset in 0 1 2 3 4 5 6; do
  day=$(date -d "$monday + $offset days" +%F)
  grep -qx "$(LC_ALL=C date -d "$day" +%a)" <<<"$days" || continue
  grep -qF "[\"$day\"" "$INTERVIEW_REPO/schedule.toml" 2>/dev/null || missing+=("$day")
done
if [ ${#missing[@]} -eq 0 ]; then
  echo "week of $monday already planned"
  exit 0
fi
cd "$INTERVIEW_REPO"
echo "planning ${missing[*]} as $PLAN_ACCOUNT"
cswap run "$PLAN_ACCOUNT" -- -p "Run the plan-week skill for these interview days: ${missing[*]}. You are running unattended from a timer: do not ask questions or stop to report repo state; plan, verify and commit, then report the table." \
  --permission-mode acceptEdits \
  --allowedTools "Skill" "Bash(nix develop:*)" "Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)" \
  "Bash(git log:*)" "Bash(interview problems:*)" "Bash(interview today:*)" "Bash(interview settings show:*)" "Bash(interview langs:*)" "Bash(interview run:*)" "Bash(nix build:*)" "Bash(mkdir:*)" "Bash(cp:*)" \
  "Bash(rm -rf /tmp/claude-*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(python3:*)" "Read" "Glob" "Grep"
for day in "${missing[@]}"; do
  grep -qF "[\"$day\"" schedule.toml || { echo "still unplanned: $day"; exit 1; }
done
