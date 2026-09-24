# Local ShellCheck option A measurement

The 2026-09-05 lint-cost audit measured the seven roots from the missed-reply incident at commit `f09de8a3d3a550b13b4d535346fbc7b9ac0d6c19`:

```text
bin/fm-brief.sh
bin/fm-parent-channel-lib.sh
bin/fm-pending-reply-lib.sh
bin/fm-secondmate-report.sh
tests/fm-brief.test.sh
tests/fm-classify-corr-token.test.sh
tests/fm-pending-reply.test.sh
```

ShellCheck was the repository-pinned 0.11.0 Darwin arm64 build.
The baseline was one source-aware invocation containing all seven roots.
Option A used one process per root, omitted `--external-sources`, retained extended dataflow, and applied the local cross-file exclusion list.
Both variants were measured in the same quiet-host window:

| Variant | User + system CPU | Reduction | Worst-process RSS | Reduction |
| --- | ---: | ---: | ---: | ---: |
| source-aware baseline | 140.1 s | n/a | 8.30 GB | n/a |
| option A, no `--external-sources`, per-root processes | 9.8 s | 93.0% | 0.56 GB | 93.3% |

## Which variable produced the saving

Option A changed two variables at once, and most of the saving came from omitting `--external-sources`.
The 2026-09-17 lint-cost investigation separated the two variables on 22 cheap `bin/*.sh` roots with the pinned 0.11.0 Darwin arm64 build, both runs keeping `--norc --external-sources`:

| Variant | Peak RSS | Summed CPU |
| --- | ---: | ---: |
| one invocation, 22 roots | 240 MB | 5.35 s |
| 22 invocations, one root each | 239 MB worst process | 5.59 s |

That sample read as "per-root processes do not cap memory", and the correction below shows why it could not: on 22 roots of roughly 240 MB each, a per-root peak and a whole-shard peak are the same number, so the sample could not separate them.

On single expensive roots, omitting `--external-sources` alone cut peak RSS 9.1x to 26.7x, for example `bin/fm-merge-outcome-lib.sh` from 826 MB to 31 MB.

```bash
shellcheck --norc --external-sources -- bin/fm-merge-outcome-lib.sh   # 826 MB peak
shellcheck --norc -- bin/fm-merge-outcome-lib.sh                      # 31 MB peak
```

## Correction: per-root processes do bound peak RSS on expensive roots

The 2026-09-22 forward-closure measurement repeated the invocation-shape comparison on the three heaviest canonical roots instead of 22 cheap ones, with the pinned 0.11.0 Darwin arm64 build on a 16 GB 10-core Apple M-series host, every run keeping `--norc --external-sources`:

| Variant | Peak RSS | Wall |
| --- | ---: | ---: |
| one invocation, the three heaviest roots | 5,656 MB | 107.9 s |
| one invocation per root, the same three | 3,781 MB worst process | 118.5 s summed |

The per-root peak is exactly the heaviest root's own cost, `tests/fm-stat-shadowing.test.sh` at 3,781 MB, while the batched run peaks 1,875 MB above it.
So a whole-shard invocation does accumulate state across roots, and per-root running caps the peak at the single heaviest root for about 9% more wall time.
This is why `bin/fm-lint.sh` runs changed-file mode one root per process and one shard at a time, and it is the measurement `#3778` did not have: that change measured "above 8 GB on a single root" while passing a whole shard to one invocation, then introduced per-root running only on the path it had just turned source following off for.

## What source following costs a changed-file run

Cost tracks a root's transitive source closure, not its own bytes, and the same window measured `shellcheck --norc --external-sources` on one root at a time across that range:

| Closure bytes | Root | Wall | Peak RSS |
| ---: | --- | ---: | ---: |
| 1,055,427 | `tests/fm-stat-shadowing.test.sh` | 93.9 s | 3,781 MB |
| 666,400 | `tests/fm-daemon.test.sh` | 21.7 s | 3,208 MB |
| 526,752 | `tests/fm-x-mode.test.sh` | 2.9 s | 469 MB |
| 396,627 | `bin/fm-procevent.sh` | 8.2 s | 1,393 MB |
| 257,578 | `bin/fm-push-transition-lib.sh` | 6.4 s | 937 MB |
| 172,990 | `bin/fm-brief.sh` | 2.2 s | 413 MB |
| 78,926 | `tests/fm-cmux-claude-composer-live-e2e.test.sh` | 0.9 s | 171 MB |
| 50,092 | `tests/fm-remote-secondmate-trace-context.test.sh` | 0.5 s | 107 MB |
| 32,384 | `tests/fm-pr-reviewers.test.sh` | 0.3 s | 70 MB |
| 5,420 | `bin/fm-project-origin-lib.sh` | 0.1 s | 28 MB |

