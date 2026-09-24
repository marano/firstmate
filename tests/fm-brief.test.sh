#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "{FIRSTMATE_SPEC}" "$brief" "$id: brief missing the {FIRSTMATE_SPEC} placeholder"
    assert_grep "## Captain's intent" "$brief" "$id: brief missing Captain's intent subsection"
    assert_grep "## Firstmate spec" "$brief" "$id: brief missing Firstmate spec subsection"
    assert_grep 'never a bare number such as "PR 108"' "$brief" "$id: brief missing the full-PR-URL rule"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's merge authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# A PR-based ship must not report done on a draft, which cannot be merged; a
# lane that deliberately holds a draft declares a wait instead. local-only opens
# no PR, so it must not carry the requirement.
test_pr_based_dod_requires_non_draft() {
  local home mode id brief
  home="$TMP_ROOT/draft-dod-home"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    id="brief-draft-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode: brief was not scaffolded"
    if [ "$mode" = local-only ]; then
      assert_no_grep "isDraft" "$brief" "$mode: a branch-only delivery must not require a non-draft PR"
      continue
    fi
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'confirm it is not a draft (`gh pr view <url> --json isDraft` must print false)' "$brief" \
      "$mode: done must require reading the PR back from the forge as non-draft"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'mark it ready with `gh-axi pr ready <number> -R <owner>/<repo>`' "$brief" \
      "$mode: a draft must be marked ready before done"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'If you deliberately keep the PR a draft, append `paused: {why the draft is held}` instead of done.' "$brief" \
      "$mode: a deliberate draft must declare a wait instead of done"
  done
  pass "fm-brief.sh: PR-based done requires a non-draft PR; a deliberate draft declares a wait"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief spelling
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  for spelling in 'Captain:' "Captain's words:" "Captain's ask:" "Captain's intent:" 'Captain,'; do
    assert_no_grep "$spelling" "$brief" "rendered intent contract still teaches operator-address labels"
  done
  assert_grep '[captain]' "$brief" "rendered intent contract must explain the neutral legacy provenance marker"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "pass \`--intent\` as only this brief's \`## Captain's intent\`" "$brief" \
    "no-mistakes DOD must require --intent to be the Captain's intent subsection"
  assert_grep "plus any later words the captain actually said" "$brief" \
    "no-mistakes DOD must allow later captain words in --intent"
  assert_grep "Do not include \`## Firstmate spec\`" "$brief" \
    "no-mistakes DOD must keep Firstmate spec out of --intent"
  assert_grep "or your own decisions and tradeoffs" "$brief" \
    "no-mistakes DOD must keep worker tradeoffs out of --intent"
  assert_grep "This replaces the no-mistakes skill's advice to enrich \`--intent\`" "$brief" \
    "no-mistakes DOD must override the external skill's enrich-with-decisions guidance"
  # A bare reference cannot preserve the captain's ask, so the rendered DOD states
  # the self-sufficiency rule and requires referenced material to be resolved into
  # its substance.
  assert_grep "The \`--intent\` string you pass must be self-sufficient" "$brief" \
    "no-mistakes DOD must require a self-sufficient --intent string"
  assert_grep "write the substance of the referenced items into \`--intent\`" "$brief" \
    "no-mistakes DOD must tell the worker to resolve report, decision, and PR references into substance"

  # The --yes ban is a fleet-wide prohibition, not a preference, and it must not
  # claim an enforcement the tool does not provide: this is instruction only.
  assert_grep "NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide." "$brief" \
    "no-mistakes DOD must state the --yes ban as a prohibition"
  assert_grep "answering your own ask-user finding is a hard rule violation" "$brief" \
    "no-mistakes DOD must say why --yes is banned"
  assert_no_grep "Avoid \`--yes\`" "$brief" \
    "no-mistakes DOD still states the --yes ban as a preference"
  assert_no_grep "no-mistakes refuses" "$brief" \
    "no-mistakes DOD must not claim the tool itself refuses --yes"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose and bans --yes outright"
}

