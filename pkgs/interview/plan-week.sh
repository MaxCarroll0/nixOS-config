# interview week planner: has Claude plan the coming week's missing weekdays, as the configured account.
monday=$(date -d "next monday" +%F)
missing=()
for offset in 0 1 2 3 4; do
  day=$(date -d "$monday + $offset days" +%F)
  grep -qF "[\"$day\"]" "$INTERVIEW_REPO/schedule.toml" 2>/dev/null || missing+=("$day")
done
if [ ${#missing[@]} -eq 0 ]; then
  echo "week of $monday already planned"
  exit 0
fi
cd "$INTERVIEW_REPO"
echo "planning ${missing[*]} as $PLAN_ACCOUNT"
cswap run "$PLAN_ACCOUNT" -- claude -p "/plan-week ${missing[*]}" \
  --permission-mode acceptEdits \
  --allowedTools "Bash(nix develop:*)" "Bash(git add:*)" "Bash(git commit:*)" "Bash(git status:*)" \
  "Bash(git log:*)" "Bash(interview problems:*)" "Bash(interview today:*)" "Bash(mkdir:*)" "Bash(cp:*)" \
  "Bash(rm -rf /tmp/claude-*)" "Bash(ls:*)" "Bash(cat:*)"
for day in "${missing[@]}"; do
  grep -qF "[\"$day\"]" schedule.toml || { echo "still unplanned: $day"; exit 1; }
done
