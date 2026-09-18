# Stock macOS Bash 3.2 lane coverage

`bin/fm-test-run.sh` owns which tests the `stock-bash` lane selects, the exclusion table with one reason per excluded test, and the `STOCK_BASH_MAX_SCRIPT_MS` bound a `cost:` reason must clear.
`bin/fm-stock-bash-lane.sh` owns everything the lane runs, so CI's `macos-stock-bash` job and a local run before push execute the same checks; `.github/workflows/ci.yml` owns that job's tool installs and wall-clock budget.
This record holds the measurement those reasons are justified against, and states what the lane still cannot cover.

## Why the lane exists

Every other CI job runs on `ubuntu-latest`, which is Bash 5.
macOS still ships Bash 3.2.57 as `/bin/bash`, and constructs that only break there are invisible to every Linux job.
The best-known member of that class is `"${arr[@]}"` on an empty array under `set -u`, which Bash before 4.4 treats as unbound.

A second member, measured on `main` on 2026-09-17 under `/bin/bash` 3.2.57(1)-release, is pattern substitution whose pattern is a quoted path.
Bash 3.2 chooses the pattern/replacement separator by scanning the expansion text for the first `/` without honouring the double quotes around it, so `${command/"$ROOT/bin/emit.sh"/"$replacement"}` splits the pattern at `"$ROOT` and substitutes silently wrong text rather than failing; Bash 4+ honours the quotes and substitutes correctly.
Holding both sides in variables first, as `${command/"$emit_command"/"$record_command"}`, leaves no literal `/` in the expansion text, so both versions agree while the quotes still keep the match literal instead of a glob.

`bash -n` cannot see it.
A parse sweep answers "does this file parse", and an unbound-variable expansion is a runtime failure in a file that parses cleanly.
That distinction is the whole reason a job can be green while the code it names is broken.

## What the job covered before, and what that cost

Before this lane, `macos-stock-bash` executed three targets under real `/bin/bash`: `tests/fm-fleet-snapshot-view.test.sh`, `tests/fm-bearings-snapshot.test.sh`, and one single-test run inside `tests/fm-public-followup.test.sh` selected with `FM_TEST_ONLY`.
Every other shell file got `bash -n` only.
The job's name promised stock-macOS-Bash coverage and its behaviour delivered that coverage for three files, which is why commit `1a093784` could repair eleven Bash 3.2 sites across ten test files that this job had reported green on.

## The blind spot widening does NOT close

Nine of the ten files repaired in `1a093784` are Herdr or live-harness end-to-end tests.
Each one gate-skips near its top when its tool is absent:

```text
tests/fm-herdr-session-cleanup-e2e.test.sh:13:
command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
```

The repaired expansion in that file is at line 49, well past the gate.
Herdr is not installed on a stock macOS runner, so running these files in this lane executes the gate and exits 0 without ever reaching the construct that was broken.

Running every test file in this lane would therefore still not have caught nine of those ten bugs.
Only `tests/fm-on.test.sh` among them is a portable test this lane genuinely exercises.

The structural reason is that the two properties never meet in CI: the required `tests-herdr` job has real Herdr but runs Bash 5, and this job has Bash 3.2 but no Herdr.
The lane does not hide this.
`bin/fm-test-run.sh` names every gate skip and its reason in the job log, so the job reports the coverage it cannot deliver instead of counting it as a pass.
Closing it needs the two properties in one job - Bash 3.2 on a runner that has Herdr - and is tracked as follow-up work, not covered here.

## Refreshing the cost table

The `cost:` reasons in `bin/fm-test-run.sh` cite measured per-script durations.
The `macos-stock-bash` job uploads `fm-test-timing-stock-bash`, whose `scripts[].duration_ms` values are the CI measurement for every script the lane runs; refresh the table from that artifact rather than from a local run, because local timings and CI timings are not interchangeable.

## Local measurement

Local measurement establishes which tests can run under stock Bash at all, and the order of magnitude of the full suite's cost.
It is not a substitute for the CI artifact above: these runs share a machine with other work, and the host is not a GitHub runner.

Environment, 2026-09-16, Darwin 25.3.0 arm64, `/bin/bash` 3.2.57(1)-release:

```text
PATH=<shim>:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
<shim> contains only: bash -> /bin/bash, plus the repository-pinned
shellcheck 0.11.0 and actionlint 1.7.12
```

Each script was run as `bash tests/<name>.test.sh` with that PATH, one at a time, holding the machine-wide build mutex.

### Why the shim replaced the old PATH

The previous job set `PATH=/bin:/usr/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin` to reach stock Bash.
Under that PATH on macOS, `/usr/bin` also wins for every other tool:

```text
python3: /usr/bin/python3  ->  Python 3.9.6, no tomllib
jq:      /usr/bin/jq       ->  a macOS platform binary
bash:    /bin/bash         ->  3.2.57  (the intended pin)
```

A first measurement pass under that PATH produced failures with no connection to the shell under test: `tests/fm-kimi-harness.test.sh` refused because `python3` had no `tomllib`, and `tests/fm-remote-herdr-guard.test.sh` failed because it specifically refuses a platform-binary `jq`.
Pinning only `bash`, and leaving every other tool at the runner's normal version, is what lets those tests run and keeps the lane about the one variable it names.
The job asserts the pin held after each PATH change rather than trusting it.

### What a local run can and cannot decide

The measurement host has no Bash 5 (`/bin/bash` 3.2.57 is the only `bash` on it), so a local run cannot separate "fails under Bash 3.2" from "fails on this host" by re-running under a newer shell.
The discriminator used instead is the failure signature: the class this lane exists to catch reports `unbound variable`, as in