Over the 419 canonical roots the closure distribution is p50 52,336 bytes, p75 155,013, p90 333,390, p95 468,425, p99 666,400, max 1,055,427, so a median changed root costs about half a second and 107 MB and a p90 one about 7 seconds and 1.2 GB.
Closure bytes rank cost well but do not predict it exactly: `tests/fm-x-mode.test.sh` has a larger closure than `bin/fm-procevent.sh` and costs a third as much.
Reproduce a row with `mutex /usr/bin/time -lp shellcheck --norc --external-sources -- <root>`, and list the closure weights the same way `bin/fm-lint.sh` does, from its `fm_lint_root_weights`.

## What the changed-file gate costs end to end

The same window ran `bin/fm-lint.sh` itself, reading its own telemetry rather than a wrapper's aggregate, on two changed sets:

| Changed set | Roots | Shards | Wall | Peak worker RSS |
| --- | ---: | ---: | ---: | ---: |
| PR 65's own set, including `bin/fm-watch.sh` | 4 | 1 at a time | 86 s | 4,404,160 KiB (4.20 GB) |
| this change's own set | 3 | 1 at a time | 5.1 s | 225 MB |

`max_worker_rss_kib` is the peak of one shard worker, and at one shard at a time no two workers are ever resident together, so 4.20 GB is the concurrent peak for the worst changed set measured here.
Wrapping the whole run in `/usr/bin/time -lp` instead reports 5,836 MB, because the parent's `RUSAGE_CHILDREN` aggregate is not a single process's peak; read the telemetry for this number.
That worst case is roughly half the "above 8 GB on a single root" that `#3778` rejected, and unlike the shape `#3778` measured it no longer grows with the number of changed roots.
A changed set touching the heaviest roots is the expensive case and costs about a minute and a half; a typical one costs seconds.

## What the local pass could not evaluate before that

The local changed-file pass used to drop `--external-sources` and exclude `SC1091,SC2034,SC2153,SC2329`, and that exclusion list was not the whole gap.
The exact tree CI failed on 2026-09-22, commit `4c2dba64a81e290219fb92abfa27270938bca22b` (PR 65, CI run 35676938642), separates the two variables on the file that failed:

```bash
shellcheck --norc --exclude=SC1091,SC2034,SC2153,SC2329 -- tests/fm-watch-triage.test.sh  # exit 0, no findings
shellcheck --norc --exclude=SC1091,SC2034,SC2153,SC2329 --external-sources -- tests/fm-watch-triage.test.sh
                                                                                          # exit 1, 9 x SC2031
shellcheck --norc --external-sources -- tests/fm-watch-triage.test.sh                     # exit 1, 9 x SC2031
```

The exclusion list is present in the middle run and SC2031 is raised anyway, so `--external-sources` alone decided it.
The file sources `bin/fm-validation-receipt-lib.sh` inside a subshell, and only a source-following pass sees that library's function-local `id`, `dir`, and `state` and attributes them to the caller's names.
SC2031 was on no exclusion list, so the local gate reported a green that covered neither it nor any other code whose evaluation depends on library context.

## Reproduction

Check out the recorded commit, install the pinned binary with `bin/fm-install-shellcheck.sh`, put it first on `PATH`, and run the following on macOS.
No `--extended-analysis=false` flag is present, so dataflow remains on.
Diagnostics are discarded because only process cost is under measurement.

