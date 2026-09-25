#!/usr/bin/env bash
# fm-supervision-alert.sh - independent supervision-dead alert for one home.
#
# Usage:
#   bin/fm-supervision-alert.sh check
#   bin/fm-supervision-alert.sh install [--interval <secs>] [--after <secs>]
#   bin/fm-supervision-alert.sh uninstall
#   bin/fm-supervision-alert.sh status
#
# Every firstmate supervision model depends on the primary session staying able
# to re-arm its watcher. When that session dies quietly (a turn ending in an API
# error the harness runs no hook for, the machine sleeping mid-reply, a closed
# terminal), nothing inside firstmate can notice, because the thing that would
# notice is the thing that died. This checker runs OUTSIDE every agent session,
# as a macOS launchd user agent, and tells the captain through the active-alert
# channels of config/wedge-alarm (bin/fm-alert-lib.sh; docs/wedge-alarm.md owns
# the operator reference) when this home's watcher beacon has been dead long
# enough to matter.
#
# It only observes and notifies. It never arms a watcher, touches the session
# lock or the watcher lock, drains or reads the wake queue, types into any pane,
# or restarts anything. Its only writes are its own episode record and log.
#
# check - one observation, what the launchd agent runs every --interval seconds.
#   The beacon is state/.last-watcher-beat and freshness is the same predicate the
#   turn-end guard's away branch and the return brief apply: beacon age below the
#   guard grace (FM_GUARD_GRACE, else fm_poll_derived_grace from FM_POLL).
#   The alert fires once per outage episode when ALL of these hold:
#     - the home needs supervision (fm_supervision_status in
#       bin/fm-supervision-lib.sh owns that condition set: live work, a Relay
#       poll, a registered event source, or a registered custom check);
#     - no away daemon owns supervision (fm_afk_daemon_owns_supervision), since
#       that daemon runs its own wedge alarm;
#     - the beacon is at least FM_SUPERVISION_ALERT_AFTER seconds old (default
#       900), or absent;
#     - an earlier check of this same episode already saw the same beacon dead
#       at least FM_SUPERVISION_ALERT_CONFIRM seconds ago (default 60). The
#       second sighting keeps a machine waking from sleep from alerting in the
#       seconds before its still-healthy watcher beats again; it delays a real
#       alert by at most one interval.
#   A Claude auto-arm rewake (fm_autoarm_midturn_healthy) is deliberately NOT
#   treated as healthy: the incident this exists for left exactly that ledger
#   shape behind for nine hours. So a single handling turn that outlives the
#   threshold alerts too, and its end brings the recovered notice.
#   While alerted, later checks stay silent. The first check that sees a fresh
#   beacon sends one "recovered" notice and closes the episode. An episode whose
#   home stops needing supervision closes silently. Exit 0 on every outcome,
#   including a failed channel; exit 2 on a usage error.
#
# install - writes ~/Library/LaunchAgents/<label>.plist and loads it into the
#   captain's GUI launchd domain, replacing an earlier install of the same home.
#   The label is home-scoped (com.firstmate.supervision-alert.<cksum of FM_HOME>)
#   so every home on the machine can carry its own. The plist pins FM_HOME, the
#   installer's PATH (so a command: channel finds its tools), --after as
#   FM_SUPERVISION_ALERT_AFTER, and FM_POLL, FM_GUARD_GRACE, and
#   FM_SUPERVISION_ALERT_CONFIRM when they are set, and sends the agent's output
#   to the log below. --interval defaults to 120. Re-run install to change a knob.
#   macOS only; any other platform refuses naming the missing scheduler.
# uninstall - unloads the agent and removes its plist; absent is success.
# status - prints whether the agent is installed and the current episode record.
#
# Files (this script is their only writer):
#   state/.supervision-alert      episode record, key=value lines: phase
#                                 (suspect|alerted), beacon (mtime or none),
#                                 since (epoch of the first dead sighting),
#                                 alerted (epoch of the alert). Absent = no episode.
#   state/.supervision-alert.log  transitions only, trimmed to the last 200 lines.
#
# Environment:
#   FM_SUPERVISION_ALERT_AFTER    seconds a beacon must be dead before alerting
#                                 (default 900)
#   FM_SUPERVISION_ALERT_CONFIRM  minimum seconds between the two dead sightings
#                                 (default 60)
#   FM_SUPERVISION_ALERT_NOW      clock seam: epoch seconds to use as "now"
#   FM_SUPERVISION_ALERT_LAUNCHD_DIR  plist directory seam (default
#                                 ~/Library/LaunchAgents)
#   FM_SUPERVISION_ALERT_LAUNCHCTL    launchctl seam (default launchctl)
#   FM_WEDGE_ALARM_CHANNEL, FM_WEDGE_ALARM_EXEC, FM_WEDGE_ALARM_TIMEOUT_SECS
#                                 channel selection, notifier seam, and bound,
#                                 exactly as for the wedge alarm. When this file
#                                 is SOURCED the notifier seam defaults to
#                                 "discard", like the daemon's library mode.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-alert-lib.sh
. "$SCRIPT_DIR/fm-alert-lib.sh"

