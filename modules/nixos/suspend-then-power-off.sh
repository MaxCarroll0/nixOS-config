alarm=/sys/class/rtc/rtc0/wakealarm
target=$(( $(date +%s) + @hoursSeconds@ ))

# Writing a wakealarm that is already armed fails EBUSY.
echo 0 > "$alarm"
echo "$target" > "$alarm"
echo "$target" > @deepSleepTarget@

# systemctl suspend returns once logind accepts the request, not on
# resume, so whether to power off is decided by resumeCommands.
# A refused suspend must disarm both, or the next resume reads a target
# already in the past and escalates to poweroff.
# Not --check-inhibitors=yes: that also refuses whenever any user is
# logged in, and the autologin session on tty1 never goes away. The
# default still lets logind honour block inhibitors.
if ! systemctl suspend; then
  echo 0 > "$alarm"
  rm -f @deepSleepTarget@
  exit 1
fi
