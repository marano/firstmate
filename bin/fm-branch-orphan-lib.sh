#!/usr/bin/env bash
# Durable record of a merged pull request's head branch that could not be
# deleted, so the branch is swept by a later pass instead of accumulating on
# the remote.
#
# bin/fm-pr-merge.sh deletes a merged head branch itself, and that deletion
# must never fail a merge that landed. Before this record existed the failure
# was reported as one `actionable:` line on stderr and then forgotten, which is
# why leftover branches built up slowly on repositories whose own
# delete_branch_on_merge was already on.
#
# The record is fleet-wide rather than per-task, at:
#   state/branch-orphans
# A task's own state is removed by bin/fm-teardown.sh once its merge lands, and
# that is exactly when an orphaned branch still needs sweeping, so a
# state/<task-id>.* sidecar would be reaped before any later pass could read
# it.
#
# One tab-separated line per orphaned branch, each self-describing so a later
# format can be told apart from this one:
#   fm-branch-orphan-v1<TAB><epoch><TAB><provider><TAB><host><TAB><path><TAB><branch><TAB><pr-url>
# <provider> is github or gitlab, <path> is owner/repository on GitHub and the
# full project path on GitLab, and <pr-url> is the canonical merged pull
# request or merge request the branch was the head of. Those five identity
# fields are what bin/fm-branch-orphans.sh needs to re-read the forge and retry
# the deletion; the epoch is for a human reading the file.
#
# Records are identified by provider, host, path, and branch. Recording is
# idempotent on that identity, so a repeated failure for one branch never
# appends a second line. A field carrying a tab or newline would split a record
# into fields that no longer mean what they say, so it is refused rather than
# written; a git ref name can contain neither, so refusing is not a limitation
# on any branch that could exist.
#
# The file is mode 0600, single-link, and written by replacing a temporary file
# in the same directory, so a reader never sees a half-written record. Every
# mutation holds state/branch-orphans.lock, because several lanes merge at once
# and an append and a removal that interleave would lose one of them.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-branch-orphans.sh, and tests. Sourcing
# it has no side effect and creates no file. fm_lock_acquire_wait and
# fm_lock_release come from bin/fm-wake-lib.sh, which the sourcing script is
# responsible for having sourced.

FM_BRANCH_ORPHAN_VERSION=fm-branch-orphan-v1

# The two characters a field must not contain, held as literals so the check
# below never depends on a substitution that strips the very character it is
# looking for.
_FM_BRANCH_ORPHAN_TAB=$(printf '\t')
_FM_BRANCH_ORPHAN_NEWLINE='
'

# The records themselves, one per line, for a caller that asked for them.
# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_BRANCH_ORPHAN_RECORDS=

_fm_branch_orphan_file() {  # <state>
  printf '%s/branch-orphans\n' "$1"
}

# Refuse a field that would corrupt the tab-separated shape, and refuse an
# empty one, because an identity field that is absent cannot be matched later.
_fm_branch_orphan_field_valid() {  # <value>
  local value=${1-}
  [ -n "$value" ] || return 1
  case $value in
    *"$_FM_BRANCH_ORPHAN_TAB"* | *"$_FM_BRANCH_ORPHAN_NEWLINE"*) return 1 ;;
  esac
  return 0
}

_fm_branch_orphan_identity_valid() {  # <provider> <host> <path> <branch>
  local provider=${1-} host=${2-} path=${3-} branch=${4-}
  case $provider in
    github | gitlab) ;;
    *) return 1 ;;
  esac
  _fm_branch_orphan_field_valid "$host" || return 1
  _fm_branch_orphan_field_valid "$path" || return 1
  _fm_branch_orphan_field_valid "$branch" || return 1
  return 0
}

# Print every record that is not the named branch, so both the removal and the
# append-after-dedup paths can rebuild the file from one filter.
_fm_branch_orphan_without() {  # <file> <provider> <host> <path> <branch>
  local file=$1 provider=$2 host=$3 path=$4 branch=$5
  [ -f "$file" ] || return 0
  awk -F'\t' \
    -v version="$FM_BRANCH_ORPHAN_VERSION" \
    -v provider="$provider" -v host="$host" -v path="$path" -v branch="$branch" \
    '$1 == version && $3 == provider && $4 == host && $5 == path && $6 == branch { next }
     { print }' \
    "$file"
}

