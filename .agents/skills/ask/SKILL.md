---
name: ask
description: >-
  Present the captain's open decisions through the interactive question picker, one at a time, most impactful first, only when the captain explicitly invokes /ask.
  Plain text stays the default way decisions reach the captain; never load this skill on your own initiative or to deliver an escalation.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# ask

`/ask` is the captain's opt-in to the question picker.
Without it, decisions reach him as plain text under `AGENTS.md` section 9, and nothing here changes that default or what gets escalated; it changes only how his open decisions are presented once he asks for them this way.

The picker is dangerous in one specific way: opening it ends this turn, and supervision of the whole fleet halts until he answers, not just the decision on screen.
A picker opened just before the captain stepped away once left five lanes idle for ten hours.
Every step below exists to keep that from recurring, and `bin/fm-ask.sh` enforces the mechanical half; its header owns the refusal codes and the record it keeps.

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

Run `bin/fm-ask.sh inventory`.
Its `CAPTAIN CALLS` are the live tasks held for the captain, and only those can be presented.
A decision stated to him in prose this session and still unanswered, or a worker decision that `ask-user-authority` genuinely escalates, is first held through `captain-hold-lifecycle`; hold a worker's keyed decision under that same key so one answer closes both records.
A decision he has already answered in his own words is closed whatever its record says: record his words through `bin/fm-captain-hold.sh answer` and never ask him twice.
If the inventory still reports an earlier presentation whose answer is not recorded, record that answer first, or run `bin/fm-ask.sh dismissed <id>` when he gave none.

With an argument (`/ask <topic>`), present only the calls that match it and say in one line how many others were left for later.
When nothing is left to present, say so in one plain sentence and stop; never manufacture a question.

## 3. Present one decision at a time

Order the calls by impact, and say once that the order is firstmate's judgement rather than a score.
For each call, run `bin/fm-ask.sh present <id>` immediately before opening the picker; when it refuses, act on its message and open nothing.
Put exactly one question in the picker.
Give it what any escalation carries under `AGENTS.md` section 9: the decision in his nouns, why it matters, the options, and a recommendation with its reason, listed first and marked recommended.
Offer only options firstmate can carry out, and say what happens if he declines to choose when that is not obvious.

## 4. Record each answer before the next

Record the answer at answer time through its owner, before anything else:

- `bin/fm-captain-hold.sh answer <id>` with his exact words, adding `--release` when the answer lets held work proceed.
- `bin/fm-send.sh <task> --resolve-key <id> '<answer>'` when the call gates a worker, which closes the worker's decision and the held task in one act.
- "Later" is an answer too: re-hold with `--until`, as `captain-hold-lifecycle` describes.

Then act on the answer where that needs no further input from him, such as steering the worker it unblocks, and only then present the next call.
If he closed the picker without answering, run `bin/fm-ask.sh dismissed <id>` and stop presenting; anything he typed instead is an ordinary captain message.
When the last call is answered, resume supervision under the emitted protocol.
