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

## Recommendation

Bound how long a holder keeps the lock, and never kill a build: a wrongly killed build is worse than a slow one.
Try the cheapest steps first, and build nothing further until they have been tried.

1. Make the wrap rule precise: one `mutex` invocation per build or test run, never one per unit inside a run, and never one around a loop of separate runs such as a baseline plus mutants.
   Arrival order then lets a queued pipeline step run between two mutant runs instead of waiting out the whole loop.
2. Make a long hold visible to the supervisor, not only to the holder: today the ceiling warning goes to the holder's own stderr, which in every long hold above was a backgrounded task nobody read.

One four-hour window is a sample, not a season.
A pipeline hold long enough to explain the queueing, or a window with no long holds, would have changed this conclusion; neither was observed.
