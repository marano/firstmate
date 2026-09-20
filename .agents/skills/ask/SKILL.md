---
name: ask
description: >-
  Present the captain's open decisions through the interactive question picker, batched into a single call, most impactful first, only when the captain explicitly invokes /ask.
  Plain text stays the default way decisions reach the captain; never load this skill on your own initiative or to deliver an escalation.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# ask

`/ask` is the captain's opt-in to the question picker.
Without it, decisions reach him as plain text under `AGENTS.md` section 9, and nothing here changes that default or what gets escalated; it changes only how his open decisions are presented once he asks for them this way.

The picker is dangerous in two ways, and the second is the worse one.
Opening it ends this turn, and supervision of the whole fleet halts until he answers, not just the decision on screen; a picker opened just before the captain stepped away once left five lanes idle for ten hours.
Opening a SECOND picker call in the same invocation wedges the supervisor outright, so it stops processing messages at all.
That consequence is the captain's own account and is authoritative here.

So `/ask` buys exactly one picker call, not one question at a time: batch every presentable decision into that single call, record the answers, and stop.
`bin/fm-ask.sh` enforces the mechanical half and refuses the second call; its header owns the refusal codes and the records it keeps.

## 0. Take the helm and check the posture

If no `SESSION START` digest for this home is visible in this session, run `bin/fm-session-start.sh` once and read it first.
A captain typing `/ask` during away mode is an unmarked message, so the `/afk` return owner runs first under `AGENTS.md` section 8, and this skill proceeds only after its catch-up clears.
If `bin/fm-ask.sh inventory` still refuses for the away posture, tell him in one plain sentence that decisions are being held for his return and stop; never open the picker while away.

## 1. Finish everything that does not need him

The picker is the last act of the turn, so anything left undone stays undone until he replies.
Before presenting anything:

- Drain and handle every queued wake, then run its acknowledgement; `present` refuses while any wake is still queued.
- Settle every entry under `WAITING ON FIRSTMATE, NOT THE CAPTAIN` in the inventory: a worker decision that is firstmate's own is decided under `ask-user-authority` and answered now, never laundered into a captain question.
- Dispatch dispatchable queued work, send steers that do not depend on his answer, and leave exactly one live supervision cycle armed per the emitted protocol.

## 2. Build the inventory from durable records

Run `bin/fm-ask.sh inventory`; it is also what marks this new invocation, so run it once at the start of every `/ask`.
Its `CAPTAIN CALLS` are the live tasks held for the captain, and only those can be presented.
A decision stated to him in prose this session and still unanswered, or a worker decision that `ask-user-authority` genuinely escalates, is first held through `captain-hold-lifecycle`; hold a worker's keyed decision under that same key so one answer closes both records.
A decision he has already answered in his own words is closed whatever its record says: record his words through `bin/fm-captain-hold.sh answer` and never ask him twice.
If the inventory still reports an earlier presentation whose answer is not recorded, record that answer first, or run `bin/fm-ask.sh dismissed <id>...` when he gave none.

That inventory, as it stands when he types `/ask`, is the whole of what this invocation may present.
A call that opens later in the turn waits for his next `/ask`; it never earns a picker of its own.
With an argument (`/ask <topic>`), present only the calls that match it and say in one line how many others were left for later.
When nothing is left to present, say so in one plain sentence and stop; never manufacture a question.

## 3. Present every call that fits, in ONE picker call

Order the calls by impact, and say once that the order is firstmate's judgement rather than a score.
Run `bin/fm-ask.sh present <id>...` once, naming every call you are about to ask, immediately before opening the picker; when it refuses, act on its message and open nothing.
Then open the picker exactly once, carrying every one of those calls as questions in that single call.
The picker holds at most four questions, so when more calls are live, present the four most impactful.
Give each question what any escalation carries under `AGENTS.md` section 9: the decision in his nouns, why it matters, the options, and a recommendation with its reason, listed first and marked recommended.
Offer only options firstmate can carry out, and say what happens if he declines to choose when that is not obvious.

Everything that did not fit goes to him in plain text in the same turn, with one line telling him he can type `/ask` again for another round.

These two numbers are the contract `bin/fm-ask.sh` enforces and `tests/fm-ask.test.sh` holds the two sides to, so neither can drift:

```json ask-presentation-contract-v1
{
  "picker_calls_per_invocation": 1,
  "questions_per_picker_call_max": 4
}
```

## 4. Record every answer, then stop opening pickers

Record each answer at answer time through its owner, before anything else:

- `bin/fm-captain-hold.sh answer <id>` with his exact words, adding `--release` when the answer lets held work proceed.
- `bin/fm-send.sh <task> --resolve-key <id> '<answer>'` when the call gates a worker, which closes the worker's decision and the held task in one act.
- "Later" is an answer too: re-hold with `--until`, as `captain-hold-lifecycle` describes.

Then act on those answers where that needs no further input from him, such as steering the workers they unblock, and resume supervision under the emitted protocol.

Do not open the picker again in this invocation.
Recording the answers does not buy another call, and neither does a follow-up, a complication, or a re-ask; those reach him in plain text like everything else, and he types `/ask` himself when he wants another round.
If an answer turns out to rest on something he did not know, say so in prose and let him reply in words.
If he closed the picker without answering, run `bin/fm-ask.sh dismissed <id>...` naming every call you presented; anything he typed instead is an ordinary captain message.