```text
tests/fm-ask-user-authority.test.sh: line 10: FM_MUTANT_ARRAY[@]: unbound variable
```

No measured script produced that signature, which is consistent with `1a093784` having repaired the reachable sites.
Every local failure observed instead named a host-specific cause: an absent pinned linter, an absent `tasks-axi`, an absent backend CLI, a live-harness guard reacting to a locally installed harness, or an `EACCES` rename inside the host temporary directory.
Whether such a test also fails on a macOS runner is not decidable locally; the `macos-stock-bash` job itself is the authority, and an `incompat:` exclusion cites what that job reported.

### Result, 2026-09-17

| Set | Scripts | Measured stock-Bash runtime |
| --- | ---: | ---: |
| whole suite | 210 | 119.9 min |
| `stock-bash` lane | 136 | 16.2 min |
| excluded by the table | 74 | 103.7 min |

The lane is 65% of the suite for 14% of its runtime, which is the whole reason a bound exists: the excluded tail is 74 scripts carrying 104 of the 120 minutes.
49 scripts in the lane gate-skip, most of them `live: opt-in` guards that spend model tokens and stay opt-in on CI too; the runner names each one and its reason rather than counting it as a pass.
So the lane SELECTS 136 files and EXECUTES 87 of them, against three executed before.
The selected-versus-executed distinction is the same one that made the old job's name wrong, so it is stated here rather than left to be inferred from a count.

Eight excluded entries record `cost:240000` exactly.
Those scripts outran the measurement's own 240-second per-script cap and were terminated, so the recorded value is a floor on their runtime rather than a completed measurement.
Every other `cost:` value is a completed run.

### Failures this widening surfaced

No script produced the `unbound variable` signature, in any of the 210.
The failures that did appear fall into three groups.

Three tests cannot run in this lane by construction, and are excluded as `incompat:`.
`tests/fm-cursor-harness.test.sh`, `tests/fm-harness-precedence.test.sh` and `tests/fm-muse-harness.test.sh` fake a process name by copying the interpreter to a file named after a harness.
When `bash` is the Apple-signed system shell, macOS kills the copy:

```text
$ cp /bin/bash "$TMP/codex" && "$TMP/codex" -c 'echo hi'
$ echo $?
137
$ codesign -dv "$TMP/codex"
Identifier=com.apple.bash
```

Exit 137 is SIGKILL: the copied binary's signature does not validate outside its original path.
The faked process never runs, so the harness resolves nothing and the test reads that empty result as a detection failure.

The detection itself is fine, which was checked rather than assumed.
Presenting the same process name through a symlink, whose signature still validates, resolves correctly:

```text
$ ln -s /bin/bash "$TMP/muse-bin-0.1.0-R708.1"
$ "$TMP/muse-bin-0.1.0-R708.1" -c 'bin/fm-harness.sh'
muse
```

So this is an artifact of the tests' process-faking technique under a system-shell pin, not a defect in `bin/fm-harness.sh`.
It does mean the ancestry contract those three assert is unreachable in this lane, which is why they are excluded by name rather than left to fail.

Two tests failed for reasons this host could not attribute at measurement time: `tests/fm-afk-return.test.sh` ("evidence publication failure should retain catch-up") and `tests/fm-extension-binding.test.sh` ("local bind returned no binding retirement identity").
Neither showed the Bash 3.2 signature and neither copies the interpreter.
`tests/fm-extension-binding.test.sh`'s failure was later diagnosed as macOS 26.3 enforcing POSIX's write-permission requirement on `rename()`'s source directory, which made every bind fail EACCES against a staging root already sealed to 0555; `bin/fm-extension.mjs` now reorders `installPackage` to rename before sealing (see its comment at the rename site) so the source directory is still owner-writable when the rename runs. `tests/fm-afk-return.test.sh` remains unattributed.
Both were left IN the lane deliberately: excluding a test on unproven local evidence loses coverage, and the `macos-stock-bash` job is the authority on whether they fail on a runner.

Several early failures were the measurement rig rather than the code, recorded here so they are not re-reported as findings.
`tests/fm-lint-workflows.test.sh` failed until the pinned `actionlint` was on PATH, `tests/fm-kimi-harness.test.sh` failed until `python3` had `tomllib`, and `tests/fm-remote-herdr-guard.test.sh` failed while `jq` was the macOS platform binary.
All three pass under the environment above.

## Local cost before push

`bin/fm-stock-bash-lane.sh` lets a worker run this lane before pushing, which is where the CI-only failures landed.
On 2026-09-18 under `mutex` on the fleet laptop, the lane selected 139 scripts, failed none, gate-skipped 48, and took 1,167,538 ms of test time, about 19.5 minutes, all under the machine-wide lock; another worker queued behind it for over nine minutes.
CI's own lane runs took 18.6 to 20.3 minutes, so a local run saves no wall time; it moves the failure before the push instead of after a CI round trip and a repair cycle.

That puts this lane in tension with [build-lock-contention.md](build-lock-contention.md): running the lane before every push makes it one of the longest holds on the machine for every firstmate change.
It is a single run, so it obeys the per-run wrap rule, but the two goals pull against each other.
The intended resolution is to keep the local run as the one pre-push lane hold, replacing ad-hoc local reruns of the same suites rather than adding to them, and to cut the hold by selecting only the lane scripts a change can affect once `bin/fm-test-run.sh` can intersect a lane with its changed-file selection; that would stay a runner selection, not a second list.
Until then the trade is about twenty minutes of lock per firstmate change against a CI round trip per missed failure.

