# Build-lock contention

`bin/fm-build-lock.sh` owns the machine-wide build lock and its contract: arrival order, and hold ceilings that report and never kill.
This record holds the measurement of who actually holds that lock and for how long, so a change to lock policy is argued from evidence rather than from the assumption it was first filed under.

## The pipeline is not the contention

The fleet's no-mistakes pipeline takes the lock through a machine-local `agent_args_override` note that tells its agents to prefix heavy commands with `mutex`.
The work was filed on the assumption that pipeline runs were the long holders, because workers used to wrap whole `no-mistakes axi run` calls in `mutex`.
That assumption no longer holds, and this is a correction rather than a detail.

On 2026-09-18 from 11:42Z to 15:42Z, a sampler read the lock's holder record (pid, start epoch, command, cwd) and its waiting-line ticket count every 2 seconds, giving 7,127 samples.
A holder whose cwd lies under the no-mistakes run worktrees is a pipeline agent.

| Holder | Holds | Longest | Total |
| --- | ---: | ---: | ---: |
| pipeline agents, four repositories | 14 | 44 s | 184 s |
| workers | 37 | 6,421 s | 12,903 s |

The lock was held in 91% of samples, and at least one waiter was queued in 63% of them.
Every hold over 600 seconds was a worker running a loop of separate runs inside one `mutex` invocation, the longest a Gradle baseline followed by a mutant loop of Gradle runs, 107 minutes with up to five waiters.
Workers wrapping a whole pipeline run disappeared once the note was in effect: 20 such holds in agent transcripts before the note, none after.

## The lock can be bypassed

During that 107-minute hold, a pipeline test agent queued four `mutex` test commands.
Each one outlived the agent's two-minute tool timeout and was moved to the background, so one agent held four tickets.
The agent read `mutex --status`, saw the long holder, and ran all four suites without the lock, concurrently with the Gradle build.

That is a hole in the mutual exclusion itself, not a tuning problem.
The lock is advisory, so any participant that tires of waiting can step out of the line.
Every fairness or wait-time figure taken while a participant was bypassing it is suspect, including the table above, which cannot see work run outside the lock.

## What those two steps became

Both cheap steps were taken.
`bin/fm-test-run.sh` moved its hold from the whole run to one hold per serial script and one per concurrent phase, and `bin/fm-build-lock.sh` grew the ceiling lines that reach a task's status file through `FM_TASK_STATUS`.
Acquisition also became arrival-ordered, so a waiter's wait is bounded by the waiters ahead of it, and the lock became an N-slot semaphore with N=1 as the default.

## The residual is the wrap rule, not the lock algorithm

Measured 2026-09-22 on a 10-core, 16 GB Apple M-series machine, ShellCheck-clean tree at `bin/fm-build-lock.sh` with a slot count of 2.

Per-script hold lengths are the per-script durations in `portable_serial_weight_hints` (179 portable-serial scripts, each the slowest of several green CI runs):

| Statistic | Per-script hold |
| --- | ---: |
| median | 9.9 s |
| p90 | 85.1 s |
| p99 | 312.2 s |
| longest | 709.9 s (`tests/fm-watch-triage.test.sh`) |
| whole lane | 6,382 s |

So a correctly scoped hold is bounded by one script, and the whole lane is 9x the longest script in it.

A sampler reading `fm-build-lock.sh --status` every 2 seconds for 450 samples caught both shapes in one window on this machine.
A run wrapped as `mutex ./bin/fm-test-run.sh tests/fm-awaiting-landing.test.sh tests/fm-watch-triage.test.sh` was observed holding one slot for 834 s as a single hold, while a correctly scoped `./tests/fm-awaiting-landing.test.sh` hold in the same window reached 8 s.
Every sample of that window read `1 of 2 build slots held, 0 waiting`: nothing was starved, because the second slot absorbed it.

The two shapes are told apart in `--status` by what follows `running:`.
A per-script hold prints the runner's own label, `bin/fm-test-run.sh <one script>`, and moves to the next script as the run proceeds.
A wrapped whole-run hold prints the caller's rendered command instead, so it keeps a `./` prefix or several script paths and does not change for the length of the run.

## A second slot masked the starvation and did not remove it

A competing waiter was timed against a synthetic runner taking one hold per unit, six units of three seconds, in a private lock root, with the waiter arriving four seconds in.

| Slots | Runner shape | Waiter waited |
| ---: | --- | ---: |
| 1 | per-unit holds | 3.49 s |
| 1 | one wrapped hold | 15.22 s |
| 2 | one wrapped hold | 0.80 s |
| 2 | two wrapped holds | 15.38 s |
| 2 | two per-unit runners | 3.51 s |

