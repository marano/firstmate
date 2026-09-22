#!/usr/bin/env bash
# fm-linear-lib.sh - the single owner of firstmate's Linear board moves.
#
# Sourced, never executed.
#
# WHY IT EXISTS. The captain's Linear board is how he sees what is being worked
# on without asking. Two transitions keep it true, and only those two: a card
# reaches the team's started status when its worker is dispatched, and the
# team's completed status when its pull request merges. Everything else on that
# board belongs to the captain. A rule alone was not enough - a backlog item
# recorded no Linear identifier, so nothing at dispatch or merge named the card
# to move, and the move relied on firstmate remembering.
#
# THE IDENTIFIER. A backlog item carries its card as one `Linear card: BLU-3268`
# line in its own body, in the same namespaced shape as bin/fm-grouping-lib.sh's
# group key and bin/fm-captain-hold.sh's hold stamp, so imported ticket prose
# cannot collide with it. `bin/fm-tasks-axi.sh linear` records and reads it, and
# carries it across a body rewrite. Two such lines are refused rather than
# resolved by position. This is NOT bin/fm-grouping-lib.sh's group key: a key is
# shared by every item of one epic, while a card names one item.
#
# ACTIVATION. The board is off, and this library completely silent, unless the
# home resolves a Linear API key (FM_LINEAR_API_KEY in the environment, else in
# the home's gitignored .env). Only a home that actually uses the board reports
# an item that carries no card. docs/configuration.md "Linear board (.env)" owns
# the configuration schema.
#
# THE THREE RULES EVERY MOVE OBEYS.
#   - A MISSING identifier is not an error: most items have no card and never
#     will. It is reported and the caller proceeds.
#   - NEVER BACKWARDS. The card's current status type is read first, and a card
#     already past the phase being applied is left exactly where it is. A card
#     the captain moved by hand is never undone. `canceled` counts as past both
#     phases, because resurrecting a cancelled card is the same harm.
#   - NEVER a status beyond the team's own started and completed types, so
#     `Verified` - the captain's own status - is unreachable from here. The
#     target is resolved from the team's workflow rather than by name.
#
# A FAILURE NEVER FAILS THE CALLER. The worker starting and the pull request
# landing both matter more than the board. fm_linear_board_advance always
# succeeds; a transport, HTTP, or GraphQL failure is reported as an
# `actionable:` line on stderr, the same convention bin/fm-pr-merge.sh uses for
# a merge that landed but whose branch could not be deleted.
#
# It defines:
#   fm_linear_identifier_valid <value>      - is this a Linear issue identifier
#   fm_linear_card_of_body <body>           - the card a decoded body carries
#   fm_linear_card_of_row <data> <id>       - the card a backlog item carries
#   fm_linear_api_key <home>                - the resolved key, in FM_LINEAR_KEY
#   fm_linear_request <home> <query> <vars> - one bounded GraphQL call
#   fm_linear_board_advance <home> <data> <phase> <id>... - the entry point
#
# THE INJECTABLE SEAM. fm_linear_request posts to FM_LINEAR_API_URL with curl,
# unless FM_LINEAR_CMD names a command; that command is then run with the
# request-body file as its only argument and must print the response JSON on
# stdout. Both paths are bounded by bin/fm-timeout-lib.sh's fm_run_timed, so a
# wedged transport cannot hold a dispatch or a merge open. Tests reach every
# behavior through that seam, because they cannot call Linear.
set -u

# Each dependency is guarded on a function of ITS OWN, never on a sibling's: a
# caller can already have sourced the backlog library without the tasks-axi
# library it in turn needs (bin/fm-pr-merge.sh does exactly that), and a shared
# guard would then skip the one that is actually missing.
_FM_LINEAR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v fm_tasks_axi_backend >/dev/null 2>&1; then
  # shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
  . "$_FM_LINEAR_LIB_DIR/fm-tasks-axi-lib.sh"
fi
if ! command -v fm_backlog_row_field >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
  . "$_FM_LINEAR_LIB_DIR/fm-backlog-transition-lib.sh"
fi
if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$_FM_LINEAR_LIB_DIR/fm-timeout-lib.sh"
fi

