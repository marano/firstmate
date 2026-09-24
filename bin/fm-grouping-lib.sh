#!/usr/bin/env bash
# Single owner of work-relatedness: the grouping posture, the group key carried
# by a backlog item, and the one question every consumer asks - given an item,
# which other items are its SIBLINGS.
#
# Why one owner: bin/fm-awaiting-landing-lib.sh records what happens otherwise -
# "every consumer that cared inferred it independently ... and each got it wrong
# differently". The dispatch guard, the `join` verb, the idle alarm, the exit
# guard and the fleet snapshot all need the same definition, so it is stated
# here once and nowhere else.
#
# THE NOUNS. A GROUP KEY is an opaque string an agent records on a backlog item
# at intake; this file never derives one and never learns what it means (an
# epic, a subsystem, anything else). The reserved key `solo` is the recorded
# verdict "considered, belongs to no group" and never matches anything,
# including another `solo`. A CHUNK is a unit row plus the members parked behind
# it. The POSTURE is off, warn, or enforce.
#
# SIBLINGS. A sibling always shares BOTH the item's repository and its key; an
# item with no key, an item whose repository is unset, and `solo` have no
# siblings at all. A sibling is READY when its row is Queued, unheld, and
# blocked by nothing except the unit it would join. A sibling is LIVE when this
# home holds a ship worker record for it whose agent has not been deliberately
# stopped - whatever its last status says, because a worker that reported `done:`
# still holds its context until firstmate stops it, and that context is exactly
# what grouping exists to keep. Reading `state/<id>.agent-stopped` for that
# purpose is this file's one licensed use of that record (bin/fm-control.sh's
# record_agent_stopped lists every reader).
#
# CANNOT TELL IS NOT NONE. Every read here is bounded, and a read that times out
# or fails returns status 2 with FM_GROUPING_ERROR set, never an empty sibling
# set. Each consumer decides what to do about that; none of them may treat it as
# "no siblings".
#
# COST. One `tasks-axi list` call per scan narrows the candidates by repository,
# state and kind; only the survivors are read individually, because a key lives
# in an item's body and only `show --full` decodes a body exactly
# (bin/fm-backlog-transition-lib.sh's fm_backlog_row_field owns that decode).
#
# Sourced, never executed.

_FM_GROUPING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper owners, sourced only when the caller has not already loaded them, the
# same shape bin/fm-idle-fleet-lib.sh uses: a caller that already has them pays
# nothing, and a test or standalone caller still gets a self-contained library.
if ! command -v fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_FM_GROUPING_LIB_DIR/fm-backend.sh"
fi
if ! command -v fm_tasks_axi_backend >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_FM_GROUPING_LIB_DIR/fm-tasks-axi-lib.sh"
fi
if ! command -v fm_backlog_row_probe >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_FM_GROUPING_LIB_DIR/fm-backlog-transition-lib.sh"
fi

# The body line that carries the key, and the one that carries a chunk's planned
# members. Both are firstmate's own machine-read lines in an item's body, in the
# same namespaced shape as bin/fm-captain-hold.sh's "Captain hold set:" stamp, so
# imported ticket prose cannot collide with them. The plan line is written only
# on a unit row, which is firstmate's own record rather than one of the captain's
# tickets.
FM_GROUPING_KEY_PREFIX="Group key: "
FM_GROUPING_PLAN_PREFIX="Chunk members: "
FM_GROUPING_SOLO_KEY="solo"

FM_GROUPING_POSTURE=off
FM_GROUPING_MEMBER_CAP=
FM_GROUPING_KEY=
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_GROUPING_REPO=
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_GROUPING_READY_SIBLINGS=
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_GROUPING_LIVE_SIBLINGS=
FM_GROUPING_ROWS=
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_GROUPING_PLAN=
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_GROUPING_ERROR=
FM_GROUPING_FINDINGS=

