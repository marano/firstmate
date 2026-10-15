#!/usr/bin/env bash
# Tests for bin/fm-leak-check.sh and the patterns bin/fm-leak-lib.sh owns: each
# leaked shape is reported wherever it appears in a pull request or a local
# branch - title, body, a commit message alone, an added diff line alone - while
# a clean change, a change that only removes such lines, and an identifier such
# as TEAM_CAPTAIN pass, and the firstmate repository itself is exempt. The
# local-only merge path's refusal and its recorded --allow-leak waiver are
# covered here too; the PR merge path's are in tests/fm-pr-merge.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CHECK="$ROOT/bin/fm-leak-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-leak-check-tests)
JQ_BIN=$(command -v jq) || fail "these tests read forge JSON with the real jq, which was not found"

PR_URL=https://github.com/example/app/pull/5
MR_URL=https://gitlab.example/group/app/-/merge_requests/9
HEAD_SHA=1111111111111111111111111111111111111111

# A forge fixture: gh and glab mocks answering from files in the case dir.
# Every file starts clean; a case overwrites the one it is about.
make_forge_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin" "$dir/home"
  ln -sf "$JQ_BIN" "$dir/fakebin/jq"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
dir=$FM_TEST_FORGE_DIR
case "${1:-} ${2:-}" in
  "pr view") cat "$dir/view.json" ;;
  "pr diff") [ ! -e "$dir/diff-fails" ] || exit 1; cat "$dir/diff" ;;
  "api --paginate")
    case "${3:-}" in
      repos/example/app/pulls/5/commits*|repos/acme/firstmate/pulls/5/commits*) cat "$dir/commits.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
dir=$FM_TEST_FORGE_DIR
[ "${GITLAB_HOST:-}" = gitlab.example ] || exit 1
case "${1:-} ${2:-}" in
  "mr view") cat "$dir/mr.json" ;;
  "api --paginate")
    case "${3:-}" in
      projects/group%2Fapp/merge_requests/9/commits) cat "$dir/mr-commits.json" ;;
      projects/group%2Fapp/merge_requests/9/diffs) cat "$dir/mr-diffs.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/glab"
  printf '{"title":"Add the export button","body":"Adds an export button.\\n\\nTested by hand."}\n' > "$dir/view.json"
  printf '[{"sha":"%s","commit":{"message":"Add the export button\\n\\nWires it to the API."}}]\n' "$HEAD_SHA" > "$dir/commits.json"
  printf '%s\n' 'diff --git a/app.js b/app.js' 'index 1..2 100644' '--- a/app.js' '+++ b/app.js' \
    '@@ -1,2 +1,3 @@' ' const a = 1;' '+const exportButton = true;' ' const b = 2;' > "$dir/diff"
  printf '{"title":"Add the export button","description":"Adds it.","sha":"%s"}\n' "$HEAD_SHA" > "$dir/mr.json"
  printf '[{"id":"%s","message":"Add the export button"}]\n' "$HEAD_SHA" > "$dir/mr-commits.json"
  printf '[{"new_path":"app.js","deleted_file":false,"diff":"@@ -1 +1,2 @@\\n const a = 1;\\n+const exportButton = true;\\n"}]\n' > "$dir/mr-diffs.json"
  printf '%s\n' "$dir"
}

# run_check <dir> <args...>: the checker with the case's mocks, its home, and
# the real code root (whose remotes are not example/app); output to <dir>/out.
run_check() {
  local dir=$1 rc=0
  shift
  PATH="$dir/fakebin:$PATH" FM_TEST_FORGE_DIR="$dir" FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE="${FM_TEST_CODE_ROOT:-$ROOT}" \
    "$CHECK" "$@" > "$dir/out" 2> "$dir/err" || rc=$?
  printf '%s\n' "$rc"
}

test_a_clean_pull_request_passes() {
  local dir rc
  dir=$(make_forge_case clean-pr)
  rc=$(run_check "$dir" pr "$PR_URL" --head "$HEAD_SHA")
  expect_code 0 "$rc" "a clean pull request"
  [ ! -s "$dir/out" ] || fail "a clean pull request reported: $(cat "$dir/out")"
  pass "a clean pull request passes"
}

