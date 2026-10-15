#!/usr/bin/env bash
# Report supervision text that would leak into a project if this work merged.
# bin/fm-leak-lib.sh owns what counts as a leak; this script reads the work and
# feeds it to those scanners.
#
#   pr <pr-url> [--head <sha>]
#       A GitHub pull request or GitLab merge request: its title, its body,
#       every commit message on it, and the lines its diff adds. With --head,
#       the commit list read must contain that head, so the scan is bound to
#       the head a merge verified; a moved head is reported as unreadable.
#   local <project-dir> <base-ref> <branch>
#       A local-only branch: every commit message in <base-ref>..<branch> and
#       the lines `git diff <base-ref>...<branch>` adds.
#
# Each hit prints `leak: <where>: <rules>: <excerpt>` on stdout, where <where>
# is `title`, `body line N`, `commit <sha> message line N`, or `<file>:<line>`
# of an added line. Removed lines never count, so a cleanup passes.
# Work on the firstmate repository itself - a pull request on one of the code
# root's remotes, or a project that is the code root or shares a remote with
# it - is exempt and prints one `exempt:` line.
# The home path searched for is FM_HOME's.
#
# Exit 0 when clean or exempt, 1 when any hit was printed, 2 when the work
# could not be read completely (reported on stderr), 64 on a usage error.
# Callers decide what a nonzero status means: bin/fm-pr-merge.sh and
# bin/fm-merge-local.sh refuse the merge unless an attended --allow-leak
# reason is recorded, and bin/fm-pr-check.sh only warns.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-leak-lib.sh
. "$SCRIPT_DIR/fm-leak-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-leak-check.sh pr <pr-url> [--head <sha>] | local <project-dir> <base-ref> <branch>" >&2
  exit 64
}

HITS=0
# Run one scanner over stdin and fold its verdict into HITS.
scan_text() {  # <where> <numbered>
  fm_leak_scan_text "$1" "$2" "$FM_HOME" || HITS=1
}
scan_diff() {
  fm_leak_scan_diff "$FM_HOME" || HITS=1
}

unreadable() {
  printf 'error: could not read %s completely, so it was not checked for leaks\n' "$1" >&2
  exit 2
}

# The commits of a JSON array, one `<sha>` line each, are scanned message by
# message. Args: <json> <sha-field> <message-field>
scan_commits_json() {
  local json=$1 sha_field=$2 msg_field=$3 count i sha
  count=$(printf '%s' "$json" | jq 'length') || return 1
  i=0
  while [ "$i" -lt "$count" ]; do
    sha=$(printf '%s' "$json" | jq -r ".[$i].$sha_field // \"\"") || return 1
    scan_text "commit ${sha:0:12} message" 1 \
      < <(printf '%s' "$json" | jq -r ".[$i].$msg_field // \"\"")
    i=$((i + 1))
  done
}

json_has_head() {  # <json> <sha-field> <head>
  printf '%s' "$1" | jq -e --arg h "$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')" \
    "any(.[]; (.$2 // \"\" | ascii_downcase) == \$h)" >/dev/null 2>&1
}

check_github() {  # <url> <head>
  local url=$1 head=$2 repo view commits diff
  repo="$FM_PR_OWNER/$FM_PR_REPO"
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "error: reading $url for leaks needs gh and jq" >&2
    exit 2
  fi
  if ! view=$(gh pr view "$FM_PR_NUMBER" --repo "$repo" --json title,body 2>/dev/null) \
    || ! printf '%s' "$view" | jq -e 'type == "object"' >/dev/null 2>&1; then
    unreadable "the title and body of $url"
  fi
  if ! commits=$(gh api --paginate "repos/$repo/pulls/$FM_PR_NUMBER/commits?per_page=100" 2>/dev/null \
    | jq -s 'add // []' 2>/dev/null) \
    || ! printf '%s' "$commits" | jq -e 'type == "array"' >/dev/null 2>&1; then
    unreadable "the commits of $url"
  fi
  # The REST list stops at 250 commits, so a list that long may be partial.
  [ "$(printf '%s' "$commits" | jq 'length')" -lt 250 ] \
    || unreadable "the commits of $url (250 or more, past what the forge lists)"
  [ -z "$head" ] || json_has_head "$commits" sha "$head" \
    || unreadable "the commits of $url at head $head (the head moved)"
  diff=$(gh pr diff "$FM_PR_NUMBER" --repo "$repo" --color never 2>/dev/null) \
    || unreadable "the diff of $url"
  scan_text title 0 < <(printf '%s' "$view" | jq -r '.title // ""')
  scan_text body 1 < <(printf '%s' "$view" | jq -r '.body // ""')
  scan_commits_json "$commits" sha commit.message || unreadable "the commits of $url"
  scan_diff <<<"$diff"
}

