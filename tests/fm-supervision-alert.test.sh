#!/usr/bin/env bash
# Behavior tests for bin/fm-supervision-alert.sh, the independent checker that
# tells the captain when this home's watcher beacon has been dead too long.
#
# Every case drives the executable's `check` through its clock seam
# (FM_SUPERVISION_ALERT_NOW) and the shared notifier seam (FM_WEDGE_ALARM_EXEC,
# pointed at a recorder), so no case posts a real notification or waits on the
# wall clock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-alert)
ALERT="$ROOT/bin/fm-supervision-alert.sh"

REC="$TMP_ROOT/rec"
cat > "$REC" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:?}"
exit 0
REC
chmod +x "$REC"

mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

# make_home <name> [work]: a home whose beacon exists; "work" adds a live task.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  [ "${2:-}" != work ] || fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  : > "$home/alerts.log"
  printf '%s\n' "$home"
}

beat_of() {
  mtime "$1/state/.last-watcher-beat"
}

# check <home> <now-epoch>
check() {
  local home=$1 now=$2
  env -u FM_POLL -u FM_GUARD_GRACE -u FM_WEDGE_ALARM_CHANNEL \
    FM_HOME="$home" FM_ROOT_OVERRIDE= \
    FM_SUPERVISION_ALERT_NOW="$now" \
    FM_SUPERVISION_ALERT_AFTER=900 FM_SUPERVISION_ALERT_CONFIRM=60 \
    FM_WEDGE_ALARM_EXEC="$REC" FM_WEDGE_ALARM_LOG="$home/alerts.log" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    bash "$ALERT" check || fail "check exited non-zero for $home at $now"
}

alert_count() {
  grep -c 'Supervision is down' "$1/alerts.log" || true
}

recovered_count() {
  grep -c 'Supervision recovered' "$1/alerts.log" || true
}

test_dead_past_threshold_alerts_once() {
  local home base
  home=$(make_home dead-alerts work)
  base=$(beat_of "$home")
  check "$home" $((base + 950))
  [ "$(alert_count "$home")" = 0 ] \
    || fail "the first dead sighting alerted before a second check confirmed it"
  check "$home" $((base + 980))
  [ "$(alert_count "$home")" = 0 ] \
    || fail "a second sighting inside the confirm window alerted"
  check "$home" $((base + 1070))
  [ "$(alert_count "$home")" = 1 ] \
    || fail "a beacon dead past the threshold on two checks did not alert exactly once: $(cat "$home/alerts.log")"
  grep -F "$home" "$home/alerts.log" >/dev/null \
    || fail "the alert does not name the home"
  grep -F '1 task(s) in flight' "$home/alerts.log" >/dev/null \
    || fail "the alert does not say what work is waiting"
  pass "a beacon dead past the threshold alerts once, on the confirming check"
}

test_still_dead_does_not_repeat() {
  local home base
  home=$(make_home dead-repeat work)
  base=$(beat_of "$home")
  check "$home" $((base + 950))
  check "$home" $((base + 1070))
  check "$home" $((base + 1190))
  check "$home" $((base + 9000))
  check "$home" $((base + 40000))
  [ "$(alert_count "$home")" = 1 ] \
    || fail "a beacon that stayed dead alerted more than once: $(cat "$home/alerts.log")"
  pass "a beacon that stays dead does not repeat the alert"
}

test_recovery_notifies_once() {
  local home base beat
  home=$(make_home recover work)
  base=$(beat_of "$home")
  check "$home" $((base + 950))
  check "$home" $((base + 1070))
  sleep 1
  touch "$home/state/.last-watcher-beat"
  beat=$(beat_of "$home")
  check "$home" $((beat + 10))
  check "$home" $((beat + 20))
  check "$home" $((beat + 30))
  [ "$(recovered_count "$home")" = 1 ] \
    || fail "recovery did not notify exactly once: $(cat "$home/alerts.log")"
  [ "$(alert_count "$home")" = 1 ] \
    || fail "recovery raised another down alert"
  [ ! -e "$home/state/.supervision-alert" ] \
    || fail "recovery left the episode record behind"
  pass "a beacon that comes back sends one recovered notice and closes the episode"
}