# The posture of <config-dir>: one line holding `off`, `warn`, or `enforce`,
# optionally followed by a soft member cap (`enforce 6`). An absent file is off,
# which is what every home that has not opted in reads. FM_GROUPING overrides the
# file. A token this file does not know is REFUSED rather than defaulted around,
# the same rule bin/fm-idle-fleet-lib.sh applies to a malformed capacity and for
# the same reason: a typo must not silently restore the old behavior.
fm_grouping_posture() {  # <config-dir>
  local config=${1-} raw='' posture cap rest source_label
  FM_GROUPING_POSTURE=off
  FM_GROUPING_MEMBER_CAP=
  FM_GROUPING_ERROR=
  if [ -n "${FM_GROUPING:-}" ]; then
    raw=$FM_GROUPING
    source_label=FM_GROUPING
  elif [ -n "$config" ] && [ -f "$config/grouping" ] && [ ! -L "$config/grouping" ]; then
    source_label="$config/grouping"
    IFS= read -r raw < "$config/grouping" || {
      FM_GROUPING_ERROR="cannot read the grouping posture at $config/grouping"
      return 1
    }
  else
    return 0
  fi
  raw=${raw#"${raw%%[![:space:]]*}"}
  raw=${raw%"${raw##*[![:space:]]}"}
  [ -n "$raw" ] || return 0
  posture=${raw%%[[:space:]]*}
  rest=${raw#"$posture"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$posture" in
    off|warn|enforce) ;;
    *)
      FM_GROUPING_ERROR="grouping posture '$posture' is not off, warn, or enforce ($source_label)"
      return 1
      ;;
  esac
  if [ -n "$rest" ]; then
    cap=${rest%%[[:space:]]*}
    rest=${rest#"$cap"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    case "$cap" in
      ''|*[!0-9]*)
        FM_GROUPING_ERROR="grouping member cap '$cap' is not a whole number ($source_label)"
        return 1
        ;;
    esac
    if [ "$cap" -le 0 ] 2>/dev/null; then
      FM_GROUPING_ERROR="grouping member cap '$cap' is not a positive number ($source_label)"
      return 1
    fi
    if [ -n "$rest" ]; then
      FM_GROUPING_ERROR="grouping posture takes at most a posture and a member cap ($source_label)"
      return 1
    fi
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_GROUPING_MEMBER_CAP=$cap
  fi
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_GROUPING_POSTURE=$posture
}

# A key is an opaque lowercase slug. The grammar is narrow on purpose: the key
# reaches a body line, a command line, and a comparison, and nothing about the
# tracker it came from may widen it.
fm_grouping_key_valid() {  # <key>
  local key=${1-}
  local LC_ALL=C
  [ -n "$key" ] && [ "${#key}" -le 64 ] || return 1
  case "$key" in
    [a-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$key" in
    *[!a-z0-9._-]*) return 1 ;;
  esac
}

# The key carried by a decoded body, printed empty when the body carries none.
# TWO key lines are refused (status 2) rather than resolved by position, the same
# rule bin/fm-meta-keys-lib.sh gives for a repeated record key: a second copy is
# how one silently redefines what every reader sees.
fm_grouping_key_of_body() {  # <body>
  local body=${1-} line key='' seen=0
  while IFS= read -r line; do
    case "$line" in
      "$FM_GROUPING_KEY_PREFIX"*)
        seen=$((seen + 1))
        key=${line#"$FM_GROUPING_KEY_PREFIX"}
        ;;
    esac
  done <<EOF
$body
EOF
  [ "$seen" -le 1 ] || return 2
  printf '%s\n' "$key"
}

# The planned members a chunk recorded on its unit row, as the comma-separated
# value, or empty. Refuses a repeated line exactly as the key does.
fm_grouping_plan_of_body() {  # <body>
  local body=${1-} line value='' seen=0
  while IFS= read -r line; do
    case "$line" in
      "$FM_GROUPING_PLAN_PREFIX"*)
        seen=$((seen + 1))
        value=${line#"$FM_GROUPING_PLAN_PREFIX"}
        ;;
    esac
  done <<EOF
$body
EOF
  [ "$seen" -le 1 ] || return 2
  printf '%s\n' "$value"
}

# A body with <prefix><value> set: the existing line is replaced WHERE IT IS, and
# a body without one gains the line as its last paragraph. Never at the top,
# because bin/fm-captain-hold.sh and bin/fm-fleet-snapshot.sh both read the hold
# stamp from line 1 only, and pushing that stamp down resets a hold's age.
fm_grouping_body_with_line() {  # <body> <prefix> <value>
  local body=${1-} prefix=$2 value=$3 line out='' replaced=0
  while IFS= read -r line; do
    case "$line" in
      "$prefix"*) line="$prefix$value"; replaced=1 ;;
    esac
    out="$out$line"$'\n'
  done <<EOF