# The no-mistakes DOD must tell the worker to drive with --wait and reattach on
# an elapsed wait, never to background the drive call and poll `axi status`
# from a separate call - that shape was measured causing 862 `axi status` calls
# and 177 `gh-axi pr view` calls in one 119-minute run (roughly a third of the
# fleet's two-day token spend). A test that only grepped for a phrase one of
# the fixed sentences happens to contain would pass on either wording, so this
# asserts the new reattach instruction is present AND the old background-and-poll
# instruction is gone.
test_no_mistakes_dod_waits_instead_of_polling() {
  local home id brief
  home="$TMP_ROOT/wait-not-poll-home"
  mkdir -p "$home/data"
  id="brief-wait-not-poll-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_grep 'drive with `no-mistakes axi run --wait` and answer gates with `no-mistakes axi respond --wait`' "$brief" \
    "no-mistakes DOD must instruct driving and responding with --wait"
  assert_grep "An elapsed wait is a normal structured return, not a failure: reattach by issuing the same drive call again." "$brief" \
    "no-mistakes DOD must say an elapsed wait is a normal reattach point, not a failure"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_grep 'Never run a `no-mistakes axi status` loop to watch a run progress' "$brief" \
    "no-mistakes DOD must forbid a status-polling loop"
  assert_grep "a single \`axi status\` call as a diagnostic" "$brief" \
    "no-mistakes DOD must still allow rule 7's single diagnostic axi status call"
  assert_grep "such as Claude Code's \`Monitor\` tool" "$brief" \
    "no-mistakes DOD must mention a native wait-without-model-calls facility as an alternative"
  assert_grep "Any residual sleep-and-recheck fallback must sleep at least 120 seconds inside a single call, never spin." "$brief" \
    "no-mistakes DOD must bound a residual sleep-and-recheck fallback to 120s and forbid spinning"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_grep 'Never poll the PR'"'"'s own check status yourself with `gh-axi`, `gh`, or an equivalent' "$brief" \
    "no-mistakes DOD must forbid polling the PR's own check status"

  assert_no_grep "So background the drive call and poll" "$brief" \
    "no-mistakes DOD must not reintroduce the background-and-poll instruction"
  assert_no_grep "Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape." "$brief" \
    "no-mistakes DOD must not reintroduce the background-and-poll fallback"
  pass "fm-brief.sh: no-mistakes DOD teaches --wait reattach instead of background-and-poll"
}

# The 2026-09-16 "we can add the guards" decision: a worker must paste the
# concrete no-mistakes run id it drove, not just claim a green PR. On
# 2026-09-17 two workers reported `done:` with an implementation commit and no
# run, and both needed a manual correction to go and validate - so the DOD
# text must both require the run id in the done line and say plainly that a
# done line with no run id is not a complete report.
test_no_mistakes_dod_requires_run_id() {
  local home id brief
  home="$TMP_ROOT/requires-run-id-home"
  mkdir -p "$home/data"
  id="brief-requires-run-id-e1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_grep 'append `done: PR {url} checks green run={run-id}` and stop' "$brief" \
    "no-mistakes DOD must require a run id in the done line"
  assert_grep "not evidence about the commit" "$brief" \
    "no-mistakes DOD must state the applied-via-axi-respond learning as the standard"
  assert_grep "a \`done:\` line with no run id is not a complete report, so do not send one" "$brief" \
    "no-mistakes DOD must refuse a done report that carries no run id"

  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_no_grep 'append `done: PR {url} checks green` and stop' "$brief" \
    "no-mistakes DOD must not still render the old run-id-less done line"
  pass "fm-brief.sh: no-mistakes DOD refuses a done report with no validation run id"
}