test_new_outage_after_recovery_alerts_again() {
  local home base beat
  home=$(make_home second-episode work)
  base=$(beat_of "$home")
  check "$home" $((base + 950))
  check "$home" $((base + 1070))
  sleep 1
  touch "$home/state/.last-watcher-beat"
  beat=$(beat_of "$home")
  check "$home" $((beat + 10))
  check "$home" $((beat + 950))
  check "$home" $((beat + 1070))
  [ "$(alert_count "$home")" = 2 ] \
    || fail "a second outage after recovery did not alert again: $(cat "$home/alerts.log")"
  pass "each outage episode alerts once"
}

test_no_live_work_no_alert() {
  local home base
  home=$(make_home idle)
  base=$(beat_of "$home")
  check "$home" $((base + 950))
  check "$home" $((base + 1070))
  check "$home" $((base + 40000))
  [ ! -s "$home/alerts.log" ] \
    || fail "a home with no live work alerted: $(cat "$home/alerts.log")"
  [ ! -e "$home/state/.supervision-alert" ] \
    || fail "a home with no live work kept an episode record"
  pass "a home that needs no supervision never alerts"
}

test_fresh_beacon_no_alert() {
  local home base
  home=$(make_home fresh work)
  base=$(beat_of "$home")
  check "$home" $((base + 10))
  check "$home" $((base + 200))
  check "$home" $((base + 299))
  [ ! -s "$home/alerts.log" ] \
    || fail "a fresh beacon alerted: $(cat "$home/alerts.log")"
  pass "a fresh beacon never alerts"
}

test_stale_below_threshold_no_alert() {
  local home base
  home=$(make_home below-threshold work)
  base=$(beat_of "$home")
  check "$home" $((base + 400))
  check "$home" $((base + 700))
  check "$home" $((base + 899))
  [ ! -s "$home/alerts.log" ] \
    || fail "a beacon stale but under the threshold alerted: $(cat "$home/alerts.log")"
  pass "a beacon past grace but under the threshold does not alert"
}

test_beacon_that_beat_between_sightings_restarts_confirmation() {
  local home base beat
  home=$(make_home wake-from-sleep work)
  base=$(beat_of "$home")
  # A machine waking from sleep: the first check sees a long-dead beacon, then
  # the still-healthy watcher beats. The beat moved, so nothing is confirmed.
  check "$home" $((base + 30000))
  sleep 1
  touch "$home/state/.last-watcher-beat"
  beat=$(beat_of "$home")
  check "$home" $((beat + 10))
  [ ! -s "$home/alerts.log" ] \
    || fail "a watcher that beat right after a dead sighting still alerted: $(cat "$home/alerts.log")"
  pass "a single dead sighting followed by a beat never alerts"
}

test_absent_beacon_with_work_alerts() {
  local home now
  home=$(make_home absent work)
  rm -f "$home/state/.last-watcher-beat"
  now=$(date +%s)
  check "$home" "$now"
  check "$home" $((now + 120))
  [ "$(alert_count "$home")" = 1 ] \
    || fail "an absent beacon with live work did not alert once: $(cat "$home/alerts.log")"
  pass "live work with no beacon on record alerts once"
}

test_away_daemon_owns_supervision_no_alert() {
  local home base pid identity
  home=$(make_home away work)
  base=$(beat_of "$home")
  sleep 300 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || { kill "$pid" 2>/dev/null; fail "could not read the stand-in daemon's identity"; }
  printf 'away\n' > "$home/state/.afk"
  mkdir -p "$home/state/.supervise-daemon.lock"
  printf '%s\n' "$pid" > "$home/state/.supervise-daemon.lock/pid"
  printf '%s\n' "$identity" > "$home/state/.supervise-daemon.lock/pid-identity"
  check "$home" $((base + 950))
  check "$home" $((base + 1070))
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  [ ! -s "$home/alerts.log" ] \
    || fail "the checker alerted while a live away daemon owned supervision: $(cat "$home/alerts.log")"
  # The same flag with no live daemon is not ownership.
  check "$home" $((base + 1200))
  check "$home" $((base + 1320))
  [ "$(alert_count "$home")" = 1 ] \
    || fail "an away flag with a dead daemon suppressed the alert: $(cat "$home/alerts.log")"
  pass "a live away daemon suppresses the alert, a dead one does not"
}