$body
EOF
  out=${out%$'\n'}
  if [ "$replaced" = 0 ]; then
    if [ -n "$out" ]; then
      out="$out"$'\n\n'"$prefix$value"
    else
      out="$prefix$value"
    fi
  fi
  printf '%s\n' "$out"
}

# The key recorded on <id>, in FM_GROUPING_KEY (empty when unkeyed).
# Status: 0 read, 1 the body carries two key lines, 2 cannot tell, 3 no such row.
fm_grouping_key_of_row() {  # <data-dir> <id>
  local data=$1 id=$2 status key
  FM_GROUPING_KEY=
  FM_GROUPING_ERROR=
  fm_backlog_row_field "$data" "$id" body
  status=$?
  case "$status" in
    0) ;;
    3) FM_GROUPING_ERROR="$id has no backlog item in this home"; return 3 ;;
    *)
      FM_GROUPING_ERROR="${FM_BACKLOG_TRANSITION_ERROR:-cannot read the body of $id}"
      return 2
      ;;
  esac
  key=$(fm_grouping_key_of_body "$FM_BACKLOG_ROW_FIELD_VALUE") || {
    FM_GROUPING_ERROR="$id carries more than one '${FM_GROUPING_KEY_PREFIX%% *}' line; leave exactly one"
    return 1
  }
  if [ -n "$key" ] && ! fm_grouping_key_valid "$key"; then
    FM_GROUPING_ERROR="$id carries an unreadable group key '$key'"
    return 1
  fi
  FM_GROUPING_KEY=$key
}

# The repository recorded on <id>, in FM_GROUPING_REPO (empty when unset).
# Status: 0 read, 2 cannot tell, 3 no such row.
fm_grouping_repo_of_row() {  # <data-dir> <id>
  local data=$1 id=$2 status value
  FM_GROUPING_REPO=
  FM_GROUPING_ERROR=
  fm_backlog_row_field "$data" "$id" repo
  status=$?
  case "$status" in
    0) ;;
    3) FM_GROUPING_ERROR="$id has no backlog item in this home"; return 3 ;;
    *)
      FM_GROUPING_ERROR="${FM_BACKLOG_TRANSITION_ERROR:-cannot read the repository of $id}"
      return 2
      ;;
  esac
  value=$FM_BACKLOG_ROW_FIELD_VALUE
  case "$value" in
    '-'|'"-"'|none) value= ;;
  esac
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_GROUPING_REPO=$value
}

# Do a key and a repository pair describe relatable work at all? An unset
# repository, an absent key, and `solo` each mean "this item has no siblings",
# which is a fact about the item rather than an error.
fm_grouping_relatable() {  # <repo> <key>
  local repo=${1-} key=${2-}
  [ -n "$repo" ] || return 1
  [ -n "$key" ] || return 1
  [ "$key" != "$FM_GROUPING_SOLO_KEY" ] || return 1
}

# Is <id> a ship worker this home has not deliberately stopped? See SIBLINGS
# above for why a concluded status still counts as live.
fm_grouping_task_is_live() {  # <state-dir> <id>
  local state=$1 id=$2 meta kind
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ ! -e "$state/$id.agent-stopped" ] && [ ! -L "$state/$id.agent-stopped" ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" = ship ]
}

