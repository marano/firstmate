# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The retained hints are the slowest completed value each script reached across the six green CI runs on 2026-09-17 listed under "Portable serial CI shards" below.
Both parallel lanes completed in all six, so every one of the 24 candidates has six samples from an uploaded `fm-test-timing-portable-parallel-*` artifact, with no script reconstructed from a cancelled job's partial log.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Collect completed per-script measurements for every member before calculating a split.
A cancelled lane's elapsed duration is only a lower bound; its unfinished scripts have no completed duration for that invocation, and a job killed at its cap uploads no artifact at all.

## Parallel lanes

The three parallel lanes use longest-processing-time assignment over those hints.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1`, `list_portable_parallel_2`, and `list_portable_parallel_3`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap and its rationale are owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the widest lane sum to differ from the narrowest by no more than five percent of the widest.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts, under "When hints are refreshed" below.
Reorder the stored memberships to match when the hints change, because the coverage regressions require each lane's stored order to equal its `--list-scheduled` order.

The lane was split from two to three on 2026-09-17 by captain decision (raising the cap and accepting the existing headroom were both rejected as not cutting wall-clock merge wait), after the two-lane packing measured 8.34 and 8.27 minutes of packed weight against the 10-minute cap with about 0.04 minutes left to gain from repacking - no rebalance left to spend.
The three-way LPT split over the same 24-script hints packs 328865, 328538, and 339763 ms (about 5.5, 5.5, and 5.7 minutes), leaving roughly 43% headroom on the heaviest lane instead of a few seconds.
On those 2026-09-17 hints `tests/fm-captain-hold-lifecycle.test.sh` (339763 ms) exceeded an even three-way share of the ~997166 ms total, so LPT placed it alone in shard 3; a fourth lane would not have lowered that packed max, only bounded a shard containing that script.
The hints were refreshed on 2026-09-24 from the slowest per-script durations across four green `main` runs (35976456798, 35976793939, 35988804472, 35991212700), because the 2026-09-17 hints had gone stale: `tests/fm-pr-merge.test.sh` had grown from 182 s to 398 s and `tests/fm-lint.test.sh` shrunk from 169 s to 35 s, so lane 2 measured 495-533 s of job wall against a 10-minute cap while the packed hint sums claimed balance.
The re-pack puts `tests/fm-pr-merge.test.sh` with three small scripts in shard 2 and `tests/fm-captain-hold-lifecycle.test.sh` with the lighter tail in shard 3, packing all three lanes at about 405 s; `tests/fm-pr-merge.test.sh` is the new floor.
Growth beyond this still has to be answered by the lane count or the cap, both of which [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) reserves as a separate scope decision.
There is no equivalent of `PORTABLE_SERIAL_MAX_SHARD_MS` on these lanes yet; `parallel_max_ms` is reported but not bounded.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The embedded hints are the slowest completed `duration_ms` each script reached across the `fm-test-timing-aggregate` artifacts of several green `main` runs, refreshed on 2026-09-24 with `--refresh-serial-hints`; the refresh refuses unless the inputs cover every hinted script, so no serial member is left unmeasured.
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
It then recurred with the shards at five and the cap at 30 minutes: on [PR 12](https://github.com/kunchenguid/firstmate/pull/12) serial shard 1 was killed at 30m15s with every completed step green, and GitHub reports a cap-killed job as `cancelled` rather than `failure`, so it carried no verdict to classify.
The hints, not the packing, were the cause both times.
The 2026-09-01 table predicted all five shards at an identical 16.4 minutes while the six runs above measured 25.0-27.2, 15.3-17.8, 16.2-18.5, 13.5-17.0, and 20.0-23.3 minutes of script time, because the retained hints understated nearly every script: `tests/fm-watch-triage.test.sh` alone measured 708653 ms against a 262626 ms hint, and the lane's true total was 104.7 minutes rather than the 82.0 the table implied.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, but an unmeasured script is only one way the balance rots, and it was not this one: that bound was satisfied throughout, at 22 of 170.
The guard therefore also reports the heaviest shard's packed weight as `serial_max_ms=` and refuses past `PORTABLE_SERIAL_MAX_SHARD_MS`, reported alongside it as `serial_shard_budget_ms=`.
A stale hint that pushes a shard toward its job cap now reds the seconds-long coverage guard, which names the offending shard, instead of surfacing half an hour later as a verdictless cancellation.
Refresh the hints under "When hints are refreshed" below rather than waiting for either bound to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size, shard composition, and balance rather than a copied table.
The hints refreshed on 2026-09-24 pack the heaviest shard at 1402289 ms, about 23.4 minutes, against the 1440000 ms per-shard budget.
That budget is derived from the job cap rather than chosen: shard 1 was killed at 30m15s from a 25.2-minute packed baseline, so a slow runner costs about 20% over the packed weight, and 30 minutes divided by that factor less the measured job setup rounds down to 24 minutes.
Job setup is small enough to ignore in that arithmetic but not to assume: on run 35215053588 the whole shard-1 job spanned 25.21 minutes around a 25.00-minute suite step, so every step before and after the suite cost about 0.21 minutes together.

The single longest script is the floor for any shard count; `tests/fm-watch-triage.test.sh` was split into `tests/fm-watch-triage-*.test.sh`, and the longest of those, `tests/fm-watch-triage-stale.test.sh` at 391394 ms, is now that floor.

Refresh with `bin/fm-test-run.sh --refresh-serial-hints <timing.json...>` over the `fm-test-timing-aggregate` artifacts of several green `main` runs (`gh run download <run-id> -R <owner>/<repo> --name fm-test-timing-aggregate`); it rewrites the table with the slowest completed duration per script, and keeps the existing hint of every member this home excludes by default, because CI never runs those and no artifact can measure them.
`--derive-serial-hints` prints the same table without writing it.

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## When hints are refreshed

A hint can only come from green CI runs that include the script at its new size, and those runs happen after the change that grew it, so no change can refresh the hints for its own growth.
A refresh is therefore its own follow-up change, made from the timing artifacts of several green runs on `main`, rather than an obligation on the change that caused the growth.
File it when a change adds scripts to a lane or grows a member materially, and whenever `--check-coverage` reports `serial_unhinted=` or `serial_max_ms=` approaching its bound; the guard's refusals remain the enforced backstop.
A refresh re-packs the shards, which changes what every script measures, so it is a rebalance rather than a correction to a set of numbers: expect the reported per-script gaps to be different afterwards rather than absent, and judge the result by the lane timing guard below.
Lint shard weights need no refresh: [`bin/fm-lint.sh`](../bin/fm-lint.sh) derives them from the source graph at run time.

## Lane timing guard

Hints go stale silently, so the aggregate job's "Check serial shard timings" step runs `bin/fm-test-run.sh --check-lane-timing` on every push and pull request.
It refuses an input missing any shard, because the aggregate job also runs when a lane produced no timing artifact and summing four shards out of five makes both bounds below silently lenient.
It then checks two things and exits non-zero naming either:

- Each shard's **measured** total against `PORTABLE_SERIAL_MEASURED_SHARD_MAX_MS` (1650000), a tripwire in front of the job cap read off what happened rather than off the hints.
  It sits above the highest healthy measurement seen on any packing (1567 s) and below the roughly 1740 s of the cap left after job setup, so it names a shard with time in hand instead of letting the job be killed with no verdict.
  The packed weight cannot stand in for this: it under-predicted the measured shard total by up to 24%, so overruns were invisible to a coverage guard that only ever saw packed weight.
  Shard 5 measuring 1532068 ms and 1560275 ms on green `main` runs sits below this bound; that near-cap margin is tracked as `fm-serial-shard5-near-job-cap` rather than caught here.
  The answer when this trips is re-sharding, not a larger bound.
- The lane's **measured** total against its packed weight, refusing past `PORTABLE_SERIAL_LANE_UNDERPREDICT_PERCENT` (10).
  Both sides are recomputed from the scripts the run itself reported, so adding or removing tests moves them together and neither side needs re-deriving when the script set changes.
  The refresh takes each script's slowest run, so the packed weight normally sits a few percent above the measured lane; measuring 10% above it means the table has rotted enough to make the per-shard budget it feeds untrustworthy, and the answer is the refresh above.

A per-script gap between a measured duration and its hint is reported as `FM_HINT_DRIFT`, past the same `PORTABLE_SERIAL_HINT_DRIFT_PERCENT` (50) and `PORTABLE_SERIAL_HINT_DRIFT_FLOOR_MS` (30000) band, and gates nothing.
It cannot: a script's measured duration is not a property of the script.
The 2026-09-21 re-pack is the measurement: it changed no test file, so the same `tests/fm-bootstrap.test.sh` measured 43663 ms in shard 4 and 104844 ms in shard 3, and `tests/fm-send-resolve-key.test.sh` measured 74942 ms in shard 5 and 20282 ms in shard 4.
`tests/fm-secondmate-sync.test.sh` did not change shard at all and still moved from 53642 ms to 85037 ms once its shard's composition changed.
The lane's measured total meanwhile stayed between 5860 s and 6314 s across both packings, which is why the total is the quantity a re-pack leaves alone and the per-script number is not.
Measured against a fixed packing the same durations are stable: across nine consecutive green `main` runs the 105 serial scripts over 5 s had a median spread of 17% and a 90th percentile of 34%, so the band is right and the basis was not.
This is also why the guard runs pre-merge now: a branch's per-script durations were never `main`'s, but a shard's measured total against the job cap is the same quantity on either.

The packed shards are not a way past the floor: the stock Bash 3.2 lane (about 19.7 minutes) bounds CI end to end, so more serial shards buy nothing.

## Default exclusions

`bin/fm-test-run.sh` owns one table of tests this home does not run by default, printed with a reason for each by `--list-default-exclusions`: the `secondmate` and `real-herdr-gated` families, and the Pi, unused-harness and unused-backend scripts. Some of those entries name live scripts that currently skip; their reason line says so, and they hide nothing.
It governs `--all`, `--lane`, `--proven-isolated` and `--changed`, so a local run and every CI lane, the stock Bash 3.2 lane included, leave the same tests out; `ci.yml` carries no list of its own and only says so in its header.
The exclusion is applied after selection, so the packed shards do not move.
Nothing is deleted and the coverage guard still accounts for every file, because each excluded test stays in its lane's membership; the guard also refuses a table entry that names a missing test or family or lacks a reason.
To run one anyway, name it (`bin/fm-test-run.sh tests/fm-backend-orca.test.sh`, or `--family <name>`), or pass `--include-excluded` (or set `FM_TEST_INCLUDE_EXCLUDED=1`) to a default selection.
The Herdr job is skipped unless the repository variable `FM_CI_RUN_HERDR` is `true`; it names its family explicitly, so setting the variable is the only step.
The aggregate job's "Prove exclusions" step runs `bin/fm-test-run.sh --check-exclusions` on every run, reading the recorded timings rather than any text.
It names each excluded script that executed (`FM_EXCLUSION_EXECUTED`) and each other script that did not (`FM_EXCLUSION_DROPPED`), and writes the excluded list to the job summary.
An explicit `--family` or script run, such as the Herdr job, neither proves nor breaks it.
Excluding a test is a cost and flakiness decision, not a verdict on it, and an exclusion that hides a red hides it rather than fixing it.
The `fm-pi-watch-shard-interference` red that `tests/fm-pi-watch-extension.test.sh` carried was answered rather than hidden, and its regression lives in the unexcluded `tests/fm-turnend-guard.test.sh`.
The `fm-calm-pi-extension` red on main was answered too: its restart raced the exit of the tmux server it had just emptied, and the test now keeps that server up; it stays excluded because CI installs no Pi.

## Pinned linter installs

Lane membership also decides which pinned external linters a CI job downloads.
`bin/fm-test-run.sh --list-required-tools` prints, for any selection, the union of the tools its scripts invoke, from the `script_required_tools` table beside the lane memberships; each lane job pipes that answer into `bin/fm-install-pinned-tools.sh`, which owns the tool-to-installer mapping and refuses a name it cannot install.
The stock-Bash job asks `bin/fm-stock-bash-lane.sh --required-tools` instead, because that lane owner also runs a retained regression outside the lane.
So a lane holding no test that invokes either linter downloads neither, and `.github/workflows/ci.yml` names no tool at all outside the Lint job, whose own two installs are not lane-derived because `bin/fm-lint.sh` needs both by definition.

A release-download outage on 2026-09-21 reddened six jobs across two main runs and five were in lanes that never invoke the tool whose download failed; a hand-maintained per-job tool matrix was rejected as the answer because that shape had already rotted into four of the same six reds.
A failed install stays fatal, so a lane that genuinely needs a binary still fails loudly when it cannot get one.

The table is held against rot from both sides, proven from what a run recorded rather than from any text.
A case skipped for a missing pinned tool prints `tests/lib.sh`'s `fm_tool_skip` marker, and wherever those tools are supposed to be installed - CI, or `FM_TEST_REQUIRE_DECLARED_TOOLS=1` - the run reds naming the script and the tool, whether the table promised that tool and the install did not deliver it or the table never named it at all.
`--check-coverage` separately refuses an entry naming a test that does not exist or a tool with no installer, and reports the table size as `required_tools=`.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that all three parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.
It separately reports the heaviest shard's packed weight as `serial_max_ms=` against `serial_shard_budget_ms=` and refuses past `PORTABLE_SERIAL_MAX_SHARD_MS`, naming the shard, so a shard growing toward its CI job cap fails here rather than as a timed-out job that uploads no timing artifact.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2/3 | See [CI workflow](../.github/workflows/ci.yml) | The workflow owns the parallel cap rationale and its evidence limits. |
| portable serial 1-5 | job `timeout-minutes: 30` | Balanced shards pack about 23 minutes; the 30-minute cap remains a hang tripwire while leaving margin for job setup and runner-speed spread. `PORTABLE_SERIAL_MAX_SHARD_MS` keeps the packed weight inside that margin, so growth is answered by re-sharding rather than by raising this cap. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are intended as hang tripwires; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the exact numbers.
