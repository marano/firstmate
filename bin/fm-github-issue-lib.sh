#!/usr/bin/env bash
# fm-github-issue-lib.sh - the single owner of firstmate's one-way GitHub issue
# mirror.
#
# Sourced, never executed.
#
# WHY IT EXISTS. The backlog is private and readable only through firstmate. A
# chosen item can be mirrored as a public GitHub issue, so its progress is
# readable without firstmate running and its pull request links to it. The
# backlog stays authoritative: the issue is a projection of it, written by
# firstmate and never read back. An edit or comment made on the issue changes
# nothing here, and nothing here ever reads an issue this home did not record.
#
# THE IDENTIFIER. A backlog item that is mirrored carries its issue as one
# `GitHub issue: marano/firstmate#123` line in its own body, in the same
# namespaced shape as bin/fm-linear-lib.sh's `Linear card:` line, so imported
# prose cannot collide with it. `bin/fm-tasks-axi.sh issue` records and reads
# it and carries it across a body rewrite, and `bin/fm-tasks-axi.sh publish`
# creates the issue and records it. Two such lines are refused rather than
# resolved by position. The line always names the repository, so every call
# below addresses exactly that repository and no firstmate id is ever resolved
# by searching GitHub.
#
# OPT-IN PER ITEM. Nothing is mirrored unless it was published deliberately.
# An item with no issue line is untouched and unmentioned: this library makes
# no call and prints nothing for it, so a home that never publishes anything
# never hears of the mirror. The issue's title and text are the public-safe
# summary written for it at publish time, never the item's private body.
#
# THE MOVES. Each one follows a backlog transition that has already happened:
#   start    dispatch moved the row In flight: add the in-progress label.
#   merge    the pull request merged: close the issue as completed and drop the
#            label. Firstmate closes it itself, which is why a worker writes
#            `Refs` and never a closing keyword in the pull request body.
#   requeue  cleanup's requeue, a handback, or `fm-tasks-axi.sh requeue`
#            returned the row to Queued: reopen the issue and drop the label.
# Every move sets the state the backlog implies without reading the issue
# first, so a repeated move converges on the same result.
#
# A FAILURE NEVER FAILS THE CALLER. The same rule as fm_linear_board_advance:
# the worker starting, the pull request landing, and the row returning to the
# queue all matter more than the mirror. fm_github_issue_advance always
# succeeds; a transport or API failure is reported as an `actionable:` line on
# stderr. It runs only after the local transition, so it can never gate one.
#
# It defines:
#   fm_github_issue_repo_valid <owner/repo>  - is this a repository name
#   fm_github_issue_ref_valid <value>        - is this an owner/repo#N reference
#   fm_github_issue_of_body <body>           - the issue a decoded body carries
#   fm_github_issue_of_row <data> <id>       - the issue a backlog item carries
#   fm_github_issue_gh <args...>             - one bounded gh call
#   fm_github_issue_create <repo> <title> <body-file> - publish; FM_GITHUB_ISSUE_NUMBER
#   fm_github_issue_advance <data> <phase> <id>... - the move entry point
#
# THE INJECTABLE SEAM. fm_github_issue_gh runs `gh` with the arguments it is
# given, unless FM_GITHUB_ISSUE_CMD names a command, which is then run in its
# place with the same arguments and must answer as `gh` would. Every call is
# `gh api` against an explicit `repos/<owner>/<repo>/...` path, so the
# repository is always named and never resolved from a checkout's remotes. Both
# paths are bounded by bin/fm-timeout-lib.sh's fm_run_timed
# (FM_GITHUB_ISSUE_TIMEOUT, default 20 seconds), so a wedged transport cannot
# hold a dispatch, a merge, or a cleanup open. Tests reach every behavior
# through that seam, because they cannot call GitHub.
set -u

# Each dependency is guarded on a function of ITS OWN; bin/fm-linear-lib.sh
# explains why a shared guard is wrong.
_FM_GITHUB_ISSUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v fm_tasks_axi_backend >/dev/null 2>&1; then
  # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
  . "$_FM_GITHUB_ISSUE_LIB_DIR/fm-tasks-axi-lib.sh"