# The ids of this home's <state> ship rows in <repo>, one per line in
# FM_GROUPING_ROWS, excluding <exclude>. The result is a variable rather than
# stdout on purpose: a command substitution would run this in a subshell, where
# a "cannot tell" reason set on FM_GROUPING_ERROR could never reach the caller,
# and silently reading that as "no siblings" is the one failure this library
# exists to prevent. Status 2 means the list could not be read.
fm_grouping_repo_rows() {  # <data-dir> <state-dir> <repo> <state> <exclude>
  local data=$1 state=$2 repo=$3 row_state=$4 exclude=$5 out line id row_repo found=''
  FM_GROUPING_ROWS=
  FM_GROUPING_ERROR=
  out=$(fm_backlog_row_list "$data" --state "$row_state" --repo "$repo" --kind ship) || {
    FM_GROUPING_ERROR="cannot list $row_state ship items in $repo: $(printf '%s\n' "$out" | sed -n 1p)"
    return 2
  }
  while IFS= read -r line; do
    case "$line" in
      '  '*) ;;
      *) continue ;;
    esac
    line=${line#  }
    id=${line%%,*}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    [ "$id" != "$exclude" ] || continue
    # The repository filter is the backlog's own; re-read the column rather than
    # trusting the filter, so a parse that drifted shows up as no siblings from
    # an unexpected repository instead of a wrong refusal.
    row_repo=${line#*,}; row_repo=${row_repo#*,}; row_repo=${row_repo#*,}
    row_repo=${row_repo%%,*}
    [ "$row_repo" = "$repo" ] || continue
    found="$found$id"$'\n'
  done <<EOF
$out
EOF
  FM_GROUPING_ROWS=$found
}

# The members a chunk recorded on <unit> before anyone was dispatched, in
# FM_GROUPING_PLAN (empty when the row carries no plan). This is the PLAN, an
# earlier statement of intent kept in the unit row's own body; the membership a
# dispatch records is owned by bin/fm-backlog-transition-lib.sh's MEMBERSHIP and
# is never derived from here.
# Status: 0 read, 1 the body carries two plan lines, 2 cannot tell, 3 no row.
fm_grouping_plan_of_row() {  # <data-dir> <id>
  local data=$1 id=$2 status
  FM_GROUPING_PLAN=
  FM_GROUPING_ERROR=
  fm_backlog_row_field "$data" "$id" body
  status=$?
  case "$status" in
    0) ;;
    3) FM_GROUPING_ERROR="$id has no backlog item in this home"; return 3 ;;
    *)
      FM_GROUPING_ERROR="${FM_BACKLOG_TRANSITION_ERROR:-cannot read the body of $id}"
      return 2
      ;;
  esac
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_GROUPING_PLAN=$(fm_grouping_plan_of_body "$FM_BACKLOG_ROW_FIELD_VALUE") || {
    FM_GROUPING_ERROR="$id carries more than one '${FM_GROUPING_PLAN_PREFIX%% *}' line; leave exactly one"
    return 1
  }
}

# Does <id> still need a planning decision? True when this home holds other
# ready or live SHIP work in the same repository and <id> carries no key, so
# nobody has yet said whether it belongs with that work or stands alone. A key -
# including the reserved one that records "belongs with nothing" - answers the
# question either way, so a keyed item never needs planning again. The dispatch
# guard's unkeyed case and the idle alarm's unplanned count both ask THIS
# predicate, so an item the alarm counts is exactly an item the guard stops.
# Status: 0 needs planning, 1 does not, 2 cannot tell.
fm_grouping_needs_planning() {  # <data-dir> <state-dir> <id> <repo> <key>
  local data=$1 state=$2 id=$3 repo=$4 key=$5 status other
  FM_GROUPING_ERROR=
  [ -n "$repo" ] || return 1
  [ -z "$key" ] || return 1
  for other in queued in_flight; do
    fm_grouping_repo_rows "$data" "$state" "$repo" "$other" "$id"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    [ -z "$FM_GROUPING_ROWS" ] || return 0
  done
  return 1
}

# The ready siblings of <unit>: Queued, unheld, blocked by nothing except <unit>,
# same repository, same key. Sets FM_GROUPING_READY_SIBLINGS to a space-separated
# list. Status 2 with FM_GROUPING_ERROR when any read could not tell.
fm_grouping_ready_siblings() {  # <data-dir> <state-dir> <unit> <repo> <key>
  local data=$1 state=$2 unit=$3 repo=$4 key=$5 id rows status found=''
  FM_GROUPING_READY_SIBLINGS=
  FM_GROUPING_ERROR=
  fm_grouping_relatable "$repo" "$key" || return 0
  fm_grouping_repo_rows "$data" "$state" "$repo" queued "$unit"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  rows=$FM_GROUPING_ROWS
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_backlog_row_probe "$data" "$id" || {
      FM_GROUPING_ERROR="cannot read the state of $id: ${FM_BACKLOG_ROW_ERROR:-unreadable}"
      return 2
    }
    case "$FM_BACKLOG_ROW_STATE" in
      queued\ no\ no) ;;
      queued\ no\ yes)
        fm_backlog_row_field "$data" "$id" blocked_by || {
          FM_GROUPING_ERROR="cannot read what blocks $id: ${FM_BACKLOG_TRANSITION_ERROR:-unreadable}"
          return 2
        }
        [ "$FM_BACKLOG_ROW_FIELD_VALUE" = "$unit" ] || continue
        ;;
      *) continue ;;
    esac
    fm_grouping_key_of_row "$data" "$id"
    status=$?
    case "$status" in
      0) ;;
      2) return 2 ;;
      *) continue ;;
    esac
    [ "$FM_GROUPING_KEY" = "$key" ] || continue
    found="${found:+$found }$id"
  done <<EOF
