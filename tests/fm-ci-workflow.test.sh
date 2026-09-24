#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# The four jobs the incident found unbounded, at the report's recommended caps.
test_previously_unbounded_jobs_keep_their_caps() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
lint 25
test-coverage 5
tests-timing-aggregate 5
invariants 5
CAPS
  pass "the incident's unbounded jobs keep their recommended caps"
}

# Cancellation makes an undersized cap costlier: a falsely tripped job now also
# discards a run nobody replaced. These bounds were measured, not guessed.
test_measured_lanes_keep_their_existing_bounds() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
tests-portable-parallel-1 10
tests-portable-parallel-2 10
tests-portable-parallel-3 10
tests-portable-serial 30
tests-herdr 75
macos-stock-bash 40
CAPS
  pass "the already-measured lane bounds are unchanged"
}

# The stock-bash job must run the shared lane owner rather than a second copy of
# its body, or a local run before push stops mirroring what CI executes.
test_stock_bash_job_runs_the_shared_lane_owner() {
  local reported
  reported=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("macos-stock-bash").fetch("steps")
runs = steps.map { |step| step["run"].to_s }
# An inspection call (--required-tools, --list) asks the owner a question; only
# a call that RUNS the lane counts against the one-execution rule.
owner = runs.select { |run| run.lines.any? { |line|
  command = line.strip
  command.start_with?("bin/fm-stock-bash-lane.sh") && command !~ /--required-tools|--list\b/
} }
puts "the job runs bin/fm-stock-bash-lane.sh #{owner.size} times, want 1" unless owner.size == 1
runs.each do |run|
  run.lines.each do |line|
    command = line.strip
    next if command.start_with?("#")
    puts "a step runs lane work outside the owner: #{command}" if command =~ /fm-test-run\.sh|bash -n|FM_TEST_ONLY=/
  end
end
' "$CI_WORKFLOW") || fail "could not read the macos-stock-bash job from ci.yml"
  [ -z "$reported" ] || fail "the stock-bash job does not run the shared lane owner:"$'\n'"$reported"
  pass "the stock-bash CI job runs the shared lane owner and nothing else of the lane"
}

# A failed Lint job must end its log with the repair note, because that tail is
# what a CI-repair agent reads; it must not print when an install step failed.
test_failed_lint_ends_with_the_repair_note() {
  local reported
  reported=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("lint").fetch("steps")
lint = steps.index { |step| step["run"].to_s.strip =~ /\Abin\/fm-lint\.sh(\s|\z)/ }
note = steps.index { |step| step["run"].to_s.strip == "bin/fm-lint-repair-note.sh" }
if lint.nil? || note.nil?
  puts "lint step #{lint.inspect}, note step #{note.inspect}"
  exit
end
id = steps[lint]["id"].to_s
condition = steps[note]["if"].to_s.gsub(/\s+/, " ")
puts "note must be the last step after the lint step" unless note == steps.size - 1 && note > lint
puts "lint step needs an id the note can test" if id.empty?
puts "note must print only when the lint step failed, got if: #{condition}" unless
  condition.include?("failure()") && condition.include?("steps.#{id}.outcome == \x27failure\x27")
' "$CI_WORKFLOW") || fail "could not read the lint job from ci.yml"
  [ -z "$reported" ] || fail "a failed Lint job does not end with the repair note:"$'\n'"$reported"
  pass "a failed Lint job ends its log with the repair note, and only when the lint failed"
}


# --- pinned linter installs -------------------------------------------------
#
# Every lane job used to install both pinned linters unconditionally, so an
# outage on either release reddened lanes that never invoke it: on 2026-09-21
# that cost six jobs across two main runs, five of them in lanes holding no test
# that calls the tool whose download failed. The fix is not a per-job tool
# matrix in ci.yml - that shape is what rotted into four of the same six reds -
# but a per-job install set DERIVED from lane membership, so these cases check
# the derivation is really what the workflow runs and that it still covers every
# test that needs a tool.

# The lanes the workflow itself installs tools for, one per line, resolved from
# the install steps rather than from a list kept here. A shard matrix names its
# lane through one step variable, so that variable is resolved against the
# job's matrix exactly as GitHub would resolve it, giving one lane per shard.
# A job that installs tools without naming a lane - the stock-Bash job asks its
# own lane owner - contributes nothing here and is checked separately.
# \x24 is a literal dollar sign, kept out of this single-quoted program for the
# same reason the concurrency resolver above keeps its quotes out of it.
workflow_install_lanes() {
  ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |_name, job|
  shards = ((job["strategy"] || {})["matrix"] || {})["shard"]
  (job["steps"] || []).each do |step|
    body = step["run"].to_s
    next unless body.include?("bin/fm-install-pinned-tools.sh")
    named = body.match(/--lane\s+"?([^"\s|]+)"?/)
    next if named.nil?
    token = named[1]
    unless token.start_with?("\x24")
      puts token
      next
    end
    spelled = (step["env"] || {})[token.delete("\x24{}")]
    raise "no step env resolves #{token}" if spelled.nil?
    (shards || [nil]).each do |shard|
      puts spelled
        .gsub("\x24{{ matrix.shard }}", shard.to_s)
        .gsub("\x24{{ strategy.job-total }}", (shards || []).size.to_s)
    end
  end
end
' "$CI_WORKFLOW" | LC_ALL=C sort -u
}

