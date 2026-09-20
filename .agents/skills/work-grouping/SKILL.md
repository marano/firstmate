---
name: work-grouping
description: >-
  Agent-only procedure for dispatching work as chunks rather than tickets: keying
  an item at intake, planning a chunk before filling a slot, handing a newly
  ready sibling to the worker already on that group, and clearing a grouping
  refusal with a recorded reason.
  Load before dispatching a ship while config/grouping is on, on any grouping
  refusal from bin/fm-spawn.sh or bin/fm-promote.sh, and on an idle-fleet wake.
user-invocable: false
metadata:
  internal: true
---

# work-grouping

The unit of dispatch is a CHUNK, not a ticket: one repository, one coherent
contract per pull request, one worker per chunk.
This procedure is how that holds in practice.
`bin/fm-grouping-lib.sh` owns what makes two items related, `docs/configuration.md`
owns the posture and its vocabulary, and each verb's own `--help` owns its
mechanics; none of that is restated here.

## Why a procedure exists at all

The rule kept failing while it lived only in a preference file, because every
structural force pointed the other way: the always-loaded contract says to
dispatch isolated work immediately, the ready list counts tickets, and grouping
was a flag to remember under pressure to fill a lane.
A judgement re-made from memory at every dispatch, with no record of whether it
was made, loses to a standing instruction.
So the judgement is made ONCE, at intake, and recorded; everything after that is
mechanical, and the refusal at dispatch is what makes forgetting impossible.

## At intake, key every item

Record what an item belongs with the moment it enters the backlog:
`bin/fm-tasks-axi.sh group <id> <key>`.
The key is opaque to shared code and means whatever this home's captain
preferences say it means - consult `data/captain.md` rather than inventing a
convention here.
An item that genuinely belongs with nothing gets `--solo`, which is a recorded
verdict, not an absence: it says the question was asked and answered.
Key the item even when you are about to dispatch it alone; the key is what lets
the NEXT related ticket find it.

## Before filling a free slot, plan

A free slot is not a reason to dispatch the first ready ticket.
Read what is unplanned with `bin/fm-tasks-axi.sh plan`, then decide, per
repository and key, what belongs together in one job.
Materialize that decision with `bin/fm-tasks-axi.sh chunk <unit> "<title>"
<member>...`, which creates the unit row, stamps the shared key, and parks the
members behind it so the queue offers one ready item instead of several.
Judgement stays yours: shared code can see that two items share a key, never
that they share a contract.
Two items with one key that would need reverting separately are two chunks.

Order chunks that must land in sequence with an ordinary dependency edge between
their unit rows.
A blocker only resolves when the blocking work is Done, so when the earlier
chunk has frozen the contract the later one needs, release it yourself with
`tasks-axi unblock` rather than waiting for the merge.

## Before dispatching beside related work, join

When a sibling becomes ready while a worker is already running that group, hand
it to that worker with `bin/fm-tasks-axi.sh join <unit> <id>` instead of
starting a second one.
The verb prints the two follow-ups it cannot do for you: put that item's own ask
in the brief, and tell the worker.
A second worker on the same group in the same repository is the exact miss this
contract exists to prevent - it duplicates context, and the two workers rebase
over each other.

## When the dispatch refuses

A refusal names what it found and prints the command that resolves it: deliver
the ready sibling in this job, hand the item to the live worker, name the
planned members, or record a key.
Prefer resolving it over overriding it.

Override with `--apart-reason "<one line>"` when the split is genuinely right -
unrelated work that merely shares a key, or work that must ship separately.
The reason is recorded on the task and on the item, and a later fleet review
reads it, so write the reason a reviewer would need, not "not related".
Clearing a refusal is firstmate's own call and needs nobody else's decision, so
a wrongly refused dispatch costs one command, never a lane sitting idle.

The private rule that a same-group chunk is not split without asking still
stands as policy; the mechanism records the reason and moves on.

## What the worker is told

Dispatch a chunk with `bin/fm-spawn.sh --delivers <id>[,<id>...]` against a
brief scaffolded with the same `--delivers`, so each delivered item's own words
sit in its own slot: the reviewer treats that subsection as acceptance criteria,
and a merged paragraph either widens an ask or loses it.
The dispatch refuses a brief whose recorded membership differs from the
dispatch's own, and one with a slot still unfilled.

A worker delivering several items ships one pull request per coherent contract,
one at a time, and names any item it could not deliver on its own status line;
hand that item back with `bin/fm-tasks-axi.sh handback` before the job's cleanup,
which otherwise closes it with the job's pull request.
