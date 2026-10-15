#!/usr/bin/env bash
# Single owner of what counts as supervision text leaking into a project.
#
# Work a task ships into a project must read as ordinary engineering work, so
# none of these may reach a project's pull request title or body, its commit
# messages, or the lines its diff adds:
#   * the whole word "captain", ignoring case - an identifier such as
#     TEAM_CAPTAIN or captainId is not the word and does not match;
#   * "firstmate", ignoring case, anywhere;
#   * the absolute path of the firstmate home doing the merging, as written and
#     as its physical path;
#   * a dated quotation: a line opening with "Request of", "Requests of" or
#     "Later request of", then a date, then a double-quoted span - the shape
#     that published an operator's own words as a pull request's intent.
# FM_LEAK_QUOTE_SHAPE_ERE is that last shape as one POSIX ERE, matched against
# the LOWERCASED line in the C locale; a brief guard that refuses the same
# shape before spawn reuses it rather than keeping a second copy.
#
# bin/fm-leak-check.sh reads a pull request or a local branch and feeds these
# scanners; bin/fm-pr-merge.sh and bin/fm-merge-local.sh refuse a merge on any
# hit and bin/fm-pr-check.sh reports the same hits as warnings when a PR is
# recorded. The firstmate repository itself is exempt, because its own tracked
# material legitimately names all of this (fm_leak_self_pr,
# fm_leak_self_project).

FM_LEAK_MONTH_ERE='(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[.]?'
FM_LEAK_DATE_ERE="([0-9][0-9][0-9][0-9]-[0-9]|[0-9]+/[0-9]|$FM_LEAK_MONTH_ERE [0-9]|[0-9] $FM_LEAK_MONTH_ERE)"
# An optional list or quote marker, the opener, a date before the quotation,
# then an opening straight or typographic double quote with content after it.
FM_LEAK_OPEN_QUOTE_ERE='("|“)'
FM_LEAK_QUOTE_SHAPE_ERE="^[[:space:]]*([-*>][[:space:]]*)*(later request|requests?) of [^\"]*${FM_LEAK_DATE_ERE}[^\"]*${FM_LEAK_OPEN_QUOTE_ERE}[[:space:]]*[^\"[:space:]]"

# The awk body shared by both scanners: leak_rules(line) returns the comma
# separated rules a line breaks, or "". Inputs come through ENVIRON, never -v,
# so no awk escape processing touches the pattern or a home path.
# shellcheck disable=SC2016  # awk source, expanded by awk rather than the shell.
FM_LEAK_AWK_RULES='
function leak_add(list, rule) { return list == "" ? rule : list ", " rule }
function leak_rules(line,   lower, r) {
  lower = tolower(line)
  r = ""
  if (lower ~ /(^|[^a-z0-9_])captain([^a-z0-9_]|$)/) r = leak_add(r, "the word \"captain\"")
  if (index(lower, "firstmate")) r = leak_add(r, "\"firstmate\"")
  if ((ENVIRON["FM_LEAK_HOME1"] != "" && index(line, ENVIRON["FM_LEAK_HOME1"])) ||
      (ENVIRON["FM_LEAK_HOME2"] != "" && index(line, ENVIRON["FM_LEAK_HOME2"])))
    r = leak_add(r, "the firstmate home path")
  if (lower ~ ENVIRON["FM_LEAK_QUOTE_ERE"]) r = leak_add(r, "a dated quotation of a request")
  return r
}
function leak_excerpt(line) {
  gsub(/[[:cntrl:]]/, " ", line)
  sub(/^[[:space:]]+/, "", line)
  return length(line) > 120 ? substr(line, 1, 117) "..." : line
}
function leak_report(where, line,   r) {
  r = leak_rules(line)
  if (r == "") return
  printf "leak: %s: %s: %s\n", where, r, leak_excerpt(line)
  hits++
}
'

# The home path forms to look for: as given and as its physical path. A path
# too short to be distinctive (the root, or empty) is not searched for.
fm_leak_home_forms() {  # <home>; sets FM_LEAK_HOME1 FM_LEAK_HOME2
  local home=${1-} physical=''
  FM_LEAK_HOME1=
  FM_LEAK_HOME2=
  home=${home%/}
  case "$home" in
    /?*) FM_LEAK_HOME1=$home ;;
    *) return 0 ;;
  esac
  physical=$(cd "$home" 2>/dev/null && pwd -P) || physical=
  physical=${physical%/}
  case "$physical" in
    /?*) [ "$physical" = "$home" ] || FM_LEAK_HOME2=$physical ;;
  esac
}

# fm_leak_scan_text <where> <numbered:0|1> <home>: scan stdin as free text and
# print one `leak: <where>[ line N]: <rules>: <excerpt>` line per offending
# line. Exit 1 when anything was printed, 0 when the text is clean.
fm_leak_scan_text() {
  local where=$1 numbered=$2
  fm_leak_home_forms "${3-}"
  FM_LEAK_HOME1=$FM_LEAK_HOME1 FM_LEAK_HOME2=$FM_LEAK_HOME2 \
    FM_LEAK_QUOTE_ERE=$FM_LEAK_QUOTE_SHAPE_ERE FM_LEAK_WHERE=$where \
    FM_LEAK_NUMBERED=$numbered LC_ALL=C awk "$FM_LEAK_AWK_RULES"'
    {
      where = ENVIRON["FM_LEAK_WHERE"]
      if (ENVIRON["FM_LEAK_NUMBERED"] == "1") where = where " line " NR
      leak_report(where, $0)
    }
    END { exit hits > 0 }
  '
}