fi
if ! command -v fm_backlog_row_field >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
  . "$_FM_GITHUB_ISSUE_LIB_DIR/fm-backlog-transition-lib.sh"
fi
if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$_FM_GITHUB_ISSUE_LIB_DIR/fm-timeout-lib.sh"
fi

# The body line that carries the issue. See THE IDENTIFIER above.
FM_GITHUB_ISSUE_PREFIX="GitHub issue: "
# The label a dispatched item's issue carries while its worker is running.
FM_GITHUB_ISSUE_LABEL="in progress"

FM_GITHUB_ISSUE_REF=
FM_GITHUB_ISSUE_NUMBER=
FM_GITHUB_ISSUE_ERROR=
FM_GITHUB_ISSUE_RESPONSE=

# A GitHub repository as owner/name. The grammar is GitHub's own character set
# and deliberately narrow: the value reaches a body line and an API path.
fm_github_issue_repo_valid() {  # <owner/repo>
  local value=${1-} owner name
  local LC_ALL=C
  case "$value" in
    */*/* | /* | */) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  owner=${value%%/*}
  name=${value#*/}
  case "$owner" in
    '' | -* | *[!A-Za-z0-9-]*) return 1 ;;
  esac
  case "$name" in
    '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#owner}" -le 39 ] && [ "${#name}" -le 100 ]
}

# A reference as GitHub prints one across repositories: owner/repo#123. A
# sentence that merely mentions an issue is not a line whose whole value is one.
fm_github_issue_ref_valid() {  # <value>
  local value=${1-} repo number
  local LC_ALL=C
  case "$value" in
    *'#'*'#'* | *'#') return 1 ;;
    *'#'[1-9]*) ;;
    *) return 1 ;;
  esac
  repo=${value%%#*}
  number=${value#*#}
  case "$number" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#number}" -le 12 ] && fm_github_issue_repo_valid "$repo"
}

# The issue a decoded body carries, printed empty when it carries none. TWO
# issue lines are refused (status 2) rather than resolved by position, the same
# rule bin/fm-linear-lib.sh gives a card.
fm_github_issue_of_body() {  # <body>
  local body=${1-} line ref='' seen=0
  while IFS= read -r line; do
    case "$line" in
      "$FM_GITHUB_ISSUE_PREFIX"*)
        seen=$((seen + 1))
        ref=${line#"$FM_GITHUB_ISSUE_PREFIX"}
        ;;
    esac
  done <<EOF
$body
EOF
  [ "$seen" -le 1 ] || return 2
  printf '%s\n' "$ref"
}

# The issue recorded on <id>, in FM_GITHUB_ISSUE_REF (empty when it has none).
# Status: 0 read, 1 the body is unusable, 2 cannot tell, 3 no such row.
fm_github_issue_of_row() {  # <data-dir> <id>
  local data=$1 id=$2 status ref
  FM_GITHUB_ISSUE_REF=
  FM_GITHUB_ISSUE_ERROR=
  status=0
  fm_backlog_row_field "$data" "$id" body || status=$?
  case "$status" in
    0) ;;
    3) FM_GITHUB_ISSUE_ERROR="$id has no backlog item in this home"; return 3 ;;
    *)
      FM_GITHUB_ISSUE_ERROR="${FM_BACKLOG_TRANSITION_ERROR:-cannot read the body of $id}"
      return 2
      ;;
  esac
  ref=$(fm_github_issue_of_body "$FM_BACKLOG_ROW_FIELD_VALUE") || {
    FM_GITHUB_ISSUE_ERROR="$id carries more than one '${FM_GITHUB_ISSUE_PREFIX%%:*}' line; leave exactly one"
    return 1
  }
  if [ -n "$ref" ] && ! fm_github_issue_ref_valid "$ref"; then
    FM_GITHUB_ISSUE_ERROR="$id carries an unreadable GitHub issue '$ref'; an issue reads like marano/firstmate#123"
    return 1
  fi
  FM_GITHUB_ISSUE_REF=$ref
}

