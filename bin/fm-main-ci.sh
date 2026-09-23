#!/usr/bin/env bash
# Watch the default branch's own CI run for the commit a merge produced.
#
# A task's merge poll retires the moment its pull request is reported merged,
# so without this nothing watches the run the base branch then starts on the
# merge commit, and a red base branch is found only by someone remembering to
# look. bin/fm-pr-merge.sh calls `arm` after the forge has confirmed a merge,
# and the watcher's ordinary custom-check sweep runs the result every
# FM_CHECK_INTERVAL.
#
#   fm-main-ci.sh arm <pr-url>
#     Reads the merged pull request's merge commit and base branch from the
#     forge, then writes state/main-ci-<merge-sha>.check.sh and binds its bytes
#     through bin/fm-check-register.sh. Every value the poll needs is written
#     into that check as a quoted argument, so the trust binding covers them and
#     no sidecar exists. The id is the merge commit, never the task, so the
#     watch outlives the task's cleanup and keeps supervision required
#     (bin/fm-supervision-lib.sh counts registered checks) until it retires.
#     Arming never fails a merge: every failure prints one `actionable:` line on
#     stderr and exits 0. Only GitHub is watched; a GitLab merge reports that it
#     is not.
#     FM_MAIN_CI_APPEAR_SECS (default 1800) bounds how long the watch waits for
#     any run of the merge commit to appear; FM_MAIN_CI_CONCLUDE_SECS (default
#     21600) bounds the whole watch. Both are fixed into the check at arm time.
#
#   fm-main-ci.sh poll <state-dir> <id> <owner/repo> <branch> <sha> <pr-url> <appear-by> <conclude-by>
#     Run only by the armed check. It lists the push-event workflow runs whose
#     head commit is exactly <sha> on <branch>, so a later push to the branch
#     can never stand in for the run this merge caused, and then:
#       - any concluded run that is not success, neutral, or skipped: prints one
#         line naming the repository, branch, merge commit, pull request, and
#         each such run's URL, and retires the watch;
#       - every run concluded green: retires silently;
#       - no run yet and <appear-by> passed: prints one line saying so, retires;
#       - anything still open (runs in progress, or the forge unreadable) when
#         <conclude-by> passes: prints one line saying so, retires;
#       - otherwise prints nothing and stays armed.
#     A forge read failure before a deadline is silent, like the PR poll's.
#     Retirement goes through bin/fm-check-unregister.sh; a retirement that fails
#     is named in the printed line, because the check then reports again.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

main_ci_sha_valid() {
  [[ "${1-}" =~ ^[0-9a-f]{40}$ ]]
}

main_ci_branch_valid() {
  local branch=${1-}
  local LC_ALL=C
  [[ "$branch" =~ ^[A-Za-z0-9._/-]{1,255}$ ]] || return 1
  case "$branch" in -*|*..*|/*|*/) return 1 ;; esac
}

main_ci_seconds_valid() {
  [[ "${1-}" =~ ^[0-9]{1,12}$ ]]
}

main_ci_arm() {
  local url=$1 state appear conclude pr_fields merged sha base now id check tmp
  if ! fm_pr_url_parse "$url"; then
    echo "error: invalid main CI watch request" >&2
    exit 2
  fi
  url=$FM_PR_URL
  if [ "$FM_PR_PROVIDER" != github ]; then
    printf 'actionable: merged %s but its target branch CI is not watched: only GitHub runs can be watched\n' "$url" >&2
    return 0
  fi
  state="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  appear=${FM_MAIN_CI_APPEAR_SECS:-1800}
  conclude=${FM_MAIN_CI_CONCLUDE_SECS:-21600}
  if ! main_ci_seconds_valid "$appear" || ! main_ci_seconds_valid "$conclude"; then
    printf 'actionable: merged %s but its target branch CI is not watched: FM_MAIN_CI_APPEAR_SECS and FM_MAIN_CI_CONCLUDE_SECS must be whole seconds\n' "$url" >&2
    return 0
  fi
  if ! pr_fields=$(gh api "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER" \
    --jq '[(.merged | tostring), (.merge_commit_sha // "-"), (.base.ref // "-")] | @tsv' 2>/dev/null); then
    printf 'actionable: merged %s but its target branch CI is not watched: the merge commit could not be read\n' "$url" >&2
    return 0
  fi
  IFS=$'\t' read -r merged sha base <<<"$pr_fields" || true
  if [ "$merged" != true ] || ! main_ci_sha_valid "$sha" || ! main_ci_branch_valid "$base"; then
    printf 'actionable: merged %s but its target branch CI is not watched: the forge did not report a merge commit and base branch\n' "$url" >&2
    return 0
  fi
  now=$(date +%s)
  id="main-ci-$sha"
  check="$state/$id.check.sh"
  [ -d "$state" ] && [ ! -L "$state" ] || {
    printf 'actionable: merged %s but its target branch CI is not watched: the state directory is unavailable\n' "$url" >&2
    return 0
  }
  umask 077
  tmp=$(mktemp "$state/.fm-main-ci.XXXXXX") || {
    printf 'actionable: merged %s but its target branch CI is not watched: the watch could not be written\n' "$url" >&2
    return 0
  }
  if ! {
    printf '#!/usr/bin/env bash\n'
    printf '# Target branch CI watch for the merge commit of %s; written by bin/fm-main-ci.sh arm.\n' "$url"
    printf 'exec bash %q poll %q %q %q %q %q %q %q %q\n' \
      "$SCRIPT_DIR/fm-main-ci.sh" "$state" "$id" "$FM_PR_OWNER/$FM_PR_REPO" "$base" "$sha" "$url" \
      "$((now + appear))" "$((now + conclude))"
  } > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$check"; then
    rm -f -- "$tmp"
    printf 'actionable: merged %s but its target branch CI is not watched: the watch could not be written\n' "$url" >&2
    return 0
  fi
  if ! FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-check-register.sh" "$id" >/dev/null 2>&1; then
    rm -f -- "$check"
    printf 'actionable: merged %s but its target branch CI is not watched: the watch could not be registered\n' "$url" >&2
    return 0
  fi
  printf 'armed: %s CI watch on %s at %s (state/%s.check.sh)\n' "$base" "$FM_PR_OWNER/$FM_PR_REPO" "$sha" "$id"
}