# A `done:` line is the supervisor's delivery signal, so for a PR-based mode it
# must never be writable without the PR URL that proves delivery. Three workers
# stopped undelivered on 2026-09-20; one of them reported `done:` with no PR
# because the no-mistakes definition of done ITSELF instructed a bare
# `done: {summary}` stop before any pipeline run. Naming the PR in the terminal
# done line could not catch that, because the same block authorized an earlier
# bare one. So the rule is enforced over the rendered artifact rather than
# recommended in it: for no-mistakes and direct-PR, no `done:` template may lack
# a PR URL. local-only is exempt - its `done: ready in branch` line is correct.
test_pr_modes_never_authorize_a_done_without_a_pr_url() {
  local home id mode brief offenders

  # The checker's own contract, driven through its public interface.
  # shellcheck source=bin/fm-dod-lib.sh
  . "$ROOT/bin/fm-dod-lib.sh"

  # MUTANT: the exact pre-fix gate text must be reported for a PR-based mode.
  # shellcheck disable=SC2016  # single quotes are deliberate: the literal braces and backticks are fixture text
  offenders=$(fm_dod_unbound_done_templates no-mistakes \
    'When you believe it is complete, append `done: {summary}` to the status file and stop.') \
    || fail "checker accepted a bare \`done: {summary}\` gate under no-mistakes"
  assert_contains "$offenders" "done: {summary}" \
    "checker did not name the unbound done template it rejected"
  # shellcheck disable=SC2016  # single quotes are deliberate: the literal braces and backticks are fixture text
  fm_dod_unbound_done_templates direct-PR 'append `done: shipped it` and stop' >/dev/null \
    || fail "checker accepted a bare done template under direct-PR"

  # The same text under local-only is correct, not an offence.
  # shellcheck disable=SC2016  # single quotes are deliberate: the literal braces and backticks are fixture text
  fm_dod_unbound_done_templates local-only \
    'append `done: ready in branch fm/x` to the status file' >/dev/null \
    && fail "checker reported an offence for local-only, which has no PR to name"

  # A PR-bound template and a bare `done:` reference are both legitimate.
  # shellcheck disable=SC2016  # single quotes are deliberate: the literal braces and backticks are fixture text
  fm_dod_unbound_done_templates no-mistakes \
    'append `done: PR {url} checks green run={run-id}` and stop' >/dev/null \
    && fail "checker rejected a done template that does carry the PR URL"
  # shellcheck disable=SC2016  # single quotes are deliberate: the literal braces and backticks are fixture text
  fm_dod_unbound_done_templates no-mistakes \
    'reports `done: PR <url> checks green run=<run-id>` after CI is green' >/dev/null \
    && fail "checker rejected the <url> placeholder spelling AGENTS.md section 7 uses"
  # shellcheck disable=SC2016  # single quotes are deliberate: the literal braces and backticks are fixture text
  fm_dod_unbound_done_templates direct-PR \
    'append `done: PR https://example.test/pull/1` and stop' >/dev/null \
    && fail "checker rejected a done template carrying a literal https PR URL"
  # shellcheck disable=SC2016  # single quotes are deliberate: the literal braces and backticks are fixture text
  fm_dod_unbound_done_templates no-mistakes \
    'a `done:` line with no run id is not a complete report' >/dev/null \
    && fail "checker treated a bare \`done:\` reference as an authorized template"

  # And the real generated briefs are clean under it.
  home="$TMP_ROOT/pr-bound-done-home"
  mkdir -p "$home/data"
  for id_mode in "brief-prbound-f1:no-mistakes" "brief-prbound-f2:direct-PR" "brief-prbound-f3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$id: --mode $mode brief should scaffold"
    brief="$home/data/$id/brief.md"
    offenders=$(fm_dod_unbound_done_templates "$mode" "$(cat "$brief")") \
      && fail "$id: mode=$mode brief authorizes a done line with no PR URL: $offenders"
  done

  # The no-mistakes brief must carry the handoff that replaced the bare gate,
  # and must no longer carry the gate itself.
  brief="$home/data/brief-prbound-f1/brief.md"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_no_grep 'append `done: {summary}`' "$brief" \
    "no-mistakes brief still instructs a bare done gate before the pipeline"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks are fixture text
  assert_grep '`blocked: implementation committed <sha>, needs the instruction to run /no-mistakes`' "$brief" \
    "no-mistakes brief lost the handoff line that replaced the bare done gate"
  assert_grep "asks firstmate to act and is not a completion" "$brief" \
    "no-mistakes brief does not say the handoff line is not a completion"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "no-mistakes brief lost the sentence naming who clears the handoff"
  assert_grep "never the validation this contract requires, and never a substitute for the PR" "$brief" \
    "no-mistakes brief does not say the project's own gate is not the delivery pipeline"
  pass "fm-brief.sh: no PR-based brief can authorize a done line without a PR URL"
}