$rows
EOF
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_GROUPING_READY_SIBLINGS=$found
}

# The live siblings of <unit>: the ids of this home's live ship workers whose own
# row, or whose delivered members, share <repo> and <key>. Sets
# FM_GROUPING_LIVE_SIBLINGS to a space-separated list of those WORKER ids, which
# is what a caller steers or joins to. Status 2 with FM_GROUPING_ERROR when any
# read could not tell.
fm_grouping_live_siblings() {  # <data-dir> <state-dir> <unit> <repo> <key>
  local data=$1 state=$2 unit=$3 repo=$4 key=$5 id rows status found='' owner meta
  FM_GROUPING_LIVE_SIBLINGS=
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_GROUPING_ERROR=
  fm_grouping_relatable "$repo" "$key" || return 0
  fm_grouping_repo_rows "$data" "$state" "$repo" in_flight "$unit"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  rows=$FM_GROUPING_ROWS
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_grouping_key_of_row "$data" "$id"
    status=$?
    case "$status" in
      0) ;;
      2) return 2 ;;
      *) continue ;;
    esac
    [ "$FM_GROUPING_KEY" = "$key" ] || continue
    # An In flight row is either its own worker's unit or a member some unit
    # delivers; either way the live worker is what a caller has to reach.
    owner=
    if fm_grouping_task_is_live "$state" "$id"; then
      owner=$id
    else
      for meta in "$state"/*.meta; do
        [ -f "$meta" ] && [ ! -L "$meta" ] || continue
        owner=${meta##*/}
        owner=${owner%.meta}
        if [ "$owner" != "$unit" ] && fm_grouping_task_is_live "$state" "$owner" \
          && fm_backlog_members_of_meta "$meta" "$owner" \
          && printf '%s\n' "${FM_BACKLOG_TRANSITION_MEMBERS[@]+"${FM_BACKLOG_TRANSITION_MEMBERS[@]}"}" \
            | grep -qxF "$id"; then
          break
        fi
        owner=
      done
    fi
    [ -n "$owner" ] || continue
    case " $found " in
      *" $owner "*) continue ;;
    esac
    found="${found:+$found }$owner"
  done <<EOF
$rows
EOF
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_GROUPING_LIVE_SIBLINGS=$found
}