test_work_ending_closes_episode_silently() {
  local home base
  home=$(make_home work-ends work)
  base=$(beat_of "$home")
  check "$home" $((base + 950))
  check "$home" $((base + 1070))
  rm -f "$home/state/task.meta"
  check "$home" $((base + 1190))
  [ ! -e "$home/state/.supervision-alert" ] \
    || fail "an episode stayed open after the home stopped needing supervision"
  [ "$(recovered_count "$home")" = 0 ] \
    || fail "work ending was reported as a recovery"
  pass "an episode closes silently when the home stops needing supervision"
}

test_check_only_observes() {
  local home base before after
  home=$(make_home observe work)
  base=$(beat_of "$home")
  printf '1\t1\tsignal\tk\tp\n' > "$home/state/.wake-queue"
  before=$(cd "$home/state" && find . -mindepth 1 -path ./.supervision-alert -prune -o -path ./.supervision-alert.log -prune -o -print | sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(mtime "$f")"
  done)
  check "$home" $((base + 950))
  check "$home" $((base + 1070))
  sleep 1
  touch "$home/state/.last-watcher-beat"
  base=$(beat_of "$home")
  before=$(printf '%s\n' "$before" | sed "s|^\./\.last-watcher-beat .*|./.last-watcher-beat $base|")
  check "$home" $((base + 5))
  after=$(cd "$home/state" && find . -mindepth 1 -path ./.supervision-alert -prune -o -path ./.supervision-alert.log -prune -o -print | sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(mtime "$f")"
  done)
  [ "$before" = "$after" ] \
    || fail "check changed state beyond its own record and log: before=[$before] after=[$after]"
  pass "check writes nothing but its own episode record and log"
}

test_off_channel_is_silent_but_records_episode() {
  local home base
  home=$(make_home off-channel work)
  base=$(beat_of "$home")
  printf 'off\n' > "$home/config/wedge-alarm"
  env -u FM_WEDGE_ALARM_CHANNEL -u FM_GUARD_GRACE -u FM_POLL FM_HOME="$home" FM_SUPERVISION_ALERT_NOW=$((base + 950)) \
    FM_WEDGE_ALARM_EXEC="$REC" FM_WEDGE_ALARM_LOG="$home/alerts.log" bash "$ALERT" check
  env -u FM_WEDGE_ALARM_CHANNEL -u FM_GUARD_GRACE -u FM_POLL FM_HOME="$home" FM_SUPERVISION_ALERT_NOW=$((base + 1070)) \
    FM_WEDGE_ALARM_EXEC="$REC" FM_WEDGE_ALARM_LOG="$home/alerts.log" bash "$ALERT" check
  [ ! -s "$home/alerts.log" ] || fail "config/wedge-alarm off still notified"
  grep -F 'phase=alerted' "$home/state/.supervision-alert" >/dev/null \
    || fail "an off channel skipped recording the episode"
  pass "config/wedge-alarm off silences the checker's channels too"
}

test_library_mode_defaults_to_discard() {
  local out
  # shellcheck disable=SC2016  # expands in the child shell
  out=$(env -u FM_WEDGE_ALARM_EXEC FM_HOME="$TMP_ROOT/lib-home" bash -c '. "$1"; printf "%s" "${FM_WEDGE_ALARM_EXEC:-UNSET}"' _ "$ALERT")
  [ "$out" = discard ] || fail "sourcing the checker did not default the notifier seam to discard (got: $out)"
  pass "sourcing the checker defaults the notifier seam to discard"
}