SUPALERT_RECORD="$STATE/.supervision-alert"
LOG="$STATE/.supervision-alert.log"
SUPALERT_LOG_KEEP=200
SUPALERT_AFTER_DEFAULT=900
SUPALERT_CONFIRM_DEFAULT=60
SUPALERT_INTERVAL_DEFAULT=120

log() {
  local tmp
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" -gt "$SUPALERT_LOG_KEEP" ]; then
    tmp="$LOG.tmp.$$"
    tail -n "$SUPALERT_LOG_KEEP" "$LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$LOG" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

supalert_usage() {
  sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

supalert_seconds() {  # <value> <default> -> a positive integer
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) if [ "$1" -gt 0 ] 2>/dev/null; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi ;;
  esac
}

supalert_now() {
  case "${FM_SUPERVISION_ALERT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_SUPERVISION_ALERT_NOW" ;;
  esac
}

supalert_duration() {  # <seconds> -> short human duration
  local s=$1
  if [ "$s" -ge 3600 ]; then
    printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm' $((s / 60))
  else
    printf '%ds' "$s"
  fi
}

# Sets SUPALERT_PHASE, SUPALERT_BEACON, and SUPALERT_SINCE from the episode
# record; all empty when there is no episode.
supalert_record_read() {
  local key value
  SUPALERT_PHASE=
  SUPALERT_BEACON=
  SUPALERT_SINCE=
  [ -f "$SUPALERT_RECORD" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      phase) SUPALERT_PHASE=$value ;;
      beacon) SUPALERT_BEACON=$value ;;
      since) SUPALERT_SINCE=$value ;;
    esac
  done < "$SUPALERT_RECORD"
  case "$SUPALERT_SINCE" in ''|*[!0-9]*) SUPALERT_SINCE=0 ;; esac
  case "$SUPALERT_PHASE" in suspect|alerted) ;; *) SUPALERT_PHASE= ;; esac
  return 0
}