# The guard must refuse at generation time, not merely be available. MUTANT:
# reintroduce the bare `done: {summary}` gate into a copy of the definition-of-done
# library and run the real generator against it - brief generation must fail and
# leave no brief behind, so the defect cannot reach a worker.
test_reintroduced_bare_done_gate_refuses_brief_generation() {
  local sandbox out status
  sandbox="$TMP_ROOT/bare-done-mutant"
  mkdir -p "$sandbox/home/data"
  cp -R "$ROOT/bin" "$sandbox/bin"
  # Rewrite the handoff line back into the pre-fix bare done gate.
  awk '
    {
      if (index($0, "needs the instruction to run /no-mistakes\\`") > 0 && index($0, "append") > 0) {
        print "When you believe it is complete, append \\`done: {summary}\\` to the status file and stop."
        mutated = 1
        next
      }
      print
    }
    END { exit !mutated }
  ' "$ROOT/bin/fm-dod-lib.sh" > "$sandbox/bin/fm-dod-lib.sh" \
    || fail "mutation found no handoff line to rewrite - the fixture no longer matches the source"

  out=$(FM_HOME="$sandbox/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$sandbox/bin/fm-brief.sh" brief-mutant-g1 some-proj --mode no-mistakes 2>&1)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reintroduced bare done gate still generated a no-mistakes brief"
  assert_contains "$out" "must never authorize a done line with no PR URL" \
    "refusal did not explain which contract the rendered brief broke"
  assert_contains "$out" "done: {summary}" \
    "refusal did not name the offending done template"
  assert_absent "$sandbox/home/data/brief-mutant-g1/brief.md" \
    "refused generation still left a brief carrying the bare done gate"

  # The same mutation under local-only stays legal, so the guard is mode-specific
  # rather than a blanket ban on a done line with no PR.
  FM_HOME="$sandbox/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$sandbox/bin/fm-brief.sh" brief-mutant-g2 some-proj --mode local-only >/dev/null 2>&1 \
    || fail "the PR-bound done guard wrongly refused a local-only brief"
  pass "fm-brief.sh: reintroducing a bare done gate refuses brief generation"
}

# Two of the three 2026-09-20 stops were `working:` lines whose last clause
# promised the next action ("taking it through no-mistakes now", "handing the CI
# gate back"), written and then not performed. The nonterminal-working rule has
# shipped since #758 and did not hold, because it fires at turn end - a moment a
# worker completing a narration has already passed. MUTANT: delete either
# sentence below and this reds. The rule is restated at composition time, about
# the text being written, and pinned to the exact transition that stalled.
test_ship_status_protocol_forbids_announcing_an_unperformed_action() {
  local home id brief
  home="$TMP_ROOT/past-tense-home"
  mkdir -p "$home/data"
  id="brief-past-tense-h1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  assert_grep "Report in the past tense, about what has already happened." "$brief" \
    "ship status protocol lost the past-tense reporting rule"
  assert_grep "announces an action you have not performed yet" "$brief" \
    "ship status protocol does not forbid announcing an unperformed action"
  assert_grep "Perform the" "$brief" \
    "ship status protocol does not require the action before the report"
  # The nonterminal rule stays: the new rule is additional, not a replacement.
  assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
    "the past-tense rule replaced the nonterminal-working rule instead of joining it"

  # And the exact transition all three stops shared is pinned in the pipeline
  # contract, so "starting no-mistakes now" has a defined right moment.
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_grep 'Do not announce the pipeline and stop' "$brief" \
    "no-mistakes DOD does not forbid announcing the run and stopping"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks must stay literal
  assert_grep 'is written after your first `no-mistakes axi run --wait` call returns' "$brief" \
    "no-mistakes DOD does not say when the run-started line may be written"
  pass "fm-brief.sh: ship status protocol forbids reporting an action before performing it"
}

