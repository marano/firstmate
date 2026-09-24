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