# The body line that carries the card. See THE IDENTIFIER above.
FM_LINEAR_CARD_PREFIX="Linear card: "

FM_LINEAR_CARD=
FM_LINEAR_KEY=
FM_LINEAR_ERROR=
FM_LINEAR_RESPONSE=

# A Linear issue identifier: a team key, a hyphen, and the issue number, as
# Linear itself prints one (BLU-3268). The grammar is narrow on purpose - the
# value reaches a body line, a command line, and a GraphQL variable - and it is
# what keeps the body-line parser from matching prose that merely mentions a
# ticket: a sentence carrying "BLU-3268" is not a line whose whole value is it.
fm_linear_identifier_valid() {  # <value>
  local value=${1-} team number
  local LC_ALL=C
  case "$value" in
    [A-Z]*-[1-9]*) ;;
    *) return 1 ;;
  esac
  team=${value%%-*}
  number=${value#*-}
  case "$team" in
    '' | *[!A-Z0-9]*) return 1 ;;
  esac
  case "$number" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#team}" -le 16 ] && [ "${#number}" -le 12 ]
}

# The card a decoded body carries, printed empty when it carries none. TWO card
# lines are refused (status 2) rather than resolved by position, the same rule
# bin/fm-grouping-lib.sh's key and bin/fm-meta-keys-lib.sh's record keys give: a
# second copy is how one silently redefines what every reader sees.
fm_linear_card_of_body() {  # <body>
  local body=${1-} line card='' seen=0
  while IFS= read -r line; do
    case "$line" in
      "$FM_LINEAR_CARD_PREFIX"*)
        seen=$((seen + 1))
        card=${line#"$FM_LINEAR_CARD_PREFIX"}
        ;;
    esac
  done <<EOF
$body
EOF
  [ "$seen" -le 1 ] || return 2
  printf '%s\n' "$card"
}

# The card recorded on <id>, in FM_LINEAR_CARD (empty when the item has none).
# Status: 0 read, 1 the body is unusable, 2 cannot tell, 3 no such row.
fm_linear_card_of_row() {  # <data-dir> <id>
  local data=$1 id=$2 status card
  FM_LINEAR_CARD=
  FM_LINEAR_ERROR=
  status=0
  fm_backlog_row_field "$data" "$id" body || status=$?
  case "$status" in
    0) ;;
    3) FM_LINEAR_ERROR="$id has no backlog item in this home"; return 3 ;;
    *)
      FM_LINEAR_ERROR="${FM_BACKLOG_TRANSITION_ERROR:-cannot read the body of $id}"
      return 2
      ;;
  esac
  card=$(fm_linear_card_of_body "$FM_BACKLOG_ROW_FIELD_VALUE") || {
    FM_LINEAR_ERROR="$id carries more than one '${FM_LINEAR_CARD_PREFIX%%:*}' line; leave exactly one"
    return 1
  }
  if [ -n "$card" ] && ! fm_linear_identifier_valid "$card"; then
    FM_LINEAR_ERROR="$id carries an unreadable Linear card '$card'; a card reads like BLU-3268"
    return 1
  fi
  FM_LINEAR_CARD=$card
}