One wrapped run at two slots is the benign case, and it is the case that was observed live.
Two of them refill both slots and the wait returns to the whole-run length, and a count of 1 remains the default on any machine that has not raised it.
So the extra slot hid this rather than fixing it.

## Standing down for a self-locking runner, measured

With the same synthetic runner at a count of 1, wrapped identically, the only difference being whether `bin/fm-build-lock.sh` recognises the program as one that takes the lock itself:

| Wrapped command | Waiter waited |
| --- | ---: |
| unrecognised name | 16.76 s |
| recognised name (stands down) | 3.99 s |

That is the difference between waiting out the whole run and waiting out one unit.
`tests/fm-build-lock.test.sh` pins the behavior, and `bin/fm-build-lock.sh`'s header owns the rule and which programs it names.

## Why not a bounded hold, and why not a fair-shared queue

The card behind this work named three candidate shapes.
The measurements pick the third and rule out the other two.

A bounded hold can only be enforced by ending the command that holds it, and this lock already settled that question the other way: ceilings report and never kill, because a wrongly killed build is worse than a slow one.
A bound that does not kill is the ceiling warning that already exists.
The measurement also removes the premise: the long holds were not long units, they were whole-lane wraps, so a bound would have ended healthy runs over a wrap rule the runtime can simply enforce.

Fair-sharing the queue does not address hold length at all.
Acquisition is already arrival-ordered, so a waiter's wait is bounded by the waiters ahead of it rather than by luck, and with one holder and one waiter every queue policy still waits out the holder.
Letting the N oldest tickets try, the obvious generalisation, was measured to re-admit barging: a fast poller took the freed slot ahead of an earlier arrival in every run, overtaking it 7, 7 and 23 times inside one poll window.

A long run yielding between phases is the shape that wins, and `bin/fm-test-run.sh` already implements it per serial script and per concurrent phase.
What the measurements show is that those yields were being defeated from outside, by an outer hold that turned every one of them into a nested pass-through.
So the change makes the existing yielding effective rather than adding a mechanism beside it, and no second locking primitive is introduced.

## What was still unbounded

The one script that was a single long hold, `tests/fm-watch-triage.test.sh` (709.9 s on CI, 139 cases), has been split into `tests/fm-watch-triage-*.test.sh` sharing `tests/fm-watch-triage-lib.sh`.
The longest of those parts is about 7 minutes locally, so a targeted run of the area a change touches finishes well inside the no-mistakes test step's limit, and the runner can yield the build lock between parts.

## A whole-machine hold still ran out of memory

