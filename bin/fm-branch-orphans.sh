#!/usr/bin/env bash
# List or sweep the merged head branches that bin/fm-pr-merge.sh could not
# delete, from the durable record bin/fm-branch-orphan-lib.sh owns.
#
# bin/fm-pr-merge.sh deletes a merged head branch itself and must never fail a
# merge that landed, so a deletion it cannot complete is recorded instead of
# raised. This script is the later pass that acts on those records. It is not a
# recurring sweeper and never enumerates a remote's branches: it reads only the
# branches already recorded, and every one of them is a branch a confirmed
# merge left behind.
#
# Usage:
#   fm-branch-orphans.sh list [--provider P --host H --path O/R]
#   fm-branch-orphans.sh retry [--provider P --host H --path O/R] [--dry-run]
#
# `list` prints one line per recorded branch and exits 0 whether or not any
# exist. `retry` re-verifies each recorded branch against the forge and deletes
# only what still proves deletable, dropping the record once the branch is
# confirmed gone. The optional repository filter bounds either command to one
# repository, which is how a merge sweeps the repository it just merged in.
# `--dry-run` reports the verdict it would act on and changes nothing.
#
# Every deletion re-reads the forge at the moment of deletion rather than
# trusting the record, because the record can be days old and deleting a branch
# is irreversible. A branch is deleted only when, read live: its recorded pull
# request is merged, that pull request's head branch is still exactly this
# branch, the head is not in a fork, the branch is not protected, and it is not
# the base of another open pull request. Those are the same conditions
# bin/fm-pr-merge.sh requires before its own deletion; a branch failing any of
# them is left alone and reported.
#
# A record is dropped only when the branch is confirmed absent, whether this
# script deleted it or found it already gone. Anything else keeps its record,
# so a branch that cannot be swept stays visible to `list` instead of being
# forgotten quietly. Exit status is 0 when every record was acted on without
# error and 1 when any record could not be read or deleted; a recorded branch
# that is deliberately left in place is not an error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-branch-orphan-lib.sh
. "$SCRIPT_DIR/fm-branch-orphan-lib.sh"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

COMMAND=${1-}
case "$COMMAND" in
  list | retry) shift ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    echo "error: expected 'list' or 'retry'; see --help" >&2
    exit 2
    ;;
esac

FILTER_PROVIDER=''
FILTER_HOST=''
FILTER_PATH=''
DRY_RUN=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider)
      FILTER_PROVIDER=${2-}
      shift 2
      ;;
    --host)
      FILTER_HOST=${2-}
      shift 2
      ;;
    --path)
      FILTER_PATH=${2-}
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# A partial filter would silently widen to every repository, which for `retry`
# means acting outside the repository the caller meant, so all three parts are
# required together or not at all.
FILTER_PARTS=0
[ -z "$FILTER_PROVIDER" ] || FILTER_PARTS=$((FILTER_PARTS + 1))
[ -z "$FILTER_HOST" ] || FILTER_PARTS=$((FILTER_PARTS + 1))
[ -z "$FILTER_PATH" ] || FILTER_PARTS=$((FILTER_PARTS + 1))
if [ "$FILTER_PARTS" -ne 0 ] && [ "$FILTER_PARTS" -ne 3 ]; then
  echo "error: --provider, --host and --path must be given together" >&2
  exit 2
fi

if ! fm_branch_orphan_list "$STATE" "$FILTER_PROVIDER" "$FILTER_HOST" "$FILTER_PATH"; then
  echo "error: could not read the recorded branches" >&2
  exit 1
fi
RECORDS=$FM_BRANCH_ORPHAN_RECORDS

if [ "$COMMAND" = list ]; then
  if [ -z "$RECORDS" ]; then
    echo "no branches recorded"
    exit 0
  fi
  printf '%s\n' "$RECORDS" | while IFS=$'\t' read -r _ epoch provider host path branch url; do
    printf '%s\t%s/%s\t%s\t%s\n' "$provider" "$host" "$path" "$branch" "$url"
    printf '  recorded at epoch %s\n' "$epoch"
  done
  exit 0
fi

if [ -z "$RECORDS" ]; then
  exit 0
fi