# The home's Linear API key, in FM_LINEAR_KEY. The environment wins over the
# home's .env, matching the mail-plane and Relay contracts. Status 1 when the
# home has no key at all, which is what keeps a home that does not use the board
# entirely silent.
fm_linear_api_key() {  # <home>
  local home=$1 env_file
  FM_LINEAR_KEY=
  if [ -n "${FM_LINEAR_API_KEY:-}" ]; then
    FM_LINEAR_KEY=$FM_LINEAR_API_KEY
    return 0
  fi
  env_file="${FM_LINEAR_ENV_FILE:-$home/.env}"
  [ -f "$env_file" ] && [ ! -L "$env_file" ] || return 1
  FM_LINEAR_KEY=$(
    LC_ALL=C sed -n \
      's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}FM_LINEAR_API_KEY=//p' \
      "$env_file" 2>/dev/null | tail -n1
  ) || FM_LINEAR_KEY=
  FM_LINEAR_KEY=${FM_LINEAR_KEY%%$'\r'}
  FM_LINEAR_KEY=${FM_LINEAR_KEY#"${FM_LINEAR_KEY%%[![:space:]]*}"}
  FM_LINEAR_KEY=${FM_LINEAR_KEY%"${FM_LINEAR_KEY##*[![:space:]]}"}
  case "$FM_LINEAR_KEY" in
    \"*\") FM_LINEAR_KEY=${FM_LINEAR_KEY#\"}; FM_LINEAR_KEY=${FM_LINEAR_KEY%\"} ;;
    \'*\') FM_LINEAR_KEY=${FM_LINEAR_KEY#\'}; FM_LINEAR_KEY=${FM_LINEAR_KEY%\'} ;;
  esac
  [ -n "$FM_LINEAR_KEY" ]
}

# One GraphQL call. The response body lands in FM_LINEAR_RESPONSE rather than on
# stdout, deliberately: reading it through a command substitution would run this
# function in a SUBSHELL, where the FM_LINEAR_ERROR it sets on failure dies with
# that subshell and every failure reports an empty reason. Status 1 with
# FM_LINEAR_ERROR set for a missing tool, an expired bound, a transport or HTTP
# failure, or a response carrying GraphQL errors. <vars> is a JSON object built
# by the caller with jq, never by string concatenation.
fm_linear_request() {  # <home> <query> <vars-json>
  local home=$1 query=$2 vars=$3
  local bound body_file out_file status errors
  FM_LINEAR_ERROR=
  FM_LINEAR_RESPONSE=
  bound=${FM_LINEAR_TIMEOUT:-20}
  case "$bound" in
    '' | *[!0-9]* | 0) bound=20 ;;
  esac
  command -v jq >/dev/null 2>&1 || {
    FM_LINEAR_ERROR="jq is needed to talk to Linear and is not on PATH"
    return 1
  }
  body_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-linear-req.XXXXXX") || {
    FM_LINEAR_ERROR="cannot stage the Linear request"
    return 1
  }
  out_file="$body_file.out"
  if ! jq -n --arg q "$query" --argjson v "$vars" '{query: $q, variables: $v}' \
    > "$body_file" 2>/dev/null; then
    rm -f -- "$body_file"
    FM_LINEAR_ERROR="cannot build the Linear request"
    return 1
  fi
  status=0
  if [ -n "${FM_LINEAR_CMD:-}" ]; then
    fm_run_timed "$bound" "$FM_LINEAR_CMD" "$body_file" > "$out_file" 2>/dev/null || status=$?
  else
    command -v curl >/dev/null 2>&1 || {
      rm -f -- "$body_file" "$out_file"
      FM_LINEAR_ERROR="curl is needed to talk to Linear and is not on PATH"
      return 1
    }
    # The key travels in a header file rather than an argument, so it never
    # appears in this host's process list.
    if ! printf 'Authorization: %s\n' "$FM_LINEAR_KEY" > "$body_file.hdr"; then
      rm -f -- "$body_file" "$body_file.hdr"
      FM_LINEAR_ERROR="cannot stage the Linear credential"
      return 1
    fi
    fm_run_timed "$bound" curl -sS -X POST \
      -H 'Content-Type: application/json' \
      -H @"$body_file.hdr" \
      --data-binary @"$body_file" \
      "${FM_LINEAR_API_URL:-https://api.linear.app/graphql}" \
      > "$out_file" 2>/dev/null || status=$?
    rm -f -- "$body_file.hdr"
  fi
  rm -f -- "$body_file"
  if [ "$status" -eq 124 ]; then
    rm -f -- "$out_file"
    FM_LINEAR_ERROR="Linear did not answer within ${bound}s"
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    rm -f -- "$out_file"
    FM_LINEAR_ERROR="the call to Linear failed (status $status)"
    return 1
  fi
  if ! jq -e . "$out_file" >/dev/null 2>&1; then
    rm -f -- "$out_file"
    FM_LINEAR_ERROR="Linear answered with something that is not JSON"
    return 1
  fi
  errors=$(jq -r 'if (.errors | type) == "array" then
      [.errors[]? | .message // "unspecified"] | join("; ")
    else "" end' "$out_file" 2>/dev/null) || errors=''
  if [ -n "$errors" ]; then
    rm -f -- "$out_file"
    FM_LINEAR_ERROR="Linear refused the request: $errors"
    return 1
  fi
  FM_LINEAR_RESPONSE=$(cat "$out_file") || FM_LINEAR_RESPONSE=''
  rm -f -- "$out_file"
}

# The one query: the card, its current status, and every workflow state its team
# defines. The issue is addressed by team key and number rather than by a
# convenience lookup, so the match is unambiguous and a second match can be
# refused. `first: 2` is deliberate - one extra row is all it takes to prove the
# address was not unique.
# shellcheck disable=SC2016 # GraphQL variables, deliberately not shell expansions.
_FM_LINEAR_CARD_QUERY='query FmCard($team: String!, $number: Float!) {
  issues(filter: {team: {key: {eq: $team}}, number: {eq: $number}}, first: 2) {
    nodes {
      id
      identifier
      state { id name type }
      team { key states(first: 250) { nodes { id name type position } } }
    }
  }
}'

