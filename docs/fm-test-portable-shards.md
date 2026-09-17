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
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.
Reorder the stored memberships to match when the hints change, because the coverage regressions require each lane's stored order to equal its `--list-scheduled` order.

The lane was split from two to three on 2026-09-17 by captain decision (raising the cap and accepting the existing headroom were both rejected as not cutting wall-clock merge wait), after the two-lane packing measured 8.34 and 8.27 minutes of packed weight against the 10-minute cap with about 0.04 minutes left to gain from repacking - no rebalance left to spend.
The three-way LPT split over the same 24-script hints packs 328865, 328538, and 339763 ms (about 5.5, 5.5, and 5.7 minutes), leaving roughly 43% headroom on the heaviest lane instead of a few seconds.
`tests/fm-captain-hold-lifecycle.test.sh` alone measures 339763ms, more than an even three-way share of the ~997166ms total, so LPT places it alone in shard 3; a fourth lane would not lower that packed max further; it only bounds a shard containing that script.
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
The embedded hints are the slowest completed `duration_ms` each script reached across the `fm-test-timing-portable-serial-*` artifacts of six green CI runs on 2026-09-17: [35194455365](https://github.com/kunchenguid/firstmate/actions/runs/35194455365), [35196521232](https://github.com/kunchenguid/firstmate/actions/runs/35196521232), [35204720947](https://github.com/kunchenguid/firstmate/actions/runs/35204720947), [35209235740](https://github.com/kunchenguid/firstmate/actions/runs/35209235740), [35210040786](https://github.com/kunchenguid/firstmate/actions/runs/35210040786), and [35215053588](https://github.com/kunchenguid/firstmate/actions/runs/35215053588).
All five serial shards completed in all six runs, so every hint comes from a completed artifact measurement rather than from a cancelled job's partial log.
That covers 169 of the 170 current serial members with six samples each; `tests/fm-build-lock.test.sh` postdates those runs and carries no hint yet.
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
Refresh the hints whenever the serial lane gains scripts, rather than waiting for either bound to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size, shard composition, and balance rather than a copied table.
The refreshed hints pack all five shards at 1256037 ms, about 20.9 minutes, against the 1440000 ms per-shard budget.
That budget is derived from the job cap rather than chosen: shard 1 was killed at 30m15s from a 25.2-minute packed baseline, so a slow runner costs about 20% over the packed weight, and 30 minutes divided by that factor less the measured job setup rounds down to 24 minutes.
Job setup is small enough to ignore in that arithmetic but not to assume: on run 35215053588 the whole shard-1 job spanned 25.21 minutes around a 25.00-minute suite step, so every step before and after the suite cost about 0.21 minutes together.

The single longest script, `tests/fm-watch-triage.test.sh` at 708653 ms, is the floor for any shard count.
It bounds the useful shard count at eight before the split stops buying anything.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

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
| portable serial 1-5 | job `timeout-minutes: 30` | Balanced shards pack about 21 minutes; the 30-minute cap remains a hang tripwire while leaving margin for job setup and runner-speed spread. `PORTABLE_SERIAL_MAX_SHARD_MS` keeps the packed weight inside that margin, so growth is answered by re-sharding rather than by raising this cap. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are intended as hang tripwires; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the exact numbers.