```bash
set -eu
[ "$(bin/fm-lint.sh --required-version)" = "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" ]
roots=(
  bin/fm-brief.sh
  bin/fm-parent-channel-lib.sh
  bin/fm-pending-reply-lib.sh
  bin/fm-secondmate-report.sh
  tests/fm-brief.test.sh
  tests/fm-classify-corr-token.test.sh
  tests/fm-pending-reply.test.sh
)
rm -rf .lint-option-a-measurement
mkdir .lint-option-a-measurement
/usr/bin/time -lp -o .lint-option-a-measurement/baseline.time \
  shellcheck --norc --external-sources -- "${roots[@]}" >/dev/null || true
index=0
for root in "${roots[@]}"; do
  index=$((index + 1))
  /usr/bin/time -lp -o ".lint-option-a-measurement/option-a.$index.time" \
    shellcheck --norc --exclude=SC1091,SC2034,SC2153,SC2329 -- "$root" \
    >/dev/null || true
done
awk '
  /^user / {cpu += $2}
  /^sys / {cpu += $2}
  /maximum resident set size/ {if ($1 > rss) rss=$1}
  /bytes allocated/ {allocated += $1}
  END {printf "cpu_seconds=%.2f worst_rss_bytes=%.0f bytes_allocated=%.0f\n", cpu, rss, allocated}
' .lint-option-a-measurement/baseline.time
awk '
  /^user / {cpu += $2}
  /^sys / {cpu += $2}
  /maximum resident set size/ {if ($1 > rss) rss=$1}
  /bytes allocated/ {allocated += $1}
  END {printf "cpu_seconds=%.2f worst_rss_bytes=%.0f bytes_allocated=%.0f\n", cpu, rss, allocated}
' .lint-option-a-measurement/option-a.*.time
```

CPU and RSS vary with host load, so percentage claims must compare runs from one measurement window.
When results must be compared across windows, use the reported `bytes_allocated` totals as the stable work proxy rather than quoting a CPU or RSS ratio.

## What the shard weight tracks

`bin/fm-lint.sh` balances its two shards by each root's source-closure bytes: the root plus every file it transitively sources.
On 2026-09-18, with the pinned 0.11.0 Darwin arm64 build, 40 canonical roots were each linted alone with `shellcheck --norc --external-sources`, sampled every fourteenth root by closure size plus the five largest files and the five smallest relative to their closures.
Each probe was killed past 2.5 GB RSS or 90 seconds; three roots crossed the RSS cap and were left out of the correlation as censored, and all three have the three largest closures.
Over the 37 completed roots, the Spearman rank correlation with CPU seconds was 0.96 for closure bytes and 0.35 for own-file bytes, and with peak RSS it was 0.96 against 0.37.
`bin/fm-secondmate-report.sh`, a 3,250-byte root with a 427,927-byte closure, took 27.6 CPU seconds and 2.5 GB, while the 265,196-byte `tests/fm-pi-branch-extension.test.sh`, whose closure adds little, took 1.0 second and 186 MB.

## Why CI runs one lint shard per runner

The 2026-09-24 measurement ran CI's full canonical lint at commit `19729638263fd8ab746f2b700dd380a62c7ad91a`, 433 roots, with the pinned 0.11.0 Darwin arm64 build on a 16 GB 10-core Apple M-series host, reading `bin/fm-lint.sh`'s own telemetry:

```bash
mutex env GITHUB_ACTIONS=true FM_LINT_JOBS=1 bin/fm-lint.sh --telemetry <file>
```

| Field | Value |
| --- | ---: |
| `max_worker_rss_kib` | 6,326,320 (6.03 GiB) |
| `worker_rss_sum_kib` | 12,255,936 (11.69 GiB) |
| `max_worker_wall_seconds` | 853.65 |

With one shard at a time those are the two shards' own peaks, about 6.0 and 5.7 GiB.
CI used to run both shards at once on one `ubuntu-latest` runner, which has 16 GB, so their peaks could sum to about 11.7 GiB before the operating system and the runner itself.
The heaviest single roots alone are in the same range, so running one root per process does not bound it:

```bash
mutex /usr/bin/time -lp shellcheck --norc --external-sources -- <root>
```

| Root | Wall | Peak RSS |
| --- | ---: | ---: |
| `bin/fm-teardown.sh` | 117.7 s | 7,166 MB |
| `tests/fm-stat-shadowing.test.sh` | 84.5 s | 6,644 MB |
| `bin/fm-watch.sh` | 73.1 s | 6,062 MB |
| `tests/fm-daemon.test.sh` | 32.7 s | 5,067 MB |
| `bin/fm-spawn.sh` | 41.1 s | 4,787 MB |
| `tests/fm-backend-herdr.test.sh` | 39.9 s | 2,831 MB |