test_ask_user_escalation_format() {
  local home id brief mode other_id other_brief
  home="$TMP_ROOT/ask-user-home"
  mkdir -p "$home/data"
  id="brief-ask-user-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"

  # A no-mistakes ask-user gate must escalate its ask-user findings as one status
  # event plus one verbatim findings snapshot file, using that same shape even
  # for a single finding, never paraphrased into the status line.
  assert_grep "escalate all ask-user findings as one event plus one snapshot file" "$brief" \
    "ship rule 6 lost the one-event-plus-snapshot-file ask-user contract"
  assert_grep "using that same shape even when the gate holds only a single ask-user finding" "$brief" \
    "ship rule 6 must require the same shape for a single finding"
  assert_grep "write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority)" "$brief" \
    "ship rule 6 must limit the verbatim axi slice to ask-user findings"
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks and the key/findings/file tokens must stay literal
  assert_grep 'needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='"$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must render the exact needs-decision ask-user status line"
  assert_grep "$home/data/$id/nm-<run>-findings.txt" "$brief" \
    "ship rule 6 must point the snapshot file under this task's own data directory"
  assert_grep "The status line only points at the file; it never restates or summarizes a finding's content." "$brief" \
    "ship rule 6 must forbid paraphrasing ask-user findings into the status line"

  # The DOD's own ask-user paragraph must point back at rule 6's format
  # (one-owner rule) rather than restating or bare-citing it.
  assert_grep "escalate to firstmate using rule 6's ask-user format" "$brief" \
    "no-mistakes DOD ask-user paragraph must point at rule 6's format instead of a bare citation"
  assert_no_grep "escalate to firstmate (rule 6) and stop." "$brief" \
    "no-mistakes DOD ask-user paragraph still uses the old bare rule-6 pointer"

  other_id="brief-no-ask-user-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --scout >/dev/null 2>&1
  other_brief="$home/data/$other_id/brief.md"
  assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
    "scout brief received a no-mistakes-only decision case"

  for mode in direct-PR local-only; do
    other_id="brief-no-ask-user-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$other_id" some-proj --mode "$mode" >/dev/null 2>&1
    other_brief="$home/data/$other_id/brief.md"
    assert_no_grep "nm-<run>-findings.txt" "$other_brief" \
      "$mode brief received a no-mistakes-only escalation format"
    assert_no_grep "destructive actions, ask-user findings" "$other_brief" \
      "$mode brief received a no-mistakes-only decision case"
  done

  pass "fm-brief.sh: no-mistakes ask-user findings use one event plus a verbatim snapshot"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "follow \`$ROOT/bin/fm-ensure-agents-md.sh\`'s self-governance contract" "$brief" \
    "project-memory contract no longer defers to the ensure helper"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# Regression (issue #2575): AGENTS.md section 11 and this script's own help tell
# firstmate to fill `{TASK}` and `{FIRSTMATE_SPEC}`. The unguarded Herdr gate used
# to quote `{TASK}` in its own prose, so that documented global replace spliced
# the whole task body into the middle of the gate's sentence - silently
# destroying the one contract that exists precisely because the scaffold cannot
# see the task text. Each placeholder must exist only at its genuine fill site,
# so the documented fill leaves the gate intact and each body appears once.
test_documented_global_replace_leaves_the_herdr_gate_intact() {
  local home id brief kind count content filled body spec
  home="$TMP_ROOT/task-fill-site-home"
  mkdir -p "$home/data"
  body='Restart the herdr session, then profile it'
  spec='Use the isolated lab helper for every lifecycle call'
  for kind in ship scout; do
    id="brief-fill-site-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind brief was not scaffolded"
    count=$(grep -c -F '{TASK}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {TASK} fill site, found $count"
    count=$(grep -c -F '{FIRSTMATE_SPEC}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {FIRSTMATE_SPEC} fill site, found $count"
    content=$(cat "$brief")
    filled=${content//'{TASK}'/$body}
    filled=${filled//'{FIRSTMATE_SPEC}'/$spec}
    count=$(printf '%s\n' "$filled" | grep -c -F "$body")
    [ "$count" = 1 ] \
      || fail "$kind brief: the documented {TASK} replace duplicated the intent body $count times"
    count=$(printf '%s\n' "$filled" | grep -c -F "$spec")
    [ "$count" = 1 ] \
      || fail "$kind brief: the {FIRSTMATE_SPEC} replace duplicated the spec body $count times"
    printf '%s\n' "$filled" | grep -qF 'this scaffold cannot inspect the task text' \
      || fail "$kind brief: the Herdr safety gate did not survive the documented fill"
  done
  pass "fm-brief.sh: the documented {TASK} and {FIRSTMATE_SPEC} fills cannot corrupt the Herdr safety gate"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep '# The captain and the parent channel' "$brief" \
    "secondmate charter lost the parent-channel section"
  assert_grep 'Nobody reads this chat' "$brief" \
    "secondmate charter no longer says the chat is unread"
  assert_grep 'in this home it IS the captain' "$brief" \
    "secondmate charter no longer names the parent channel as the captain"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'bin/fm-secondmate-report.sh <verb> <corr_id> <note>' "$brief" \
    "secondmate charter lost the mechanical helper invocation"
  assert_grep 'do not pass a status path' "$brief" \
    "secondmate charter still tells the mate to pass a hand path to the helper"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, work ready for review, or work you landed' "$brief" \
    "secondmate charter lost decisions, blockers, failures, ready outcomes, or landed work"
  # Under standing merge authority nothing is ever "ready for review", so the
  # landed merge is the trigger a charter without this line silently omits.
  assert_grep 'a merge you performed yourself under standing merge authority and one the captain merged on the forge' "$brief" \
    "secondmate charter did not name a landed merge as a reporting trigger"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep '`awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

# Rule 4's pause contract must reach a worker as an obligation fired at the
# moment it goes quiet, not as a definition of when the verb is permitted.
# Stating it as a definition ("use `paused:` ONLY when you are deliberately
# idling on a known external wait") left five healthy workers undeclared in one
# night - waiting on the shared build lock, a test re-run, a background test
# run, and their own pipeline - because a worker reads that form as a
# restriction on a report it was separately told to make sparingly, and reads a
# job it launched itself as neither "external" nor "idling".
#
# So this pins the three properties that make a worker act rather than classify:
# a self-launched job is named in-category, the append is ordered ahead of going
# quiet, and the wait is closed when it reports. It also pins the `blocked:`
# escape alongside them, because one of those five alerts was a real starvation
# condition and nothing here may make a genuine blocker less likely to be raised.
test_ship_and_scout_oblige_declaring_a_self_launched_wait() {
  local home kind id brief rule4
  home="$TMP_ROOT/self-launched-wait-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    id="brief-self-launched-wait-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
        "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
        "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    # Scope every assertion to the rendered status protocol: the obligation only
    # works where the worker meets the reporting rule, so a stray mention of a
    # background job elsewhere in the brief must not satisfy this test.
    rule4="$TMP_ROOT/$id.rule4"
    awk '/^4\. Report status/ { inside = 1 } /^5\. / { inside = 0 } inside' "$brief" > "$rule4"
    [ -s "$rule4" ] || fail "$kind brief has no rule 4 status protocol to carry the pause obligation"

    # A job the worker launched itself must be inside the category, and must not
    # depend on the worker reading to the end of a list of outside-world waits.
    assert_grep "A job you launched yourself counts" "$rule4" \
      "$kind rule 4 no longer puts a self-launched job inside the declared-wait category"
    assert_grep "your own validation round" "$rule4" \
      "$kind rule 4 no longer names the validation round as a wait to declare"
    assert_grep "a test or build run" "$rule4" \
      "$kind rule 4 no longer names a background test or build run as a wait to declare"

    # The report must be ordered ahead of going quiet. A permissive definition of
    # the verb satisfies neither of these.
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    grep -Eq 'Append `awaiting: \{why\}` BEFORE you stop' "$rule4" \
      || fail "$kind rule 4 no longer orders the pause append ahead of the worker going quiet"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'then `working:` or `done:` once it reports' "$rule4" \
      "$kind rule 4 no longer closes the declared wait when the job reports back"
    assert_no_grep "ONLY when you are deliberately idling" "$rule4" \
      "$kind rule 4 reverted to defining when the pause verb is permitted"

    # Declaring a wait must never become the quiet alternative to escalating.
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'use `blocked:` when you are stuck and need help' "$rule4" \
      "$kind rule 4 lost the blocked escape beside the pause obligation"
    assert_grep "never downgrade a real blocker" "$rule4" \
      "$kind rule 4 no longer forbids downgrading a real blocker to a declared wait"
  done
  pass "fm-brief.sh: ship and scout scaffolds oblige declaring a self-launched wait"
}

test_ship_and_scout_teach_reading_stored_text_as_data() {
  local home kind id brief
  home="$TMP_ROOT/stored-text-as-data-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    id="brief-stored-text-as-data-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "gh api repos/<owner>/<repo>/pulls/<n> --template '{{.body}}'" "$brief" \
      "$kind brief did not tell workers how to read a PR body back as data"
    assert_grep 'gh-axi has no data mode for a stored body' "$brief" \
      "$kind brief did not name the data read as the explicit exception to the gh-axi rule"
    assert_grep "pr view --full" "$brief" \
      "$kind brief did not name pr view --full as rendered text"
    assert_grep "pr list --fields body" "$brief" \
      "$kind brief did not name pr list --fields body as rendered text"
    assert_grep "never a source to recover a body from by unescaping it" "$brief" \
      "$kind brief did not forbid recovering a body by unescaping rendered output"
  done
  pass "fm-brief.sh: ship and scout scaffolds teach reading stored text as data"
}

# A worker that tried to prepend its findings to its own pull request body was
# refused with "lacks permission for UpdatePullRequest" and stopped, reading it
# as an account limit; the findings reached a file nobody reads. The account
# was never the problem - gh resolves an unnamed call from the checkout's git
# remotes, and this fleet's own checkout also carries an `upstream`, so the
# edit reached a repository the account cannot write. The scaffold is the only
# firstmate instruction surface a project worker reads, so it has to carry both
# the repository-naming rule and what that refusal actually means, or the next
# worker draws the same reasonable conclusion.
# tests/fm-pr-body-write-live-e2e.test.sh proves the route this rule names
# still works against a real repository.
test_ship_and_scout_name_the_repository_on_github_calls() {
  local home kind id brief
  home="$TMP_ROOT/github-repo-scope-home"
  mkdir -p "$home/data"

  for kind in ship scout; do
    id="brief-github-repo-scope-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep 'Name the repository on EVERY GitHub call' "$brief" \
      "$kind brief did not require naming the repository on GitHub calls"
    assert_grep 'resolves the repository' "$brief" \
      "$kind brief did not explain that an unnamed call resolves from the checkout's remotes"
    assert_grep 'lacks permission for UpdatePullRequest' "$brief" \
      "$kind brief did not name the refusal a worker will actually see"
    assert_grep 'NOT that your account lacks the right' "$brief" \
      "$kind brief did not correct the reading that stops a worker"
    assert_grep 'gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -F body=@<file>' "$brief" \
      "$kind brief did not give workers a route that writes a PR body"
  done
  pass "fm-brief.sh: ship and scout scaffolds name the repository and the write route"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`captain-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared captain-call policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# A scout brief offers the Lavish review loop only when bootstrap confirms the
# supported lavish-axi floor at scaffold time; a missing or older build gets a
# text-report instruction instead, so a scout never drives a below-floor Lavish.
test_scout_lavish_line_follows_presentation_floor() {
  local base label version expect case_dir fakebin brief n=0
  local hosting='you may host the Lavish review loop yourself'
  local text_only='deliver your findings as a text report without Lavish'
  base=$(fm_test_base_path_sans "${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" lavish-axi)
  while IFS='^' read -r label version expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/scout-lavish-$n"
    mkdir -p "$case_dir/home/data"
    fakebin=$(fm_fakebin "$case_dir")
    [ "$version" = absent ] || fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION "$version"
    PATH="$fakebin:$base" FM_HOME="$case_dir/home" \
      "$ROOT/bin/fm-brief.sh" scout-lavish alpha --scout >/dev/null \
      || fail "$label: scout scaffold failed"
    brief="$case_dir/home/data/scout-lavish/brief.md"
    if [ "$expect" = hosting ]; then
      assert_grep "$hosting" "$brief" "$label: scout brief did not offer the Lavish review loop"
      assert_no_grep "$text_only" "$brief" "$label: scout brief withheld Lavish from a compatible build"
    else
      assert_grep "$text_only" "$brief" "$label: scout brief did not ask for a text report"
      assert_no_grep "$hosting" "$brief" "$label: scout brief offered a below-floor Lavish"
    fi
  done <<'ROWS'
lavish-axi at the floor^0.1.46^hosting
lavish-axi above the floor^0.2.0^hosting
lavish-axi just below the floor^0.1.45^text
absent lavish-axi^absent^text
ROWS
  pass "fm-brief.sh: scout Lavish hosting follows the bootstrap lavish-axi floor"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "## Captain's intent" "$brief" "scout brief missing Captain's intent subsection"
  assert_grep "## Firstmate spec" "$brief" "scout brief missing Firstmate spec subsection"
  assert_grep "{FIRSTMATE_SPEC}" "$brief" "scout brief missing the spec placeholder"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  assert_no_grep "## Captain's intent" "$brief" \
    "secondmate charter must not grow ship/scout Task subsections"
  assert_no_grep "{FIRSTMATE_SPEC}" "$brief" \
    "secondmate charter must not carry the Firstmate spec placeholder"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_worker_role_scope() {
  local kind home brief
  home="$TMP_ROOT/worker-role"
  for kind in no-mistakes direct-PR local-only scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" arbitrary-project-name --scout >/dev/null || fail "scout scaffold failed"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" arbitrary-project-name --mode "$kind" >/dev/null || fail "$kind scaffold failed"
    fi
    brief="$home/data/$kind/brief.md"
    assert_no_grep '# Current worker role contract' "$brief" "$kind scaffolded a second owner of the role scope fm-spawn.sh delivers"
  done
  FM_HOME="$home" FM_SECONDMATE_CHARTER='Supervise assigned work.' \
    "$ROOT/bin/fm-brief.sh" supervisor --secondmate --no-projects >/dev/null || fail "secondmate scaffold failed"
  brief="$home/data/supervisor/brief.md"
  assert_no_grep '# Current worker role contract' "$brief" "secondmate received the worker exception"
  assert_no_grep 'do not adopt the supervisor identity' "$brief" "secondmate received the worker exception"
  assert_grep "The local \`AGENTS.md\` is your job description" "$brief" "secondmate lost its supervisor contract"
  assert_grep 'That file is your parent channel' "$brief" "secondmate lost its parent channel"
  pass "fm-brief: scaffolds leave the worker role scope to the launch boundary and keep the secondmate contract"
}

test_ship_and_scout_teach_the_build_mutex() {
  local home kind mode id brief
  home="$TMP_ROOT/build-mutex-home"
  mkdir -p "$home/data"

  # Every ship mode and the scout scaffold, because a project worker reads no
  # other firstmate instruction surface: AGENTS.md is the supervisor contract and
  # firstmate-coding-guidelines only reaches a firstmate-repo task.
  for kind in no-mistakes direct-PR local-only scout; do
    id="brief-build-mutex-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" bluejam-platform --scout >/dev/null 2>&1
    else
      mode=$kind
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" bluejam-platform --mode "$mode" >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep 'a full CI script - prefixed with' "$brief" \
      "$kind brief did not tell workers to prefix heavy commands with mutex"
    assert_grep 'lint, test, build, codegen, an e2e' "$brief" \
      "$kind brief did not name the commands the rule covers"
    assert_grep 'mutex pnpm run ci' "$brief" \
      "$kind brief did not show a concrete wrapped invocation"
    # Mutant: drop the "Never split one run" line.
    assert_grep 'Never split one run into per-test, per-file or per-module invocations' "$brief" \
      "$kind brief did not say the mutex wraps a whole run rather than each unit inside it"
    # Mutant: drop the network-bound sentence - workers then read long-running as heavy.
    assert_grep 'a command that is slow because it waits on a network or an external API does not take the' "$brief" \
      "$kind brief did not say a network-bound command stays out of the lock however long it runs"
    assert_grep 'terraform plan' "$brief" \
      "$kind brief did not give terraform plan as the network-bound example"
    # Mutant: drop the "Never put one mutex around a loop" line - every measured
    # hold over ten minutes was one mutex around a loop of separate runs.
    assert_grep "Never put one \`mutex\` around a loop, script or \`&&\` chain of several runs" "$brief" \
      "$kind brief did not forbid one mutex around a loop of separate runs"
    assert_grep 'wrap each run in the loop instead' "$brief" \
      "$kind brief did not say to wrap each run of a loop separately"
    # A worker obeying "a full CI script" above wrapped bin/fm-test-run.sh, whose
    # own per-script holds then became no-ops inside that outer hold - a measured
    # 20-minute whole-lane hold. The rule has to name that case, or the positive
    # list above reads as covering it.
    # Mutant: drop the "takes the lock per unit itself" line.
    assert_grep 'A script that takes the lock per unit itself is the one thing never to wrap' "$brief" \
      "$kind brief did not name a self-locking runner as the one command never to wrap"
    # Mutant: drop the "never run the command without mutex" line.
    assert_grep "never run the command without \`mutex\` to get out of the line" "$brief" \
      "$kind brief did not forbid leaving the line by running unlocked"
    assert_grep 'stands down by itself on CI' "$brief" \
      "$kind brief did not say the mutex stands down on CI without the worker reasoning about it"
    assert_grep 'bin/fm-build-lock.sh' "$brief" \
      "$kind brief did not point at the contract owner for the mutex"
  done

  # A secondmate supervises; it does not run a project's builds, so the rule
  # must not leak into the charter.
  id='brief-build-mutex-secondmate'
  FM_SECONDMATE_CHARTER='Own one domain.' FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  ! grep -q 'a full CI script - prefixed with' "$brief" \
    || fail "secondmate charter carried the worker build-mutex rule"

  pass "fm-brief.sh: every ship mode and the scout scaffold teach the machine-wide build mutex"
}

test_worker_role_scope
test_script_parses
test_ship_and_scout_teach_the_build_mutex
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_pr_based_dod_requires_non_draft
test_no_mistakes_dod_waits_instead_of_polling
test_no_mistakes_dod_requires_run_id
test_pr_modes_never_authorize_a_done_without_a_pr_url
test_reintroduced_bare_done_gate_refuses_brief_generation
test_ship_status_protocol_forbids_announcing_an_unperformed_action
test_ask_user_escalation_format
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_documented_global_replace_leaves_the_herdr_gate_intact
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_ship_and_scout_oblige_declaring_a_self_launched_wait
test_ship_and_scout_teach_reading_stored_text_as_data
test_ship_and_scout_name_the_repository_on_github_calls
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_scout_lavish_line_follows_presentation_floor
