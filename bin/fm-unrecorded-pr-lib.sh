#!/usr/bin/env bash
# fm-unrecorded-pr-lib.sh - the single owner of the unrecorded-PR condition: a
# task of this home whose branch has an OPEN pull request on the forge while
# the task's own record carries no pr=.
#
# Sourced, never executed. bin/fm-watch.sh owns the cadence, the re-surface
# window, and the wake (unrecorded_pr_tick); this file owns only what the
# condition IS and how its two sides are read.
#
# WHY THIS EXISTS. bin/fm-pr-check.sh records pr= and arms the merge poll, but
# only when firstmate handles the worker's ready line. A worker that opens a PR
# and then goes quiet - waiting on CI, blocked on its own background call, or
# not yet at its done report - leaves an open PR that nothing watches: the
# captain is not told, the merge poll is not armed, and the PR can go green and
# sit, or go red unnoticed. 2026-09-17 had four occurrences, one during an away
# window where the PR went red with nobody looking. The heartbeat review in
# AGENTS.md section 8 already owed this comparison; nothing performed it.
# bin/fm-awaiting-landing-lib.sh even reads a done, deliberately stopped task
# with no PR recorded as quiet awaiting-landing, so this is the only component
# that notices when such a task in fact has a PR.
#
# THE TWO SIDES.
#   recorded - every state/<id>.meta of this home whose kind is ship (an empty
#       kind is ship; bin/fm-task-kind-lib.sh), with no remote_host= (a remote
#       secondmate's record lives on its own host), no pr= recorded, and a
#       worktree= checked out on a named branch whose origin is a GitHub
#       repository. A task with no branch yet, or no worktree, is the ordinary
#       case and is simply not a candidate.
#   forge - ONE query per sweep, never one per task: the open pull requests the
#       authenticated GitHub account opened, keyed by base repository and head
#       branch. It runs only when at least one candidate exists, so a fleet
#       whose every PR is recorded costs no network at all.
# A candidate whose (repository, branch) matches an open PR is the condition.
# A branch with no open PR - including one whose PR was closed or merged - is
# silent.
#
# DETECTION ONLY, AND DELIBERATELY SO. Nothing here records pr=, arms a merge
# poll, or touches a task. Recording a PR binds a task to a forge identity and
# is an authority-carrying act; a detector that did it from forge state alone
# would bind a task to a PR nobody verified. The wake names the task and the PR
# so firstmate verifies it and records it through bin/fm-pr-check.sh.
#
# GitHub only: other forges are not queried, so their tasks stay silent here.
#
# No side effects on source. set -u safe.

if [ -n "${FM_UNRECORDED_PR_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_UNRECORDED_PR_LIB_SOURCED=1

_FM_UNRECORDED_PR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_UNRECORDED_PR_DIR/fm-timeout-lib.sh"
unset _FM_UNRECORDED_PR_DIR

# Seconds the one forge query may take before the sweep gives up on it.
FM_UNRECORDED_PR_TIMEOUT=${FM_UNRECORDED_PR_TIMEOUT:-}
case "$FM_UNRECORDED_PR_TIMEOUT" in ''|*[!0-9]*|0) FM_UNRECORDED_PR_TIMEOUT=20 ;; esac

# One meta field's last recorded value, or the empty string.
_fm_unrecorded_pr_meta() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# owner/repo of a GitHub remote URL (https, ssh, or scp form), or empty.
fm_unrecorded_pr_repo_slug() {  # <remote-url>
  printf '%s' "${1-}" | sed -n 's#^.*github\.com[:/]\([^/][^/]*/[^/][^/]*\)$#\1#p' | sed 's#\.git$##; s#/$##'
}

# The recorded side: one `<task>\t<owner/repo>\t<branch>` line per candidate.
fm_unrecorded_pr_candidates() {  # <state-dir>
  local state=${1-} meta id kind wt branch origin slug
  [ -n "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    kind=$(_fm_unrecorded_pr_meta "$meta" kind)
    case "$kind" in ''|ship) ;; *) continue ;; esac
    [ -z "$(_fm_unrecorded_pr_meta "$meta" remote_host)" ] || continue
    [ -z "$(_fm_unrecorded_pr_meta "$meta" pr)" ] || continue
    wt=$(_fm_unrecorded_pr_meta "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || continue
    [ -n "$branch" ] || continue
    origin=$(git -C "$wt" remote get-url origin 2>/dev/null) || continue
    slug=$(fm_unrecorded_pr_repo_slug "$origin")
    [ -n "$slug" ] || continue
    printf '%s\t%s\t%s\n' "$id" "$slug" "$branch"
  done
}

# The forge side: one `<owner/repo>\t<head-branch>\t<url>` line per open PR the
# authenticated account opened. Non-zero when the query cannot be answered, so
# a caller never mistakes an unreachable forge for "no open PRs".
fm_unrecorded_pr_open_prs() {
  command -v gh >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016 # GraphQL and jq text, not shell expansions.
  fm_run_timed "$FM_UNRECORDED_PR_TIMEOUT" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh api graphql \
      -f query='query { viewer { pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { url headRefName repository { nameWithOwner } } } } }' \
      --jq '.data.viewer.pullRequests.nodes[] | [.repository.nameWithOwner, .headRefName, .url] | @tsv' \
      2>/dev/null
}

# THE condition: one `<task>\t<pr-url>\t<branch>` line per candidate whose
# branch has an open PR. Returns 0 with no output when there is nothing to
# report (including when there are no candidates, which skips the forge), and 2
# when the forge query failed, so the caller can log instead of alarming.
fm_unrecorded_pr_scan() {  # <state-dir>
  local state=${1-} candidates prs
  candidates=$(fm_unrecorded_pr_candidates "$state")
  [ -n "$candidates" ] || return 0
  prs=$(fm_unrecorded_pr_open_prs) || return 2
  [ -n "$prs" ] || return 0
  awk -F '\t' '
    NR == FNR { if ($1 != "" && $2 != "" && $3 != "") open[$1 "\t" $2] = $3; next }
    ($2 "\t" $3) in open { printf "%s\t%s\t%s\n", $1, open[$2 "\t" $3], $3 }
  ' <(printf '%s\n' "$prs") <(printf '%s\n' "$candidates")
}