supalert_record_write() {  # <phase> <beacon> <since> [alerted]
  local tmp="$SUPALERT_RECORD.tmp.$$"
  printf 'phase=%s\nbeacon=%s\nsince=%s\nalerted=%s\n' "$1" "$2" "$3" "${4:-}" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$SUPALERT_RECORD" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

supalert_record_clear() {
  rm -f "$SUPALERT_RECORD" 2>/dev/null
  return 0
}

supalert_work_desc() {
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    printf '%s task(s) in flight' "$FM_SUP_IN_FLIGHT"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    printf '%s event source(s) waiting' "$FM_SUP_SOURCES"
  elif [ "$FM_SUP_CHECKS" -gt 0 ]; then
    printf '%s custom check(s) registered' "$FM_SUP_CHECKS"
  else
    printf 'a Relay poll registered'
  fi
}

supalert_check() {
  local now grace after confirm beacon age dead_for
  now=$(supalert_now)
  grace=$(supalert_seconds "${FM_GUARD_GRACE:-}" "$(fm_poll_derived_grace)")
  after=$(supalert_seconds "${FM_SUPERVISION_ALERT_AFTER:-}" "$SUPALERT_AFTER_DEFAULT")
  confirm=$(supalert_seconds "${FM_SUPERVISION_ALERT_CONFIRM:-}" "$SUPALERT_CONFIRM_DEFAULT")
  supalert_record_read

  if beacon=$(fm_path_mtime "$STATE/.last-watcher-beat") && [ -n "$beacon" ]; then
    age=$((now - beacon))
  else
    beacon=none
    age=
  fi

  if [ -n "$age" ] && [ "$age" -lt "$grace" ]; then
    if [ "$SUPALERT_PHASE" = alerted ]; then
      case "$SUPALERT_BEACON" in
        ''|*[!0-9]*) dead_for="after an outage" ;;
        *) dead_for="after about $(supalert_duration $((now - age - SUPALERT_BEACON))) without a beat" ;;
      esac
      log "recovered: beacon fresh (${age}s old) ${dead_for}"
      WEDGE_ALARM_TITLE="firstmate: supervision recovered"
      wedge_alarm_notify "Supervision recovered in $FM_HOME: the watcher is beating again ${dead_for}." "$SUPALERT_RECORD"
    fi
    supalert_record_clear
    return 0
  fi

  fm_supervision_status "$STATE" "$grace"
  if [ "$FM_SUP_NEEDED" != true ]; then
    [ -z "$SUPALERT_PHASE" ] || log "episode closed without notice: the home no longer needs supervision"
    supalert_record_clear
    return 0
  fi

  # A live away daemon owns supervision and raises its own wedge alarm. An
  # already-alerted episode stays open (silently) until the beacon returns.
  if fm_afk_daemon_owns_supervision "$STATE"; then
    [ "$SUPALERT_PHASE" != suspect ] || supalert_record_clear
    return 0
  fi

  if [ -n "$age" ] && [ "$age" -lt "$after" ]; then
    [ "$SUPALERT_PHASE" != suspect ] || supalert_record_clear
    return 0
  fi

  case "$SUPALERT_PHASE" in
    alerted)
      return 0 ;;
    suspect)
      if [ "$SUPALERT_BEACON" != "$beacon" ]; then
        supalert_record_write suspect "$beacon" "$now"
        return 0
      fi
      [ $((now - SUPALERT_SINCE)) -ge "$confirm" ] || return 0
      ;;
    *)
      supalert_record_write suspect "$beacon" "$now"
      log "suspect: beacon ${age:-absent}${age:+s old}; confirming on the next check"
      return 0 ;;
  esac

  supalert_record_write alerted "$beacon" "$SUPALERT_SINCE" "$now"
  if [ -n "$age" ]; then
    dead_for="no watcher beat for $(supalert_duration "$age")"
  else
    dead_for="no watcher beat on record"
  fi
  log "alerted: ${dead_for}; $(supalert_work_desc)"
  WEDGE_ALARM_TITLE="firstmate: supervision DOWN"
  wedge_alarm_notify "Supervision is down in $FM_HOME: ${dead_for}, $(supalert_work_desc). Nothing will wake the firstmate session until it gets a message - open it and send one." "$SUPALERT_RECORD"
  return 0
}

# --- launchd install ----------------------------------------------------------

supalert_label() {
  printf 'com.firstmate.supervision-alert.%s\n' "$(printf '%s' "$FM_HOME" | cksum | awk '{print $1}')"
}

supalert_plist_path() {
  printf '%s/%s.plist\n' "${FM_SUPERVISION_ALERT_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}" "$(supalert_label)"
}

supalert_launchctl() {
  ${FM_SUPERVISION_ALERT_LAUNCHCTL:-launchctl} "$@"
}

supalert_require_macos() {
  [ "$(uname)" = Darwin ] && return 0
  printf 'fm-supervision-alert: install needs macOS launchd; no scheduler is supported on %s yet\n' "$(uname)" >&2
  return 1
}