# Replace the record file with the caller's stdin, atomically and privately.
# Reading stdin fully before the destination is touched keeps a filter that
# reads the same file from truncating its own input.
_fm_branch_orphan_publish() {  # <state> <file>
  local state=$1 file=$2 tmp status=0
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ ! -e "$file" ] || { [ -f "$file" ] && [ ! -L "$file" ]; } || return 1
  tmp=$(mktemp "$state/.fm-branch-orphans.XXXXXX") || return 1
  cat > "$tmp" || status=1
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" && mv -f -- "$tmp" "$file" || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  return "$status"
}

# Record one branch that a confirmed merge left behind. Idempotent on the
# branch's identity: a second failure for the same branch refreshes its line
# rather than adding another.
fm_branch_orphan_record() {  # <state> <provider> <host> <path> <branch> <pr-url>
  local state=${1-} provider=${2-} host=${3-} path=${4-} branch=${5-} url=${6-}
  local file lock kept status=0
  [ -n "$state" ] || return 1
  _fm_branch_orphan_identity_valid "$provider" "$host" "$path" "$branch" || return 1
  _fm_branch_orphan_field_valid "$url" || return 1
  file=$(_fm_branch_orphan_file "$state")
  lock="$file.lock"
  fm_lock_acquire_wait "$lock" || return 1
  kept=$(_fm_branch_orphan_without "$file" "$provider" "$host" "$path" "$branch") || status=1
  if [ "$status" -eq 0 ]; then
    {
      [ -z "$kept" ] || printf '%s\n' "$kept"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$FM_BRANCH_ORPHAN_VERSION" "$(date +%s)" \
        "$provider" "$host" "$path" "$branch" "$url"
    } | _fm_branch_orphan_publish "$state" "$file" || status=1
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}

# Drop one branch's record, after it has been deleted or found already gone.
# A record that is not there is not an error: the sweep reached the state it
# wanted either way.
fm_branch_orphan_forget() {  # <state> <provider> <host> <path> <branch>
  local state=${1-} provider=${2-} host=${3-} path=${4-} branch=${5-}
  local file lock kept status=0
  [ -n "$state" ] || return 1
  _fm_branch_orphan_identity_valid "$provider" "$host" "$path" "$branch" || return 1
  file=$(_fm_branch_orphan_file "$state")
  [ -f "$file" ] || return 0
  lock="$file.lock"
  fm_lock_acquire_wait "$lock" || return 1
  kept=$(_fm_branch_orphan_without "$file" "$provider" "$host" "$path" "$branch") || status=1
  if [ "$status" -eq 0 ]; then
    if [ -z "$kept" ]; then
      rm -f -- "$file" || status=1
    else
      printf '%s\n' "$kept" | _fm_branch_orphan_publish "$state" "$file" || status=1
    fi
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}

# Read the records into FM_BRANCH_ORPHAN_RECORDS, optionally only those for one
# repository. An absent file means no orphans, which is the healthy state, so
# it reads as empty rather than as a failure.
fm_branch_orphan_list() {  # <state> [<provider> <host> <path>]
  local state=${1-} provider=${2-} host=${3-} path=${4-}
  local file
  FM_BRANCH_ORPHAN_RECORDS=
  [ -n "$state" ] || return 1
  file=$(_fm_branch_orphan_file "$state")
  [ -f "$file" ] || return 0
  # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
  FM_BRANCH_ORPHAN_RECORDS=$(awk -F'\t' \
    -v version="$FM_BRANCH_ORPHAN_VERSION" \
    -v provider="$provider" -v host="$host" -v path="$path" \
    '$1 != version { next }
     provider != "" && ($3 != provider || $4 != host || $5 != path) { next }
     { print }' \
    "$file") || return 1
  return 0
}