# shellcheck disable=SC2016 # GraphQL variables, deliberately not shell expansions.
_FM_LINEAR_MOVE_MUTATION='mutation FmMove($id: String!, $state: String!) {
  issueUpdate(id: $id, input: {stateId: $state}) { success }
}'

# The status types a card must already be at or past for each phase, so the move
# is skipped rather than pulling the card backwards. `start` also declines a card
# that is already completed or cancelled; `merge` declines only those two,
# because a started card is exactly what a merge advances.
_fm_linear_phase_declines() {  # <phase> <current-type>
  local phase=$1 current=$2
  case "$phase" in
    start)
      case "$current" in
        started | completed | canceled) return 0 ;;
      esac
      ;;
    merge)
      case "$current" in
        completed | canceled) return 0 ;;
      esac
      ;;
  esac
  return 1
}

_fm_linear_phase_target_type() {  # <phase>
  case "$1" in
    start) printf 'started\n' ;;
    merge) printf 'completed\n' ;;
    *) return 1 ;;
  esac
}

# Move one card for one phase. Prints its own outcome line and returns 0 for
# every outcome a caller must not fail on; see fm_linear_board_advance.
_fm_linear_move_card() {  # <home> <phase> <task-id> <card>
  local home=$1 phase=$2 task=$3 card=$4
  local team number target_type response count issue_id current_type current_name
  local target_id target_name success vars
  team=${card%%-*}
  number=${card#*-}
  target_type=$(_fm_linear_phase_target_type "$phase") || return 0

  vars=$(jq -n --arg t "$team" --argjson n "$number" '{team: $t, number: $n}' 2>/dev/null) || {
    printf 'actionable: could not build the Linear lookup for %s (%s)\n' "$card" "$task" >&2
    return 0
  }
  if ! fm_linear_request "$home" "$_FM_LINEAR_CARD_QUERY" "$vars"; then
    printf 'actionable: the Linear card %s recorded on %s could not be read: %s\n' \
      "$card" "$task" "$FM_LINEAR_ERROR" >&2
    return 0
  fi

  response=$FM_LINEAR_RESPONSE
  count=$(printf '%s' "$response" | jq -r '.data.issues.nodes | length' 2>/dev/null) || count=''
  case "$count" in
    0) printf 'actionable: %s records the Linear card %s, which Linear has no issue for\n' "$task" "$card" >&2; return 0 ;;
    1) ;;
    '') printf 'actionable: Linear answered about %s in a shape this home cannot read\n' "$card" >&2; return 0 ;;
    *) printf 'actionable: %s matches %s Linear issues, so none was moved\n' "$card" "$count" >&2; return 0 ;;
  esac

  issue_id=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].id // ""' 2>/dev/null) || issue_id=''
  current_type=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].state.type // ""' 2>/dev/null) || current_type=''
  current_name=$(printf '%s' "$response" | jq -r '.data.issues.nodes[0].state.name // ""' 2>/dev/null) || current_name=''
  if [ -z "$issue_id" ] || [ -z "$current_type" ]; then
    printf 'actionable: Linear answered about %s without its status, so it was left alone\n' "$card" >&2
    return 0
  fi

  if _fm_linear_phase_declines "$phase" "$current_type"; then
    printf 'linear: %s left in %s, which is already at or past this point\n' "$card" "${current_name:-$current_type}"
    return 0
  fi

  # The team's own first status of the wanted type, in its workflow order. This
  # is what keeps a second completed status the captain owns - `Verified` - out
  # of reach without naming it here, and the chosen name is always reported so a
  # team whose workflow is ordered unusually is visible on the first move.
  target_id=$(printf '%s' "$response" | jq -r --arg t "$target_type" \
    '[.data.issues.nodes[0].team.states.nodes[]? | select(.type == $t)]
     | sort_by(.position) | (.[0].id // "")' 2>/dev/null) || target_id=''
  target_name=$(printf '%s' "$response" | jq -r --arg t "$target_type" \
    '[.data.issues.nodes[0].team.states.nodes[]? | select(.type == $t)]
     | sort_by(.position) | (.[0].name // "")' 2>/dev/null) || target_name=''
  if [ -z "$target_id" ]; then
    printf 'actionable: team %s defines no %s status, so %s was left in %s\n' \
      "$team" "$target_type" "$card" "${current_name:-$current_type}" >&2
    return 0
  fi

  vars=$(jq -n --arg id "$issue_id" --arg state "$target_id" '{id: $id, state: $state}' 2>/dev/null) || {
    printf 'actionable: could not build the Linear move for %s\n' "$card" >&2
    return 0
  }
  if ! fm_linear_request "$home" "$_FM_LINEAR_MOVE_MUTATION" "$vars"; then
    printf 'actionable: %s could not be moved to %s: %s\n' "$card" "$target_name" "$FM_LINEAR_ERROR" >&2
    return 0
  fi
  success=$(printf '%s' "$FM_LINEAR_RESPONSE" | jq -r '.data.issueUpdate.success // false' 2>/dev/null) || success=''

  if [ "$success" != true ]; then
    printf 'actionable: Linear did not accept moving %s to %s\n' "$card" "$target_name" >&2
    return 0
  fi
  printf 'linear: %s moved to %s\n' "$card" "$target_name"
}

# THE ENTRY POINT. Advance every named item's card for <phase> (`start` at
# dispatch, `merge` after a merge is proven). ALWAYS returns 0: a caller adds
# this line without guarding it, because the board is never worth failing a
# dispatch or a merge over. Silent when this home has no Linear key.
#
# errexit is suspended for the body and restored before returning. Both callers
# run under `set -e`, where ANY unchecked nonzero inside this function - a jq
# that cannot parse, a backlog read that cannot reach tasks-axi - would exit the
# caller instead of being reported, which is precisely the failure this contract
# exists to prevent. Guarding each command is not enough on its own: the next
# command added here would silently re-acquire that power.
fm_linear_board_advance() {  # <home> <data-dir> <phase> <task-id>...
  local errexit=0
  case $- in *e*) errexit=1; set +e ;; esac
  _fm_linear_advance_each "$@"
  [ "$errexit" -eq 0 ] || set -e
  return 0
}

# The body of the entry point above, kept separate so it can return early
# wherever it needs to while the errexit restore stays on one path.
_fm_linear_advance_each() {  # <home> <data-dir> <phase> <task-id>...
  local home=$1 data=$2 phase=$3
  local task status
  shift 3
  [ "$#" -gt 0 ] || return 0
  _fm_linear_phase_target_type "$phase" >/dev/null || return 0
  fm_linear_api_key "$home" || return 0
  for task in "$@"; do
    fm_linear_card_of_row "$data" "$task"
    status=$?
    case "$status" in
      0) ;;
      3) continue ;;
      *) printf 'actionable: %s\n' "$FM_LINEAR_ERROR" >&2; continue ;;
    esac
    if [ -z "$FM_LINEAR_CARD" ]; then
      printf 'linear: %s has no Linear card, so the board was left alone\n' "$task"
      continue
    fi
    _fm_linear_move_card "$home" "$phase" "$task" "$FM_LINEAR_CARD"
  done
}
