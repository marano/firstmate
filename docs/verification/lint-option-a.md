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