main_ci_retire() {
  local state=$1 id=$2
  if FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-check-unregister.sh" "$id" >/dev/null 2>&1; then
    printf 'watch retired'
  else
    printf 'its watch could not be retired and will report again'
  fi
}

main_ci_poll() {
  local state=$1 id=$2 repo=$3 branch=$4 sha=$5 url=$6 appear_by=$7 conclude_by=$8
  local runs status conclusion run_url name now reds='' open='' total=0 retired
  if ! fm_pr_task_id_valid "$id" || [ "$id" != "main-ci-$sha" ] || ! main_ci_sha_valid "$sha" \
    || ! main_ci_branch_valid "$branch" || ! fm_pr_url_parse "$url" \
    || [ "$repo" != "$FM_PR_OWNER/$FM_PR_REPO" ] \
    || ! main_ci_seconds_valid "$appear_by" || ! main_ci_seconds_valid "$conclude_by" \
    || [ -z "$state" ] || [ ! -d "$state" ]; then
    printf 'main CI watch %s is malformed and cannot poll; retire it with bin/fm-check-unregister.sh %s\n' "$id" "$id"
    return 0
  fi
  now=$(date +%s)
  if runs=$(gh api -X GET "repos/$repo/actions/runs" \
    -f head_sha="$sha" -f branch="$branch" -f event=push -F per_page=100 \
    --jq ".workflow_runs[] | select(.head_sha == \"$sha\") | [.status, (.conclusion // \"-\"), .html_url, .name] | @tsv" \
    2>/dev/null); then
    while IFS=$'\t' read -r status conclusion run_url name; do
      [ -n "$status" ] || continue
      total=$((total + 1))
      if [ "$status" != completed ]; then
        open="${open:+$open, }$name ($status) $run_url"
        continue
      fi
      case "$conclusion" in
        success|neutral|skipped) ;;
        -) reds="${reds:+$reds; }$name completed without a conclusion: $run_url" ;;
        *) reds="${reds:+$reds; }$name concluded $conclusion: $run_url" ;;
      esac
    done <<<"$runs"
  else
    open="the forge's run list could not be read"
    total=-1
  fi

  if [ -n "$reds" ]; then
    retired=$(main_ci_retire "$state" "$id")
    printf 'main CI red after merge: %s %s at %s (merged from %s) - %s; %s\n' \
      "$repo" "$branch" "$sha" "$url" "$reds" "$retired"
  elif [ "$total" -gt 0 ] && [ -z "$open" ]; then
    main_ci_retire "$state" "$id" >/dev/null
  elif [ "$total" -eq 0 ] && [ "$now" -ge "$appear_by" ]; then
    retired=$(main_ci_retire "$state" "$id")
    printf 'main CI never started after merge: no %s push run of %s at %s (merged from %s) appeared within the watch window; %s\n' \
      "$branch" "$repo" "$sha" "$url" "$retired"
  elif [ "$now" -ge "$conclude_by" ]; then
    retired=$(main_ci_retire "$state" "$id")
    printf 'main CI unresolved after merge: %s %s at %s (merged from %s) had not concluded when the watch window closed - %s; %s\n' \
      "$repo" "$branch" "$sha" "$url" "${open:-no run appeared}" "$retired"
  fi
}

case "${1:-}" in
  arm)
    [ "$#" -eq 2 ] || { echo "error: invalid main CI watch request" >&2; exit 2; }
    main_ci_arm "$2"
    ;;
  poll)
    [ "$#" -eq 9 ] || { echo "error: invalid main CI poll" >&2; exit 2; }
    shift
    main_ci_poll "$@"
    ;;
  *)
    echo "usage: fm-main-ci.sh arm <pr-url> | poll <state-dir> <id> <owner/repo> <branch> <sha> <pr-url> <appear-by> <conclude-by>" >&2
    exit 2
    ;;
esac