# Re-read one recorded GitHub branch and delete it only if every condition the
# merge path requires still holds live. Prints its verdict; returns 0 when the
# branch is confirmed gone, 1 on a read or delete error, and 2 when the branch
# is deliberately left in place.
github_retry_one() {  # <path> <branch> <url> <number>
  local path=$1 branch=$2 url=$3 number=$4
  local pr_json merged head_ref cross_repo enc protected open_count
  if ! pr_json=$(gh api "repos/$path/pulls/$number" 2>/dev/null); then
    printf 'could not read %s; %s left in place\n' "$url" "$branch" >&2
    return 1
  fi
  merged=$(printf '%s' "$pr_json" | jq -r '.merged_at != null') || return 1
  head_ref=$(printf '%s' "$pr_json" | jq -r '.head.ref // ""') || return 1
  cross_repo=$(printf '%s' "$pr_json" \
    | jq -r --arg path "$path" '(.head.repo.full_name // "") != $path') || return 1
  if [ "$merged" != true ]; then
    printf 'not swept: %s is not merged; %s left in place\n' "$url" "$branch" >&2
    return 2
  fi
  if [ "$head_ref" != "$branch" ]; then
    printf 'not swept: %s no longer has head branch %s; left in place\n' "$url" "$branch" >&2
    return 2
  fi
  if [ "$cross_repo" != false ]; then
    printf 'not swept: %s lives in a fork; left in place\n' "$branch" >&2
    return 2
  fi
  enc=$(url_encode_path_segment "$branch")
  if ! protected=$(gh api "repos/$path/branches/$enc" --jq '.protected' 2>/dev/null); then
    if ! gh api "repos/$path/branches/$enc" >/dev/null 2>&1; then
      printf 'already gone: %s (%s)\n' "$branch" "$url"
      return 0
    fi
    printf 'could not confirm branch protection for %s; left in place\n' "$branch" >&2
    return 1
  fi
  if [ "$protected" = true ]; then
    printf 'not swept: %s is a protected branch; left in place\n' "$branch" >&2
    return 2
  fi
  if ! open_count=$(gh api "repos/$path/pulls?base=$enc&state=open" --jq 'length' 2>/dev/null); then
    printf 'could not confirm %s is not the base of another open pull request; left in place\n' "$branch" >&2
    return 1
  fi
  if [ "$open_count" != 0 ]; then
    printf 'not swept: %s is the base of %s other open pull request(s); left in place\n' \
      "$branch" "$open_count" >&2
    return 2
  fi
  if [ "$DRY_RUN" = true ]; then
    printf 'would delete: %s (%s)\n' "$branch" "$url"
    return 2
  fi
  if gh api -X DELETE "repos/$path/git/refs/heads/$branch" >/dev/null 2>&1; then
    printf 'branch deleted: %s (%s)\n' "$branch" "$url"
    return 0
  fi
  if ! gh api "repos/$path/branches/$enc" >/dev/null 2>&1; then
    printf 'already gone: %s (%s)\n' "$branch" "$url"
    return 0
  fi
  printf 'could not delete branch %s; left in place\n' "$branch" >&2
  return 1
}