# fm_leak_scan_diff <home>: scan a unified diff on stdin and report only the
# lines it ADDS, as `leak: <file>:<new line number>: <rules>: <excerpt>`.
# Removed and context lines never count, so a change that deletes leaked text
# passes. A `+++ <path>` header outside a hunk names the file, which also
# accepts per-file hunks with a synthesized header and no `diff --git` line.
# Exit 1 when anything was printed, 0 when the added lines are clean.
fm_leak_scan_diff() {
  fm_leak_home_forms "${1-}"
  FM_LEAK_HOME1=$FM_LEAK_HOME1 FM_LEAK_HOME2=$FM_LEAK_HOME2 \
    FM_LEAK_QUOTE_ERE=$FM_LEAK_QUOTE_SHAPE_ERE LC_ALL=C awk "$FM_LEAK_AWK_RULES"'
    function hunk_count(spec,   parts) {
      return split(spec, parts, ",") > 1 ? parts[2] + 0 : 1
    }
    function hunk_start(spec,   parts) {
      split(spec, parts, ",")
      return parts[1] + 0
    }
    /^diff --git / { file = ""; in_hunk = 0; next }
    !in_hunk && /^\+\+\+ / {
      path = substr($0, 5)
      sub(/\t.*$/, "", path)
      if (path == "/dev/null") file = ""
      else { sub(/^b\//, "", path); file = path }
      next
    }
    !in_hunk && /^@@ / {
      split($0, f, " ")
      old_left = hunk_count(substr(f[2], 2))
      new_left = hunk_count(substr(f[3], 2))
      new_line = hunk_start(substr(f[3], 2))
      in_hunk = (old_left > 0 || new_left > 0)
      next
    }
    in_hunk {
      mark = substr($0, 1, 1)
      if (mark == "\\") next
      if (mark == "+") {
        leak_report((file == "" ? "(unnamed file)" : file) ":" new_line, substr($0, 2))
        new_line++; new_left--
      } else if (mark == "-") {
        old_left--
      } else {
        new_line++; new_left--; old_left--
      }
      if (old_left <= 0 && new_left <= 0) in_hunk = 0
    }
    END { exit hits > 0 }
  '
}

# fm_leak_remote_identity <url>: a remote URL as lowercase host/path with any
# userinfo, port, trailing slash and .git suffix removed, so the https, ssh and
# scp-like spellings of one repository compare equal. A local path has no
# forge identity and fails.
fm_leak_remote_identity() {
  local url=${1-} rest host path
  case "$url" in
    *://*)
      rest=${url#*://}
      rest=${rest#*@}
      host=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 1
      host=${host%%:*}
      ;;
    /*|.*|'') return 1 ;;
    *:*)
      rest=${url#*@}
      host=${rest%%:*}
      path=${rest#*:}
      ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  path=${path#/}
  [ -n "$host" ] && [ -n "$path" ] || return 1
  printf '%s/%s\n' "$host" "$path" | tr '[:upper:]' '[:lower:]'
}

# The forge identities of every remote of a git directory, one per line.
fm_leak_repo_identities() {  # <git-dir>
  local dir=$1 remote
  git -C "$dir" remote 2>/dev/null | while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    fm_leak_remote_identity "$(git -C "$dir" remote get-url "$remote" 2>/dev/null)" || true
  done
}

# fm_leak_self_pr <fm-root> <host> <path>: 0 when the pull request's repository
# is a remote of the firstmate code root, i.e. firstmate itself.
fm_leak_self_pr() {
  local root=$1 want
  want=$(printf '%s/%s\n' "$2" "$3" | tr '[:upper:]' '[:lower:]')
  fm_leak_repo_identities "$root" | grep -qxF -- "$want"
}

# fm_leak_self_project <fm-root> <project-dir>: 0 when the project is the
# firstmate code root itself, or a clone sharing one of its remotes.
fm_leak_self_project() {
  local root=$1 proj=$2 root_p proj_p ids
  root_p=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  proj_p=$(cd "$proj" 2>/dev/null && pwd -P) || return 1
  [ "$root_p" != "$proj_p" ] || return 0
  ids=$(fm_leak_repo_identities "$root")
  [ -n "$ids" ] || return 1
  fm_leak_repo_identities "$proj" | grep -qxF -f <(printf '%s\n' "$ids")
}

# fm_leak_waiver_valid <reason>: a waiver reason is one non-empty line.
fm_leak_waiver_valid() {
  local reason=${1-}
  [ -n "$(printf '%s' "$reason" | tr -d '[:space:]')" ] || return 1
  case "$reason" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

# fm_leak_waiver_record <meta> <reason>: record the waiver on the task record as
# leak_waiver=<reason>, replacing any earlier one, under the record's lock
# (fm_meta_lock_path and fm_lock_acquire_wait come from bin/fm-wake-lib.sh,
# which every caller already sources).
fm_leak_waiver_record() {
  local meta=$1 reason=$2 lock tmp status=0
  fm_leak_waiver_valid "$reason" || return 1
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "${meta%/*}/.fm-leak-meta.XXXXXX") || status=1
  if [ "$status" -eq 0 ]; then
    { grep -v '^leak_waiver=' "$meta" || true; printf 'leak_waiver=%s\n' "$reason"; } > "$tmp" \
      && chmod 0600 "$tmp" && mv -f -- "$tmp" "$meta" || status=1
    [ "$status" -eq 0 ] || rm -f -- "$tmp"
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}