A per-root variant of the full lint on two workers measured a 7,647 MB concurrent peak and took 1,046 s against 854 s for the slower whole shard, so it cost about a fifth more wall time and still left two heavy roots free to coincide.
The garbage collector is not tunable from outside: `GHCRTS=-s` reports `bin/fm-teardown.sh` at 3,663,006,728 bytes maximum residency and 8,967 MiB total memory in use, but the pinned binary refuses `-c` and `-M` with `Most RTS options are disabled`.
So CI gives each of the two shards its own job through `bin/fm-lint.sh --shard <k>/2`, and one runner holds one ShellCheck process of about 6 GiB at a time.
Darwin RSS is not Linux RSS, so treat these as the scale of the cost rather than the runner's exact figure.

That memory pressure caused the CI kills is the leading hypothesis, not a proven cause.
The killed jobs' logs prove only the sender: each ends with `The runner has received a shutdown signal.` just before `Process completed with exit code 143`, and in the last 100 CI runs no job other than Lint carried that line.
No log shows an out-of-memory message, so a runner shutdown for another reason, such as preemption, is not excluded.
`bin/fm-lint.sh` now prints the stopping signal and the host's available memory and swap when a signal stops it, so the next such kill records whether memory was exhausted.

## What a repeated source site costs

The 2026-09-24 measurement compared commit `09966ec5d4b2` with the change that gave each late-loaded `bin/fm-pending-reply-lib.sh` dependency one source site and made every `bin/fm-watch.sh` library edge an analysis boundary, using the pinned 0.11.0 Darwin arm64 build on a 16 GB 10-core Apple M-series host.
Each root was linted alone, and each shard as CI runs it:

```bash
mutex env GHCRTS=-s /usr/bin/time -l shellcheck --norc --external-sources -- <root>
mutex env CI=true GHCRTS=-s /usr/bin/time -l bin/fm-lint.sh --shard <k>/2
```

GHC's `total memory in use` is the peak heap and `bytes allocated in the heap` the stable work proxy.
The host was swapping throughout, so Darwin RSS under-read the heap and is not quoted.

ShellCheck inlines a separate copy of a sourced file at every source site it follows; its only guard skips a file already on the current include stack.
`bin/fm-pending-reply-lib.sh` followed `bin/fm-wake-lib.sh`, and through it the classifier, from three lock entry points: that root allocated 62 GiB with a 2,878 MB heap, against 32 GiB and 1,734 MB with one of those sites followed.
A `# shellcheck source=` directive before a file's first command applies to the whole file, so that file's stray `source=bin/fm-marker-lib.sh` had silently resolved its three directive-less wake-library sites to the marker library.
The cost is ShellCheck's dataflow analysis over the inlined program rather than any one function: `bin/fm-watch.sh` reached about 46,000 inlined lines from 24,000 unique ones, its sources alone reproduced 119 of its 132 GiB, and with `--extended-analysis=false` as a measurement-only control its maximum residency fell from 2,725 MB to 264 MB.

| Root | Before | After |
| --- | ---: | ---: |
| `bin/fm-teardown.sh` | 202 GiB, 9,913 MB | 127 GiB, 7,140 MB |
| `tests/fm-stat-shadowing.test.sh` | 157 GiB, 9,806 MB | 6 GiB, 373 MB |
| `bin/fm-watch.sh` | 132 GiB, 7,951 MB | 5 GiB, 621 MB |
| `bin/fm-pending-reply-lib.sh` | 62 GiB, 2,878 MB | 29 GiB, 1,565 MB |

| Shard | Before | After |
| --- | ---: | ---: |
| 1/2 | 1,805 GiB, 9,179 MB, 792 s | 1,546 GiB, 5,109 MB, 600 s |
| 2/2 | 2,181 GiB, 11,411 MB, 927 s | 1,594 GiB, 7,144 MB, 676 s |

These figures supersede the `bin/fm-watch.sh` and `tests/fm-stat-shadowing.test.sh` rows of the heaviest-roots table above.
`bin/fm-watch.sh` itself now follows no library, because each is a canonical root analysed with its full graph; the trade is that the watcher's own dataflow no longer sees library definitions.
`bin/fm-teardown.sh`, `bin/fm-bootstrap.sh`, and `bin/fm-mail.sh` still source `bin/fm-wake-lib.sh` at two sites each, and `bin/fm-teardown.sh` is now the heaviest root measured.
