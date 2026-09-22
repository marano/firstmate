#!/usr/bin/env bash
# fm-install-pinned-tools.sh - install the pinned external linters a caller
# actually needs, and nothing else.
#
# It exists so no CI job downloads a tool its work never invokes. A
# release-download outage on 2026-09-21 reddened six jobs across two main runs
# of firstmate, and five of the six were lanes that never invoke the tool whose
# download failed. Every lane job used to install both pinned linters
# unconditionally, so every lane carried the full blast radius of both releases.
#
# The tool names are NOT chosen by the caller's own judgement. A lane job asks
# the runner which tools its lane's tests need and pipes that answer in here:
#
#   bin/fm-test-run.sh --list-required-tools --lane portable-parallel-1 \
#     | bin/fm-install-pinned-tools.sh "$RUNNER_TEMP/bin"
#
# bin/fm-test-run.sh's script_required_tools is the single owner of which test
# needs which tool, and lane membership there derives the rest, so no workflow
# file carries a per-job tool matrix that can rot away from the lanes.
#
# Usage:
#   fm-install-pinned-tools.sh <destination-directory> [<tool>...]
#                   install each named tool into <destination-directory>.
#                   With no tool arguments it reads the names from stdin, one
#                   per line; an empty list installs nothing and exits 0, which
#                   is the correct outcome for a lane that needs no linter.
#   fm-install-pinned-tools.sh --list
#                   print every installable tool name, one per line.
#   fm-install-pinned-tools.sh --installer <tool>
#                   print the repository installer that provides <tool>.
#   fm-install-pinned-tools.sh --help
#
# An unknown tool name is refused rather than skipped, and a failed install is
# fatal: a lane that genuinely needs the binary must still fail loudly when it
# cannot get one, so the outage class this script narrows stays visible exactly
# where it is a real dependency.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/bin/fm-install-pinned-tools.sh"

# The single owner of the tool-to-installer mapping, as "<tool><TAB><installer>"
# lines. bin/fm-test-run.sh's coverage guard validates its own requirement table
# against these names rather than keeping a second copy of them.
known_tools() {
  local t=$'\t'
  cat <<EOF
actionlint${t}bin/fm-install-actionlint.sh
shellcheck${t}bin/fm-install-shellcheck.sh
EOF
}

die() {
  printf 'fm-install-pinned-tools.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

installer_for() {  # <tool>
  known_tools | awk -F '\t' -v want="$1" '$1 == want { print $2; found = 1 }
    END { exit found ? 0 : 1 }'
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list)
    [ "$#" -eq 1 ] || die "--list takes no further arguments"
    known_tools | cut -f1
    exit 0
    ;;
  --installer)
    [ "$#" -eq 2 ] || die "--installer takes exactly one tool name"
    installer_for "$2" || die "unknown tool: $2 (see --list)"
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
  -*)
    die "unknown option: $1 (see --help)"
    ;;
esac

DESTINATION=$1
shift
[ -n "$DESTINATION" ] || die "a destination directory is required"

TOOLS=
if [ "$#" -gt 0 ]; then
  TOOLS=$(printf '%s\n' "$@")
else
  TOOLS=$(cat)
fi

# Duplicates cost a whole redundant download, and the union of several lanes is
# the obvious way to get one, so collapse them here rather than at every caller.
TOOLS=$(printf '%s\n' "$TOOLS" | LC_ALL=C sort -u)

installed=0
while IFS= read -r tool; do
  [ -n "$tool" ] || continue
  installer=$(installer_for "$tool") || die "unknown tool: $tool (see --list)"
  [ -x "$ROOT/$installer" ] || die "$installer is missing or not executable"
  printf 'fm-install-pinned-tools.sh: installing %s into %s\n' "$tool" "$DESTINATION"
  "$ROOT/$installer" "$DESTINATION"
  installed=$((installed + 1))
done <<EOF
$TOOLS
EOF

printf 'fm-install-pinned-tools.sh: installed %s pinned tool(s) into %s\n' \
  "$installed" "$DESTINATION"