supalert_xml() {  # <text> -> XML-escaped
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

supalert_plist_env() {  # <name> <value>
  printf '    <key>%s</key><string>%s</string>\n' "$1" "$(supalert_xml "$2")"
}

supalert_install() {
  local interval=$SUPALERT_INTERVAL_DEFAULT after=${FM_SUPERVISION_ALERT_AFTER:-$SUPALERT_AFTER_DEFAULT}
  local label plist dir tmp domain
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ "$#" -ge 2 ] || { supalert_usage >&2; return 2; }; interval=$2; shift 2 ;;
      --after) [ "$#" -ge 2 ] || { supalert_usage >&2; return 2; }; after=$2; shift 2 ;;
      *) supalert_usage >&2; return 2 ;;
    esac
  done
  case "$interval" in ''|*[!0-9]*|0) printf 'fm-supervision-alert: --interval must be a positive number of seconds\n' >&2; return 2 ;; esac
  case "$after" in ''|*[!0-9]*|0) printf 'fm-supervision-alert: --after must be a positive number of seconds\n' >&2; return 2 ;; esac
  supalert_require_macos || return 1
  label=$(supalert_label)
  plist=$(supalert_plist_path)
  dir=${plist%/*}
  mkdir -p "$dir" "$STATE" || return 1
  tmp="$plist.tmp.$$"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$label"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    printf '    <string>/bin/bash</string>\n'
    printf '    <string>%s</string>\n' "$(supalert_xml "$SCRIPT_DIR/fm-supervision-alert.sh")"
    printf '    <string>check</string>\n'
    printf '  </array>\n'
    printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
    supalert_plist_env FM_HOME "$FM_HOME"
    supalert_plist_env PATH "${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
    supalert_plist_env FM_SUPERVISION_ALERT_AFTER "$after"
    [ -z "${FM_SUPERVISION_ALERT_CONFIRM:-}" ] || supalert_plist_env FM_SUPERVISION_ALERT_CONFIRM "$FM_SUPERVISION_ALERT_CONFIRM"
    [ -z "${FM_POLL:-}" ] || supalert_plist_env FM_POLL "$FM_POLL"
    [ -z "${FM_GUARD_GRACE:-}" ] || supalert_plist_env FM_GUARD_GRACE "$FM_GUARD_GRACE"
    printf '  </dict>\n'
    printf '  <key>StartInterval</key><integer>%s</integer>\n' "$interval"
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(supalert_xml "$LOG")"
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(supalert_xml "$LOG")"
    printf '</dict>\n</plist>\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$plist" || { rm -f "$tmp"; return 1; }
  domain="gui/$(id -u)"
  supalert_launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  if ! supalert_launchctl bootstrap "$domain" "$plist"; then
    printf 'fm-supervision-alert: launchctl bootstrap %s %s failed; the plist is written but not loaded\n' "$domain" "$plist" >&2
    return 1
  fi
  printf 'installed %s: checks %s every %ss, alerts after %ss dead\n' "$label" "$FM_HOME" "$interval" "$after"
}

supalert_uninstall() {
  local label plist
  supalert_require_macos || return 1
  label=$(supalert_label)
  plist=$(supalert_plist_path)
  supalert_launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  rm -f "$plist" || return 1
  printf 'uninstalled %s\n' "$label"
}

supalert_status() {
  local plist
  plist=$(supalert_plist_path)
  if [ -f "$plist" ]; then
    printf 'installed: %s\n' "$plist"
  else
    printf 'installed: no\n'
  fi
  if [ -f "$SUPALERT_RECORD" ]; then
    printf 'episode:\n'
    sed 's/^/  /' "$SUPALERT_RECORD"
  else
    printf 'episode: none\n'
  fi
}

supalert_main() {
  local cmd=${1:-}
  [ "$#" -eq 0 ] || shift
  case "$cmd" in
    check) [ "$#" -eq 0 ] || { supalert_usage >&2; return 2; }; supalert_check ;;
    install) supalert_install "$@" ;;
    uninstall) supalert_uninstall ;;
    status) supalert_status ;;
    -h|--help|help) supalert_usage ;;
    *) supalert_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  supalert_main "$@"
  exit $?
else
  # Library mode: a sourced context (only tests do this) must never post a real
  # notification, so the notifier seam defaults to "discard" unless the embedder
  # already wired a recorder.
  : "${FM_WEDGE_ALARM_EXEC:=discard}"
  export FM_WEDGE_ALARM_EXEC
fi