# One bounded gh call. Its stdout lands in FM_GITHUB_ISSUE_RESPONSE rather than
# on stdout, for the reason bin/fm-linear-lib.sh's fm_linear_request gives: a
# command substitution would run this in a subshell and lose FM_GITHUB_ISSUE_ERROR.
# Status 1 with FM_GITHUB_ISSUE_ERROR set (gh's first error line, or the bound)
# on any failure.
fm_github_issue_gh() {  # <gh args...>
  local bound out_file err_file status detail
  local -a cmd
  FM_GITHUB_ISSUE_ERROR=
  FM_GITHUB_ISSUE_RESPONSE=
  bound=${FM_GITHUB_ISSUE_TIMEOUT:-20}
  case "$bound" in
    '' | *[!0-9]* | 0) bound=20 ;;
  esac
  if [ -n "${FM_GITHUB_ISSUE_CMD:-}" ]; then
    cmd=("$FM_GITHUB_ISSUE_CMD")
  else
    command -v gh >/dev/null 2>&1 || {
      FM_GITHUB_ISSUE_ERROR="gh is needed to talk to GitHub and is not on PATH"
      return 1
    }
    cmd=(gh)
  fi
  out_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-github-issue.XXXXXX") || {
    FM_GITHUB_ISSUE_ERROR="cannot stage the GitHub call"
    return 1
  }
  err_file="$out_file.err"
  status=0
  fm_run_timed "$bound" "${cmd[@]}" "$@" > "$out_file" 2> "$err_file" || status=$?
  FM_GITHUB_ISSUE_RESPONSE=$(cat "$out_file" 2>/dev/null) || FM_GITHUB_ISSUE_RESPONSE=''
  detail=$(grep -m1 '[^[:space:]]' "$err_file" 2>/dev/null) || detail=''
  rm -f -- "$out_file" "$err_file"
  if [ "$status" -eq 124 ]; then
    FM_GITHUB_ISSUE_ERROR="GitHub did not answer within ${bound}s"
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    FM_GITHUB_ISSUE_ERROR="${detail:-the call to GitHub failed (status $status)}"
    return 1
  fi
}

# Publish: create one issue on <repo> from a public-safe title and body file,
# printing nothing. Its number lands in FM_GITHUB_ISSUE_NUMBER. Status 1 with
# FM_GITHUB_ISSUE_ERROR set when the issue was not created or its number cannot
# be read; the caller records nothing in either case.
fm_github_issue_create() {  # <owner/repo> <title> <body-file>
  local repo=$1 title=$2 body_file=$3 number
  FM_GITHUB_ISSUE_NUMBER=
  command -v jq >/dev/null 2>&1 || {
    FM_GITHUB_ISSUE_ERROR="jq is needed to read GitHub's answer and is not on PATH"
    return 1
  }
  fm_github_issue_gh api -X POST "repos/$repo/issues" \
    -f "title=$title" -F "body=@$body_file" || return 1
  number=$(printf '%s' "$FM_GITHUB_ISSUE_RESPONSE" | jq -r '.number // empty' 2>/dev/null) || number=''
  case "$number" in
    '' | *[!0-9]*)
      FM_GITHUB_ISSUE_ERROR="GitHub answered the issue creation without an issue number, so nothing was recorded; check $repo for a new issue before publishing again"
      return 1
      ;;
  esac
  # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
  FM_GITHUB_ISSUE_NUMBER=$number
}

# Drop the in-progress label. A label the issue does not carry is already the
# wanted state, so GitHub's 404 for it is success.
_fm_github_issue_unlabel() {  # <repo> <number>
  local label
  label=$(printf '%s' "$FM_GITHUB_ISSUE_LABEL" | sed 's/ /%20/g')
  fm_github_issue_gh api -X DELETE "repos/$1/issues/$2/labels/$label" && return 0
  case "$FM_GITHUB_ISSUE_ERROR" in
    *'HTTP 404'*) return 0 ;;
  esac
  return 1
}