Measured 2026-11-06 on the fleet machine: 10 cores (8 performance, 2 efficiency), 16 GiB of which about 6 GiB stayed wired, slot count 3, with the web app's `build-lock-exclusive` patterns in place.
A sampler read `ps -Ao pid=,ppid=,rss=,time=,command=` (CPU as the change in cumulative CPU time between samples), `top -l 1 -stats pid,mem` (each process's memory footprint, which counts its compressed pages), `vm_stat` swap counters and `fm-build-lock.sh --holders` every 8 seconds.
It grouped every process by ancestry as a hold's descendant, an agent, an agent's other descendants, the no-mistakes daemon, or the rest of the machine.
The held run was the web app's full `pnpm test` - vitest 5.0.0, 1,039 files, a jsdom project in worker threads and a browser project in headless Chromium - in a scratch clone at a fixed commit, as `mutex --exclusive pnpm test`, beside the live fleet.
The suite's own local setting is half the cores, 5 workers.

| Run | Workers | Wall | Failed files | Pages swapped out per 8 s | Held footprint, median |
| --- | ---: | ---: | ---: | ---: | ---: |
| B1 | 5, the suite's own | 1,027 s | 1, a locator timeout | 70,789 | 9.2 GB |
| C1 | 3, `VITEST_MAX_WORKERS=3` | 830 s | 0 | 6,007 | 6.6 GB |

Both runs held every slot and nothing else held one while they ran.
The held tree used the same CPU in both, 4.6 and 4.4 cores on average, so the two extra workers bought no CPU.
At 16 KiB pages, B1 swapped about 1.1 GiB out and 1.0 GiB in every 8 seconds and memory pressure read warning in 98% of its samples.
Both ran beside the same competing memory - about 6.2 GB of agents and their descendants and 21 GB for the rest of the machine - so the difference is the run's own pool.
From the two medians, each worker cost about 1.3 GB, one jsdom thread plus one Chromium renderer, on top of about 2.7 GB for the runner itself.

Nine full runs of the same suite by workers earlier that day, at 5 workers and beside up to five workers in that repository, took 868 to 1,277 s and every one of them failed at least one file; eight of the nine failed on a test or a browser action timing out.

The rest of the machine holds most of the memory, and the lock reaches none of it.
Two minutes into B1 the footprint of everything running was 35.6 GB on the 16 GiB machine: desktop applications about 16 GB, the held run about 9 GB, and the fleet's agents with their descendants about 6 GB.
An agent costs 0.35 to 0.45 GB, and in a TypeScript repository the TypeScript language server a code-intelligence plugin starts for each agent costs another 1.5 to 1.65 GB.

## The validation daemon slowed with the memory, not with CPU load

The no-mistakes daemon logs `write: broken pipe` when a client stopped waiting before its answer was written, which is how a slow health probe shows on its side.

| Window | Disconnects |
| --- | ---: |
| B1, 17 min at 5 workers | 13 |
| C1, 14 min at 3 workers | 0 |
| a worker's full run at 5 workers, 16 min from 17:30Z | 54 |
| 12 busy loops beside an ordinary hold, 17:22Z, about 40 s | 0 |
| 16 runs beside 40 busy loops each under whole-machine holds, 2,753 s | 34, 44.5 an hour |
| the whole day, 15:09 to 19:40Z | 181, about 40 an hour |

Busy loops left the daemon at the day's ordinary rate, while a full run at 5 workers drove it far above that and the same run at 3 workers drove it to none.
So deliberate CPU load was not what starved the pipeline, and the lock is not changed for it.

## Every slot's runner fans out

Three ordinary commands from the same clone, each its own `mutex` run, shared the three slots at once: `pnpm typecheck` used about 2 cores and 3.4 GB, `pnpm lint` 1 to 2 cores and 3.8 GB, and `pnpm exec vitest run src/metric src/objective` - 516 tests at the suite's own 5 workers - about 5 cores and 6.1 GB, as much memory as a whole-machine run.
While all three overlapped, the machine swapped 60,000 to 100,000 pages out every 3 seconds.
Agent transcripts from the same day put two or more ordinary holds side by side for about 44 minutes and three for about 18.
Vitest's own default is one fewer worker than the cores, 9 here, so a suite with no setting fans out further still.

## The same held run, before and after

The proof ran the same held full suite four times in an order fixed beforehand - before, after, after, before - each queued through the lock like any other run, beside the live fleet.
Before is the installed lock with `mutex --exclusive pnpm test`, which leaves the suite at its own 5 workers; after is this change's `bin/fm-build-lock.sh --exclusive pnpm test`, which exported `VITEST_MAX_WORKERS=3` on this 16 GiB machine.
The sampler confirmed it: five large Chromium processes under every before hold, three under every after hold.
Held time excludes the time each run queued.

| Run | Arm | Held | Failed files | Pages swapped out per 8 s | Held footprint, mean | Agents and descendants, mean |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| P1 | before | 902 s | 0 | 62,635 | 8.4 GB | 2.7 GB |
| P2 | after | 786 s | 0 | 3,149 | 6.3 GB | 2.3 GB |
| P3 | after | 810 s | 0 | 6,350 | 6.2 GB | 2.3 GB |
| P4 | before | 775 s | 1, a locator timeout | 37,510 | 8.6 GB | 2.0 GB |

The rest of the machine stayed at 20.9 to 21.2 GB in every run.
With the pilots B1 and C1, every run at 5 workers swapped 37,000 to 71,000 pages out per 8 seconds and two of the three timed out a browser action, while every run at 3 workers swapped 3,000 to 6,400 and none timed out anything.
Held time is not reliably shorter at the lighter fleet of the proof window: the arms averaged 838 s before and 798 s after, and P4 finished before both after runs.
What the change buys is the run's memory, and with it the load-dependent timeouts.

## What the lock cannot reach, and the worker limit it implies

The lock now bounds one pool, the test runner's, and nothing else.
It does not reach the agents, the language servers they start, the desktop, the memory of `tsc` and `eslint` on a shared slot (3.4 and 3.8 GB above), or the length of a whole-machine run, which every other worker waits out.
So for a repository whose validation runs its full suite, the number of concurrent workers is the remaining control, and these measurements bound it on this machine.

- Memory: C1 ran clean beside two workers in the web app's repository, each with its 1.5 to 1.65 GB language server, a marketing-site worker and a firstmate worker, and P2 and P3 beside one web-app worker and two firstmate workers.
  At 5 workers even that lighter fleet thrashed (P1), and the morning's five web-app workers saw every full run fail.
  Each further web-app worker adds about 2 GB the lock cannot reclaim.
- Queue: a whole-machine full run holds the machine for 786 to 830 s, and a no-mistakes agent step has 30 minutes.
  A step that runs the full suite itself behind the full runs of k - 1 other workers needs k x 830 s to fit in 1,800 s, so k is at most 2.

This machine therefore sustains two concurrent workers in a full-suite-heavy repository like the web app, in a fleet no larger than the four-worker mix measured clean.