# GitLab equivalent of github_retry_one, with the same verdicts and the same
# live re-read of every condition.
gitlab_retry_one() {  # <host> <path> <branch> <url> <number>
  local host=$1 path=$2 branch=$3 url=$4 number=$5
  local mr_json merged source_branch fork project_enc branch_enc
  local protected_output protected_status=0 open_count
  project_enc=$(url_encode_path_segment "$path")
  branch_enc=$(url_encode_path_segment "$branch")
  if ! mr_json=$(GITLAB_HOST="$host" glab api \
    "projects/$project_enc/merge_requests/$number" 2>/dev/null); then
    printf 'could not read %s; %s left in place\n' "$url" "$branch" >&2
    return 1
  fi
  merged=$(printf '%s' "$mr_json" | jq -r '.state == "merged"') || return 1
  source_branch=$(printf '%s' "$mr_json" | jq -r '.source_branch // ""') || return 1
  fork=$(printf '%s' "$mr_json" | jq -r '.source_project_id != .target_project_id') || return 1
  if [ "$merged" != true ]; then
    printf 'not swept: %s is not merged; %s left in place\n' "$url" "$branch" >&2
    return 2
  fi
  if [ "$source_branch" != "$branch" ]; then
    printf 'not swept: %s no longer has source branch %s; left in place\n' "$url" "$branch" >&2
    return 2
  fi
  if [ "$fork" != false ]; then
    printf 'not swept: %s lives in a forked project; left in place\n' "$branch" >&2
    return 2
  fi
  if ! GITLAB_HOST="$host" glab api \
    "projects/$project_enc/repository/branches/$branch_enc" >/dev/null 2>&1; then
    printf 'already gone: %s (%s)\n' "$branch" "$url"
    return 0
  fi
  protected_output=$(GITLAB_HOST="$host" glab api \
    "projects/$project_enc/protected_branches/$branch_enc" 2>&1) || protected_status=$?
  if [ "$protected_status" -eq 0 ]; then
    printf 'not swept: %s is a protected branch; left in place\n' "$branch" >&2
    return 2
  fi
  # As in bin/fm-pr-merge.sh, only a 404 in the error text confirms the branch
  # is unprotected; any other failure is a safety-relevant unknown.
  case "$protected_output" in
    *404*) ;;
    *)
      printf 'could not confirm branch protection for %s; left in place\n' "$branch" >&2
      return 1
      ;;
  esac
  if ! open_count=$(GITLAB_HOST="$host" glab api \
    "projects/$project_enc/merge_requests?state=opened&target_branch=$branch_enc" --jq 'length' 2>/dev/null); then
    printf 'could not confirm %s is not the target of another open merge request; left in place\n' "$branch" >&2
    return 1
  fi
  if [ "$open_count" != 0 ]; then
    printf 'not swept: %s is the target of %s other open merge request(s); left in place\n' \
      "$branch" "$open_count" >&2
    return 2
  fi
  if [ "$DRY_RUN" = true ]; then
    printf 'would delete: %s (%s)\n' "$branch" "$url"
    return 2
  fi
  if GITLAB_HOST="$host" glab api -X DELETE \
    "projects/$project_enc/repository/branches/$branch_enc" >/dev/null 2>&1; then
    printf 'branch deleted: %s (%s)\n' "$branch" "$url"
    return 0
  fi
  if ! GITLAB_HOST="$host" glab api \
    "projects/$project_enc/repository/branches/$branch_enc" >/dev/null 2>&1; then
    printf 'already gone: %s (%s)\n' "$branch" "$url"
    return 0
  fi
  printf 'could not delete branch %s; left in place\n' "$branch" >&2
  return 1
}

STATUS=0
SWEPT=0
LEFT=0
while IFS=$'\t' read -r _ _ provider host path branch url; do
  [ -n "$branch" ] || continue
  # The recorded URL is the identity the forge is asked about, and it is parsed
  # rather than trusted so a record that cannot reconstruct a canonical URL is
  # reported instead of being turned into a request.
  if ! fm_pr_url_parse "$url"; then
    printf 'could not parse the recorded pull request URL for %s; left in place\n' "$branch" >&2
    STATUS=1
    LEFT=$((LEFT + 1))
    continue
  fi
  if [ "$FM_PR_PROVIDER" != "$provider" ] || [ "$FM_PR_HOST" != "$host" ] \
    || [ "$FM_PR_PATH" != "$path" ]; then
    printf 'recorded identity for %s disagrees with its pull request URL; left in place\n' "$branch" >&2
    STATUS=1
    LEFT=$((LEFT + 1))
    continue
  fi
  rc=0
  case "$provider" in
    github) github_retry_one "$path" "$branch" "$url" "$FM_PR_NUMBER" || rc=$? ;;
    gitlab) gitlab_retry_one "$host" "$path" "$branch" "$url" "$FM_PR_NUMBER" || rc=$? ;;
    *)
      printf 'unknown provider %s recorded for %s; left in place\n' "$provider" "$branch" >&2
      rc=1
      ;;
  esac
  case "$rc" in
    0)
      SWEPT=$((SWEPT + 1))
      if ! fm_branch_orphan_forget "$STATE" "$provider" "$host" "$path" "$branch"; then
        printf 'actionable: %s was swept but its record could not be cleared\n' "$branch" >&2
        STATUS=1
      fi
      ;;
    2) LEFT=$((LEFT + 1)) ;;
    *)
      LEFT=$((LEFT + 1))
      STATUS=1
      ;;
  esac
done <<EOD
$RECORDS
EOD

printf 'swept %s branch(es), %s left in place\n' "$SWEPT" "$LEFT"
exit "$STATUS"