test_install_and_uninstall_with_stub_launchctl() {
  local home agents calls out plist
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP install/uninstall: launchd exists only on macOS"
    return 0
  fi
  home=$(make_home install)
  agents="$TMP_ROOT/install-agents"
  calls="$TMP_ROOT/install-launchctl.log"
  cat > "$TMP_ROOT/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_LAUNCHCTL_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/launchctl"
  out=$(FM_HOME="$home" FM_SUPERVISION_ALERT_LAUNCHD_DIR="$agents" \
    FM_SUPERVISION_ALERT_LAUNCHCTL="$TMP_ROOT/launchctl" FM_TEST_LAUNCHCTL_LOG="$calls" \
    bash "$ALERT" install --interval 90 --after 600) || fail "install failed: $out"
  plist=$(find "$agents" -name 'com.firstmate.supervision-alert.*.plist' | head -1)
  [ -n "$plist" ] || fail "install wrote no plist into $agents"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null || fail "install wrote an invalid plist: $(cat "$plist")"
    [ "$(plutil -extract StartInterval raw "$plist")" = 90 ] || fail "plist StartInterval is not the --interval"
    [ "$(plutil -extract EnvironmentVariables.FM_HOME raw "$plist")" = "$home" ] || fail "plist does not pin FM_HOME"
    [ "$(plutil -extract EnvironmentVariables.FM_SUPERVISION_ALERT_AFTER raw "$plist")" = 600 ] || fail "plist does not carry --after"
    [ "$(plutil -extract ProgramArguments.2 raw "$plist")" = check ] || fail "plist does not run check"
  fi
  grep -F "bootstrap gui/$(id -u) $plist" "$calls" >/dev/null || fail "install did not bootstrap the agent: $(cat "$calls")"
  out=$(FM_HOME="$home" FM_SUPERVISION_ALERT_LAUNCHD_DIR="$agents" bash "$ALERT" status)
  printf '%s\n' "$out" | grep -F "installed: $plist" >/dev/null || fail "status does not report the install: $out"
  FM_HOME="$home" FM_SUPERVISION_ALERT_LAUNCHD_DIR="$agents" \
    FM_SUPERVISION_ALERT_LAUNCHCTL="$TMP_ROOT/launchctl" FM_TEST_LAUNCHCTL_LOG="$calls" \
    bash "$ALERT" uninstall >/dev/null || fail "uninstall failed"
  [ ! -e "$plist" ] || fail "uninstall left the plist"
  grep -F "bootout gui/$(id -u)/$(basename "$plist" .plist)" "$calls" >/dev/null || fail "uninstall did not boot the agent out: $(cat "$calls")"
  pass "install writes and loads a home-scoped launchd agent; uninstall removes it"
}

test_install_refuses_off_macos() {
  local fakebin home out
  fakebin="$TMP_ROOT/fake-linux"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\necho Linux\n' > "$fakebin/uname"
  chmod +x "$fakebin/uname"
  home=$(make_home linux)
  if out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_ALERT_LAUNCHD_DIR="$TMP_ROOT/linux-agents" \
    FM_SUPERVISION_ALERT_LAUNCHCTL=false bash "$ALERT" install 2>&1); then
    fail "install succeeded on a non-macOS host: $out"
  fi
  printf '%s\n' "$out" | grep -F 'needs macOS launchd' >/dev/null || fail "install refusal does not name the missing scheduler: $out"
  [ ! -e "$TMP_ROOT/linux-agents" ] || fail "a refused install still wrote files"
  pass "install refuses off macOS and names why"
}

test_dead_past_threshold_alerts_once
test_still_dead_does_not_repeat
test_recovery_notifies_once
test_new_outage_after_recovery_alerts_again
test_no_live_work_no_alert
test_fresh_beacon_no_alert
test_stale_below_threshold_no_alert
test_beacon_that_beat_between_sightings_restarts_confirmation
test_absent_beacon_with_work_alerts
test_away_daemon_owns_supervision_no_alert
test_work_ending_closes_episode_silently
test_check_only_observes
test_off_channel_is_silent_but_records_episode
test_library_mode_defaults_to_discard
test_install_and_uninstall_with_stub_launchctl
test_install_refuses_off_macos