test_each_leaked_shape_is_reported_where_it_appears() {
  local dir rc
  dir=$(make_forge_case shapes-pr)
  # shellcheck disable=SC2016  # literal JSON, no expansion wanted.
  printf '{"title":"Fix the export the Captain asked for","body":"Context\\n\\nRequest of 2026-10-15: \\"make it faster\\"\\n- Later request of Oct 16: “and smaller”"}\n' > "$dir/view.json"
  rc=$(run_check "$dir" pr "$PR_URL")
  expect_code 1 "$rc" "a leaking title and body"
  assert_grep 'leak: title: the word "captain": Fix the export the Captain asked for' "$dir/out" \
    "the title hit was not named"
  assert_grep 'leak: body line 3: a dated quotation of a request: Request of 2026-10-15: "make it faster"' "$dir/out" \
    "the dated quotation in the body was not named"
  assert_grep 'leak: body line 4: a dated quotation of a request: - Later request of Oct 16: “and smaller”' "$dir/out" \
    "the typographic dated quotation in the body was not named"
  pass "a leaking title and body are reported line by line"
}

test_a_hit_only_in_a_commit_message_is_reported() {
  local dir rc
  dir=$(make_forge_case commit-only)
  printf '[{"sha":"aaaa%s","commit":{"message":"Tidy the module"}},{"sha":"%s","commit":{"message":"Rename the helper\\n\\nAs firstmate decided."}}]\n' \
    "${HEAD_SHA:4}" "$HEAD_SHA" > "$dir/commits.json"
  rc=$(run_check "$dir" pr "$PR_URL" --head "$HEAD_SHA")
  expect_code 1 "$rc" "a leak only in a commit message"
  assert_grep "leak: commit ${HEAD_SHA:0:12} message line 3: \"firstmate\": As firstmate decided." "$dir/out" \
    "the commit message hit was not named with its commit"
  [ "$(wc -l < "$dir/out" | tr -d ' ')" = 1 ] || fail "a commit-only leak reported more: $(cat "$dir/out")"
  pass "a hit only in a commit message is reported"
}

test_a_hit_only_in_an_added_diff_line_is_reported_with_its_file_and_line() {
  local dir rc
  dir=$(make_forge_case diff-only)
  printf '%s\n' 'diff --git a/docs/a.md b/docs/a.md' '--- a/docs/a.md' '+++ b/docs/a.md' \
    '@@ -10,3 +10,4 @@' ' intro' '-old text' '+new text' '+Ask the captain before deploying.' ' outro' \
    'diff --git a/src/b.kt b/src/b.kt' 'new file mode 100644' '--- /dev/null' '+++ b/src/b.kt' \
    '@@ -0,0 +1,2 @@' '+val TEAM_CAPTAIN = 1' "+val dir = \"$dir/home/state\"" > "$dir/diff"
  rc=$(run_check "$dir" pr "$PR_URL")
  expect_code 1 "$rc" "a leak only in an added diff line"
  assert_grep 'leak: docs/a.md:12: the word "captain": Ask the captain before deploying.' "$dir/out" \
    "the added line was not named by file and new line number"
  assert_grep "leak: src/b.kt:2: the firstmate home path: val dir = \"$dir/home/state\"" "$dir/out" \
    "the home path in an added line was not named"
  assert_no_grep 'TEAM_CAPTAIN' "$dir/out" "TEAM_CAPTAIN was reported as the word captain"
  pass "a hit only in an added diff line is reported with its file and line"
}

test_a_pull_request_that_only_removes_leaks_passes() {
  local dir rc
  dir=$(make_forge_case removal-only)
  printf '{"title":"Remove supervision wording from the docs","body":"Removes stray wording."}\n' > "$dir/view.json"
  printf '%s\n' 'diff --git a/docs/a.md b/docs/a.md' '--- a/docs/a.md' '+++ b/docs/a.md' \
    '@@ -1,4 +1,2 @@' ' intro' '-Ask the captain first.' '-Request of 2026-10-15: "keep it"' ' outro' \
    'diff --git a/firstmate.md b/firstmate.md' 'deleted file mode 100644' '--- a/firstmate.md' '+++ /dev/null' \
    '@@ -1 +0,0 @@' '-firstmate notes' > "$dir/diff"
  rc=$(run_check "$dir" pr "$PR_URL")
  expect_code 0 "$rc" "a removal-only pull request"
  [ ! -s "$dir/out" ] || fail "a removal-only pull request reported: $(cat "$dir/out")"
  pass "a pull request that only removes leaked lines passes"
}