# WHAT A DISPATCH OF <id> WOULD START BESIDE. This is the whole question the
# guard at each entry point asks, answered once here so the two commands that
# start a ship worker - bin/fm-spawn.sh and bin/fm-promote.sh - cannot drift
# apart on it. Findings land in FM_GROUPING_FINDINGS, one per line, each naming
# what was found and the command that resolves it; a read that cannot answer is
# a finding too, never a silent pass. <delivers> is the membership the dispatch
# already names, so work it is about to deliver is not reported against it.
# Status: 0 nothing found, 1 findings, 2 the posture itself is unreadable.
fm_grouping_dispatch_findings() {  # <data-dir> <state-dir> <config-dir> <id> <delivers-csv>
  local data=$1 state=$2 config=$3 id=$4 delivers=${5-}
  local repo key status plan planned missing extra sibling
  local -a wanted=()
  FM_GROUPING_FINDINGS=
  fm_grouping_posture "$config" || return 2
  [ "$FM_GROUPING_POSTURE" != off ] || return 0

  fm_grouping_repo_of_row "$data" "$id"
  status=$?
  # An item with no backlog row of its own is refused by the dispatch gate
  # itself, which is a better error than anything this could say about it.
  [ "$status" -ne 3 ] || return 0
  if [ "$status" -ne 0 ]; then
    fm_grouping_add_finding "cannot tell what repository $id belongs to: $FM_GROUPING_ERROR"
    repo=
  else
    repo=$FM_GROUPING_REPO
  fi
  fm_grouping_key_of_row "$data" "$id"
  status=$?
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    fm_grouping_add_finding "cannot tell what group $id belongs to: $FM_GROUPING_ERROR"
    key=
  else
    key=$FM_GROUPING_KEY
  fi

  # The plan a chunk recorded on this unit. Membership stays explicit - the
  # dispatch names what it delivers - and this only stops the OMISSION, because
  # a forgotten member unblocks when the unit closes and surfaces later as the
  # lone ticket this contract exists to prevent.
  if fm_grouping_plan_of_row "$data" "$id"; then
    plan=$FM_GROUPING_PLAN
    if [ -n "$plan" ]; then
      missing=''
      for planned in ${plan//,/ }; do
        case ",$delivers," in
          *",$planned,"*) continue ;;
        esac
        # A planned member the captain has since held cannot be delivered at
        # all, so naming it is not the resolution; releasing it is.
        if fm_backlog_row_probe "$data" "$planned"; then
          case "$FM_BACKLOG_ROW_STATE" in
            *' yes '*)
              fm_grouping_add_finding "$id plans to deliver $planned, which is held: release it first, or dispatch without it"
              continue
              ;;
          esac
        fi
        missing="${missing:+$missing,}$planned"
      done
      if [ -n "$missing" ]; then
        extra=$delivers
        for planned in ${missing//,/ }; do
          extra="${extra:+$extra,}$planned"
        done
        fm_grouping_add_finding "$id plans to deliver $missing, which this dispatch does not name; name them at dispatch (bin/fm-spawn.sh --delivers $extra)"
      fi
    fi
  elif [ -n "$FM_GROUPING_ERROR" ]; then
    fm_grouping_add_finding "cannot tell what $id plans to deliver: $FM_GROUPING_ERROR"
  fi

  if fm_grouping_relatable "$repo" "$key"; then
    if fm_grouping_ready_siblings "$data" "$state" "$id" "$repo" "$key"; then
      for sibling in $FM_GROUPING_READY_SIBLINGS; do
        case ",$delivers," in
          *",$sibling,"*) continue ;;
        esac
        wanted+=("$sibling")
      done
      if [ "${#wanted[@]}" -gt 0 ]; then
        extra=$delivers
        for sibling in "${wanted[@]}"; do
          extra="${extra:+$extra,}$sibling"
        done
        fm_grouping_add_finding "${wanted[*]} is ready work in $repo under the same group key ($key); deliver it in the same job (bin/fm-spawn.sh --delivers $extra), or plan a chunk with bin/fm-tasks-axi.sh chunk"
      fi
    else
      fm_grouping_add_finding "cannot tell whether $id has ready siblings: $FM_GROUPING_ERROR"
    fi
    if fm_grouping_live_siblings "$data" "$state" "$id" "$repo" "$key"; then
      for sibling in $FM_GROUPING_LIVE_SIBLINGS; do
        fm_grouping_add_finding "$sibling is already working $repo's $key group; hand this item to it with bin/fm-tasks-axi.sh join $sibling $id"
      done
    else
      fm_grouping_add_finding "cannot tell whether $id has a live sibling: $FM_GROUPING_ERROR"
    fi
  else
    fm_grouping_needs_planning "$data" "$state" "$id" "$repo" "$key"
    case "$?" in
      0)
        fm_grouping_add_finding "$id carries no group key while this home holds other ready or live ship work in $repo; record what it belongs with (bin/fm-tasks-axi.sh group $id <key>), or that it belongs with nothing (bin/fm-tasks-axi.sh group $id --solo)"
        ;;
      2)
        fm_grouping_add_finding "cannot tell whether $id needs a group key: $FM_GROUPING_ERROR"
        ;;
    esac
  fi

  [ -n "$FM_GROUPING_FINDINGS" ] || return 0
  return 1
}

fm_grouping_add_finding() {  # <line>
  FM_GROUPING_FINDINGS="${FM_GROUPING_FINDINGS}$1"$'\n'
}

# The findings as an operator reads them, one indented line each under the id.
fm_grouping_report_findings() {  # <id>
  local id=$1 line
  printf 'grouping: %s\n' "$id"
  while IFS= read -r line; do
    [ -z "$line" ] || printf 'grouping:   %s\n' "$line"
  done <<FINDINGS
$FM_GROUPING_FINDINGS
FINDINGS
}

# A body with the <prefix> line removed, along with the blank line that
# separated it, so dissolving a chunk leaves the body it found.
fm_grouping_body_without_line() {  # <body> <prefix>
  local body=${1-} prefix=$2 line out=''
  while IFS= read -r line; do
    case "$line" in
      "$prefix"*) continue ;;
    esac
    out="$out$line"$'\n'
  done <<BODY
$body
BODY
  out=${out%$'\n'}
  while :; do
    case "$out" in
      *$'\n\n') out=${out%$'\n'} ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$out"
}