test_only_the_lint_job_names_a_linter_installer() {
  local reported
  reported=$(ruby -ryaml -e '
installers = ["bin/fm-install-shellcheck.sh", "bin/fm-install-actionlint.sh"]
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  body = (job["steps"] || []).map { |step| step["run"].to_s }.join("\n")
  named = installers.select { |installer| body.include?(installer) }
  if name == "lint"
    puts "the Lint job must install both pinned linters itself, found #{named.size}" unless named.size == 2
    next
  end
  next if named.empty?
  puts "#{name} names a pinned linter installer directly: #{named.join(", ")}"
end
' "$CI_WORKFLOW") || fail "could not read the jobs from ci.yml"
  [ -z "$reported" ] || fail "a job outside Lint hard-codes which pinned linters it installs:"$'\n'"$reported"
  pass "no lane job names a pinned linter installer, so no per-job tool matrix can rot here"
}

test_every_lane_job_derives_its_tools_from_its_own_lane() {
  local reported
  reported=$(ruby -ryaml -e '
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
jobs.each do |name, job|
  runs = (job["steps"] || []).map { |step| step["run"].to_s }
  suite = runs.select { |run| run =~ /fm-test-run\.sh .*--lane|fm-stock-bash-lane\.sh/ }
  installs = runs.select { |run| run.include?("bin/fm-install-pinned-tools.sh") }
  next if suite.empty? && installs.empty?
  if suite.empty?
    puts "#{name} installs pinned tools but runs no lane"
    next
  end
  unless installs.size == 1
    puts "#{name} must install its pinned tools in exactly one derived step, found #{installs.size}"
    next
  end
  install = installs.first
  unless install =~ /--list-required-tools|--required-tools/
    puts "#{name} installs tools without asking what its lane needs: #{install.gsub(/\s+/, " ").strip}"
  end
  # Compare the lane token as spelled, shell expansion and all: the serial
  # shards name theirs through one variable, so equality is what matters.
  lanes = (suite + [install]).flat_map { |run| run.scan(/--lane\s+(\S+)/) }
  lanes = lanes.flatten.map { |lane| lane.delete("\x22\x27") }.reject(&:empty?).uniq
  if lanes.size > 1
    puts "#{name} installs for a different lane than it runs: #{lanes.join(" vs ")}"
  end
end
' "$CI_WORKFLOW") || fail "could not read the lane jobs from ci.yml"
  [ -z "$reported" ] || fail "a lane job does not derive its pinned tools from its own lane:"$'\n'"$reported"
  pass "every lane job derives its pinned tools from the lane it runs, in one step"
}

# The whole point of the change: the tools ARE still installed wherever a test
# needs one. Proven against the runner's own answer rather than against the
# workflow text, so moving a test between lanes moves its tool with it.
test_installed_tools_cover_every_test_that_needs_one() {
  local needed lane covered missing
  needed=$("$ROOT/bin/fm-test-run.sh" --list-required-tools --all --include-excluded) \
    || fail "could not ask bin/fm-test-run.sh what the whole suite needs"
  [ -n "$needed" ] || fail "no test requires a pinned tool, so this case proves nothing"
  covered=$(
    while IFS= read -r lane; do
      [ -n "$lane" ] || continue
      "$ROOT/bin/fm-test-run.sh" --list-required-tools --lane "$lane" || exit 1
    done < <(workflow_install_lanes)
    "$ROOT/bin/fm-stock-bash-lane.sh" --required-tools || exit 1
  ) || fail "could not derive the tools ci.yml's lanes install"
  covered=$(printf '%s\n' "$covered" | LC_ALL=C sort -u)
  missing=$(comm -23 <(printf '%s\n' "$needed") <(printf '%s\n' "$covered"))
  [ -z "$missing" ] || fail "tests need pinned tools no CI lane installs:"$'\n'"$missing"
  pass "every pinned tool a test needs is installed by the lane that runs it"
}

# ...and the blast radius really is narrower than it was. Installing every tool
# in every lane would satisfy the coverage case above while restoring exactly
# the failure this change exists to remove, so pin the count too.
test_no_lane_installs_a_tool_its_tests_never_invoke() {
  local lanes lane tools tool_count lane_count pair_count
  lanes=$(workflow_install_lanes)
  [ -n "$lanes" ] || fail "ci.yml installs pinned tools for no lane at all"
  tool_count=$("$ROOT/bin/fm-install-pinned-tools.sh" --list | grep -c .)
  lane_count=$(printf '%s\n' "$lanes" | grep -c .)
  pair_count=0
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    tools=$("$ROOT/bin/fm-test-run.sh" --list-required-tools --lane "$lane" | grep -c . || true)
    pair_count=$((pair_count + tools))
  done <<LANES
$lanes
LANES
  [ "$pair_count" -lt "$((lane_count * tool_count))" ] \
    || fail "every lane installs every pinned tool ($pair_count of $((lane_count * tool_count))), which is the unconditional install this change removed"
  pass "lane tool installs are $pair_count of a possible $((lane_count * tool_count)), so a download outage no longer reds lanes that never use the tool"
}

test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_previously_unbounded_jobs_keep_their_caps
test_measured_lanes_keep_their_existing_bounds
test_stock_bash_job_runs_the_shared_lane_owner
test_failed_lint_ends_with_the_repair_note
test_only_the_lint_job_names_a_linter_installer
test_every_lane_job_derives_its_tools_from_its_own_lane
test_installed_tools_cover_every_test_that_needs_one
test_no_lane_installs_a_tool_its_tests_never_invoke