test_identifiers_containing_captain_pass() {
  local dir rc
  dir=$(make_forge_case identifiers)
  printf '{"title":"Rename TEAM_CAPTAIN","body":"Uses captainId and TEAM_CAPTAIN only."}\n' > "$dir/view.json"
  printf '%s\n' '--- a/x.ts' '+++ b/x.ts' '@@ -1 +1 @@' '-const a = 1;' '+export const TEAM_CAPTAIN = "captain_role";' > "$dir/diff"
  rc=$(run_check "$dir" pr "$PR_URL")
  expect_code 0 "$rc" "identifiers containing captain"
  pass "TEAM_CAPTAIN and similar identifiers pass"
}

test_the_firstmate_repository_itself_is_exempt() {
  local dir rc root
  dir=$(make_forge_case self-repo)
  root="$dir/code-root"
  fm_git_init_commit "$root"
  git -C "$root" remote add origin git@github.com:Acme/firstmate.git
  printf '{"title":"Teach the captain hold a new reason","body":"firstmate change"}\n' > "$dir/view.json"
  rc=$(FM_TEST_CODE_ROOT="$root" run_check "$dir" pr https://github.com/acme/firstmate/pull/5)
  expect_code 0 "$rc" "a pull request on the firstmate repository"
  assert_grep 'exempt: https://github.com/acme/firstmate/pull/5 is the firstmate repository itself' "$dir/out" \
    "the exemption was not reported"
  # The same text on any other repository is still refused.
  rc=$(FM_TEST_CODE_ROOT="$root" run_check "$dir" pr "$PR_URL")
  expect_code 1 "$rc" "the same pull request text on a project"
  pass "the firstmate repository itself is exempt"
}

test_a_moved_head_or_unreadable_diff_is_not_a_pass() {
  local dir rc
  dir=$(make_forge_case unreadable)
  rc=$(run_check "$dir" pr "$PR_URL" --head 2222222222222222222222222222222222222222)
  expect_code 2 "$rc" "a commit list without the verified head"
  assert_grep 'the head moved' "$dir/err" "a moved head was not named"
  : > "$dir/diff-fails"
  rc=$(run_check "$dir" pr "$PR_URL")
  expect_code 2 "$rc" "an unreadable diff"
  assert_grep "could not read the diff of $PR_URL" "$dir/err" "an unreadable diff was not named"
  pass "a moved head or an unreadable diff is reported, never passed"
}

test_a_gitlab_merge_request_is_checked_the_same_way() {
  local dir rc
  dir=$(make_forge_case gitlab)
  rc=$(run_check "$dir" pr "$MR_URL" --head "$HEAD_SHA")
  expect_code 0 "$rc" "a clean merge request"
  printf '[{"id":"%s","message":"Fix\\n\\nper the captain"}]\n' "$HEAD_SHA" > "$dir/mr-commits.json"
  printf '[{"new_path":"a.md","deleted_file":false,"diff":"@@ -3,2 +3,2 @@\\n keep\\n-old\\n+See firstmate notes\\n"}]\n' > "$dir/mr-diffs.json"
  rc=$(run_check "$dir" pr "$MR_URL" --head "$HEAD_SHA")
  expect_code 1 "$rc" "a leaking merge request"
  assert_grep "leak: commit ${HEAD_SHA:0:12} message line 3: the word \"captain\": per the captain" "$dir/out" \
    "the merge request commit hit was not named"
  assert_grep 'leak: a.md:4: "firstmate": See firstmate notes' "$dir/out" \
    "the merge request diff hit was not named"
  pass "a GitLab merge request is checked the same way"
}

# A local-only task fixture: a project with a default branch and a fm/<id>
# branch carrying one commit, and a home whose task record points at it.
# Args: <name> <commit-message> <file> <content>. Echoes the case dir.
make_local_case() {
  local name=$1 msg=$2 file=$3 content=$4 dir id=task-l1
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  fm_git_init_commit "$dir/project"
  printf 'Ask the captain first.\n' > "$dir/project/old.md"
  git -C "$dir/project" add old.md
  git -C "$dir/project" commit -qm 'add old notes'
  git -C "$dir/project" checkout -q -b "fm/$id"
  if [ "$content" = '<delete>' ]; then
    git -C "$dir/project" rm -q "$file"
  else
    printf '%s\n' "$content" > "$dir/project/$file"
    git -C "$dir/project" add "$file"
  fi
  git -C "$dir/project" commit -qm "$msg"
  git -C "$dir/project" checkout -q main
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$dir/project" \
    "project=$dir/project" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$id"
  printf '%s\n' "$dir"
}

run_merge_local() {  # <dir> [args...]
  local dir=$1 rc=0
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    "$ROOT/bin/fm-merge-local.sh" task-l1 "$@" > "$dir/out" 2> "$dir/err" || rc=$?
  printf '%s\n' "$rc"
}

test_local_branch_leaks_refuse_the_local_merge() {
  local dir rc before
  dir=$(make_local_case local-commit 'Add notes, as the captain asked' notes.md 'Plain notes.')
  before=$(git -C "$dir/project" rev-parse main)
  rc=$(run_merge_local "$dir")
  expect_code 1 "$rc" "a local branch whose commit message leaks"
  assert_grep 'message line 1: the word "captain": Add notes, as the captain asked' "$dir/err" \
    "the local commit message hit was not named"
  assert_grep 'refusing to merge fm/task-l1' "$dir/err" "the local merge refusal was not stated"
  [ "$(git -C "$dir/project" rev-parse main)" = "$before" ] || fail "a leaking local branch was merged"

  dir=$(make_local_case local-diff 'Add notes' notes.md 'Request of 2026-10-15: "ship it"')
  before=$(git -C "$dir/project" rev-parse main)
  rc=$(run_merge_local "$dir")
  expect_code 1 "$rc" "a local branch whose added line leaks"
  assert_grep 'leak: notes.md:1: a dated quotation of a request' "$dir/err" \
    "the local added-line hit was not named"
  [ "$(git -C "$dir/project" rev-parse main)" = "$before" ] || fail "a leaking local diff was merged"
  pass "a leak in a local branch's commit message or added line refuses the local merge"
}

test_a_local_cleanup_merges_and_a_waiver_is_recorded() {
  local dir rc before
  dir=$(make_local_case local-cleanup 'Remove old notes' old.md '<delete>')
  before=$(git -C "$dir/project" rev-parse main)
  rc=$(run_merge_local "$dir")
  expect_code 0 "$rc" "a local branch that only removes a leaked line"
  [ "$(git -C "$dir/project" rev-parse main)" != "$before" ] || fail "the clean local cleanup did not merge"

  dir=$(make_local_case local-waiver 'Add the captain role' roles.md 'The captain role ships here.')
  rc=$(run_merge_local "$dir" --allow-leak $'two\nlines')
  expect_code 2 "$rc" "a multi-line waiver"
  : > "$dir/home/state/.afk-contract"
  rc=$(run_merge_local "$dir" --allow-leak 'the product has a captain role')
  expect_code 2 "$rc" "a waiver while away"
  assert_grep 'attended-only' "$dir/err" "the away refusal of a waiver was not stated"
  rm "$dir/home/state/.afk-contract"
  before=$(git -C "$dir/project" rev-parse main)
  rc=$(run_merge_local "$dir" --allow-leak 'the product has a captain role')
  expect_code 0 "$rc" "an attended waiver"
  [ "$(git -C "$dir/project" rev-parse main)" != "$before" ] || fail "the waived local merge did not land"
  assert_grep 'leak_waiver=the product has a captain role' "$dir/home/state/task-l1.meta" \
    "the waiver reason was not recorded on the task"
  assert_grep 'past the leak check on the recorded --allow-leak reason' "$dir/err" \
    "the waived merge did not say it was waived"
  pass "a local cleanup merges, and a leak merges only on a recorded attended waiver"
}

test_a_local_firstmate_project_is_exempt() {
  local dir rc
  dir=$(make_local_case local-self 'Teach the captain hold' notes.md 'firstmate notes')
  rc=$(FM_TEST_FORGE_DIR="$dir" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/project" \
    "$CHECK" local "$dir/project" main fm/task-l1 > "$dir/out" 2>&1; echo $?)
  expect_code 0 "$rc" "the firstmate code root as a local project"
  assert_grep 'is the firstmate repository itself' "$dir/out" "the local exemption was not reported"
  pass "a local project that is the firstmate repository itself is exempt"
}

test_a_clean_pull_request_passes
test_each_leaked_shape_is_reported_where_it_appears
test_a_hit_only_in_a_commit_message_is_reported
test_a_hit_only_in_an_added_diff_line_is_reported_with_its_file_and_line
test_a_pull_request_that_only_removes_leaks_passes
test_identifiers_containing_captain_pass
test_the_firstmate_repository_itself_is_exempt
test_a_moved_head_or_unreadable_diff_is_not_a_pass
test_a_gitlab_merge_request_is_checked_the_same_way
test_local_branch_leaks_refuse_the_local_merge
test_a_local_cleanup_merges_and_a_waiver_is_recorded
test_a_local_firstmate_project_is_exempt