# Apply one move to one recorded issue. Prints its own outcome line and returns
# 0 for every outcome; see fm_github_issue_advance.
_fm_github_issue_move() {  # <phase> <task-id> <owner/repo#N>
  local phase=$1 task=$2 ref=$3 repo number
  repo=${ref%%#*}
  number=${ref#*#}
  case "$phase" in
    start)
      if ! fm_github_issue_gh api -X POST "repos/$repo/issues/$number/labels" \
        -f "labels[]=$FM_GITHUB_ISSUE_LABEL"; then
        printf 'actionable: the GitHub issue %s recorded on %s could not be labelled %s: %s\n' \
          "$ref" "$task" "$FM_GITHUB_ISSUE_LABEL" "$FM_GITHUB_ISSUE_ERROR" >&2
        return 0
      fi
      printf 'github-issue: %s labelled %s\n' "$ref" "$FM_GITHUB_ISSUE_LABEL"
      ;;
    merge)
      if ! fm_github_issue_gh api -X PATCH "repos/$repo/issues/$number" \
        -f state=closed -f state_reason=completed; then
        printf 'actionable: the GitHub issue %s recorded on %s could not be closed: %s\n' \
          "$ref" "$task" "$FM_GITHUB_ISSUE_ERROR" >&2
        return 0
      fi
      if ! _fm_github_issue_unlabel "$repo" "$number"; then
        printf 'actionable: the GitHub issue %s was closed, but its %s label could not be removed: %s\n' \
          "$ref" "$FM_GITHUB_ISSUE_LABEL" "$FM_GITHUB_ISSUE_ERROR" >&2
        return 0
      fi
      printf 'github-issue: %s closed\n' "$ref"
      ;;
    requeue)
      if ! fm_github_issue_gh api -X PATCH "repos/$repo/issues/$number" -f state=open; then
        printf 'actionable: the GitHub issue %s recorded on %s could not be reopened: %s\n' \
          "$ref" "$task" "$FM_GITHUB_ISSUE_ERROR" >&2
        return 0
      fi
      if ! _fm_github_issue_unlabel "$repo" "$number"; then
        printf 'actionable: the GitHub issue %s is open, but its %s label could not be removed: %s\n' \
          "$ref" "$FM_GITHUB_ISSUE_LABEL" "$FM_GITHUB_ISSUE_ERROR" >&2
        return 0
      fi
      printf 'github-issue: %s reopened as queued\n' "$ref"
      ;;
  esac
}

# THE ENTRY POINT. Apply <phase> (`start`, `merge`, or `requeue`) to every named
# item's recorded issue. ALWAYS returns 0, and suspends errexit for its body,
# for the reasons fm_linear_board_advance gives: a caller adds this line without
# guarding it. Silent for an item that carries no issue.
fm_github_issue_advance() {  # <data-dir> <phase> <task-id>...
  local errexit=0
  case $- in *e*) errexit=1; set +e ;; esac
  _fm_github_issue_advance_each "$@"
  [ "$errexit" -eq 0 ] || set -e
  return 0
}

_fm_github_issue_advance_each() {  # <data-dir> <phase> <task-id>...
  local data=$1 phase=$2 task status data_abs
  shift 2
  [ "$#" -gt 0 ] || return 0
  case "$phase" in
    start | merge | requeue) ;;
    *) return 0 ;;
  esac
  # A home that keeps no backlog has no item that could carry an issue, so it
  # hears nothing; a backlog that exists but cannot be read is a failure.
  data_abs=$(fm_backlog_data_absolute "$data" 2>/dev/null) || return 0
  fm_backlog_source_present "$data_abs" "$data" >/dev/null 2>&1 || return 0
  for task in "$@"; do
    fm_github_issue_of_row "$data" "$task"
    status=$?
    case "$status" in
      0) ;;
      3) continue ;;
      *) printf 'actionable: the GitHub issue of %s could not be read: %s\n' "$task" "$FM_GITHUB_ISSUE_ERROR" >&2; continue ;;
    esac
    [ -n "$FM_GITHUB_ISSUE_REF" ] || continue
    _fm_github_issue_move "$phase" "$task" "$FM_GITHUB_ISSUE_REF"
  done
}