check_gitlab() {  # <url> <head>
  local url=$1 head=$2 project_url enc view commits diffs
  project_url="https://$FM_PR_HOST/$FM_PR_PATH"
  enc=$(url_encode_path_segment "$FM_PR_PATH")
  if ! command -v glab >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "error: reading $url for leaks needs glab and jq" >&2
    exit 2
  fi
  if ! view=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "$project_url" -F json 2>/dev/null) \
    || ! printf '%s' "$view" | jq -e 'type == "object"' >/dev/null 2>&1; then
    unreadable "the title and description of $url"
  fi
  if ! commits=$(GITLAB_HOST="$FM_PR_HOST" glab api --paginate \
    "projects/$enc/merge_requests/$FM_PR_NUMBER/commits" 2>/dev/null | jq -s 'add // []' 2>/dev/null) \
    || ! printf '%s' "$commits" | jq -e 'type == "array"' >/dev/null 2>&1; then
    unreadable "the commits of $url"
  fi
  [ -z "$head" ] || json_has_head "$commits" id "$head" \
    || unreadable "the commits of $url at head $head (the head moved)"
  if ! diffs=$(GITLAB_HOST="$FM_PR_HOST" glab api --paginate \
    "projects/$enc/merge_requests/$FM_PR_NUMBER/diffs" 2>/dev/null | jq -s 'add // []' 2>/dev/null) \
    || ! printf '%s' "$diffs" | jq -e 'type == "array" and all(.[]; has("diff") and .too_large != true)' >/dev/null 2>&1; then
    unreadable "the diff of $url"
  fi
  scan_text title 0 < <(printf '%s' "$view" | jq -r '.title // ""')
  scan_text body 1 < <(printf '%s' "$view" | jq -r '.description // ""')
  scan_commits_json "$commits" id message || unreadable "the commits of $url"
  # Each entry carries only its hunks, so its file header is synthesized.
  scan_diff < <(printf '%s' "$diffs" \
    | jq -r '.[] | "+++ " + (if .deleted_file then "/dev/null" else "b/" + .new_path end), .diff')
}

check_local() {  # <project> <base> <branch>
  local proj=$1 base=$2 branch=$3 shas sha diff
  if ! git -C "$proj" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
    || ! git -C "$proj" rev-parse --verify --quiet "$branch^{commit}" >/dev/null; then
    unreadable "$branch against $base in $proj"
  fi
  shas=$(git -C "$proj" rev-list "$base..$branch" 2>/dev/null) \
    || unreadable "the commits of $branch in $proj"
  diff=$(git -C "$proj" diff --no-color --no-ext-diff --no-textconv \
    "$base...$branch" 2>/dev/null) || unreadable "the diff of $branch in $proj"
  for sha in $shas; do
    scan_text "commit ${sha:0:12} message" 1 < <(git -C "$proj" log -1 --format=%B "$sha" 2>/dev/null)
  done
  scan_diff <<<"$diff"
}

[ "$#" -ge 1 ] || usage
case "$1" in
  pr)
    [ "$#" -eq 2 ] || { [ "$#" -eq 4 ] && [ "$3" = --head ]; } || usage
    HEAD_SHA=${4:-}
    fm_pr_url_parse "$2" || usage
    if fm_leak_self_pr "$FM_ROOT" "$FM_PR_HOST" "$FM_PR_PATH"; then
      printf 'exempt: %s is the firstmate repository itself\n' "$FM_PR_URL"
      exit 0
    fi
    case "$FM_PR_PROVIDER" in
      github) check_github "$FM_PR_URL" "$HEAD_SHA" ;;
      gitlab) check_gitlab "$FM_PR_URL" "$HEAD_SHA" ;;
      *) usage ;;
    esac
    ;;
  local)
    [ "$#" -eq 4 ] || usage
    [ -d "$2" ] || unreadable "project $2"
    if fm_leak_self_project "$FM_ROOT" "$2"; then
      printf 'exempt: %s is the firstmate repository itself\n' "$2"
      exit 0
    fi
    check_local "$2" "$3" "$4"
    ;;
  *) usage ;;
esac
exit "$HITS"
