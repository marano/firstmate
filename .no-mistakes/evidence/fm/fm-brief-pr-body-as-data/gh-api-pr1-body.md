## What changed

Generated briefs now teach a worker how to read stored text back **as data**, so a rendered view is never used to recover a PR body.

Rule 3 in both scaffold variants (ship and scout) previously said only "Use gh-axi for GitHub operations". It now additionally names the data-mode read as the one explicit exception to that routing rule, with the reason stated in a single clause, and names both lossy surfaces by name.

## Why

On 15 Sep 2026 a worker rebuilt bluejam-platform PR 331's description from `gh-axi pr view --full` output and ran `body.encode().decode('unicode_escape')` to undo the renderer's escaping. That decode reads UTF-8 bytes as Latin-1, so all 39 status markers the validation pipeline had written cleanly were destroyed in one step and shipped live.

The cause was established by evidence, not inference: the pipeline wrote the body clean (the worker's own pre-edit capture has all 39 markers intact), a different PR through the same pipeline kept all 44 of its markers, and the only clean sections in the corrupted body were the ones typed fresh in a heredoc — clean where hand-written, mangled where round-tripped.

The instruction that pointed the worker at a renderer was rule 3 itself, which never said that a tool's rendered output is a display surface rather than a data format.

Review additionally caught that naming `gh api` without naming the exception left rule 3 self-contradictory: a worker resolving the conflict in gh-axi's favour has a discoverable native path, `pr list --fields body`, which returns the body as a single escaped line that *reads* like data — and unescaping it is precisely the step that corrupted PR 331. Both lossy surfaces are now named.

## Scope

Deliberately narrow: the ask was the instruction, not enforcement. No validation step, linter, wrapper, or checking machinery was added.

A sibling instance of the same round-trip pattern exists for backlog task bodies (`docs/architecture.md`, the stow skill) and is **not** covered here — it was ruled out of scope for this PR and filed separately, since a mangled task body is home-local and cannot reach a PR description through that path.

## Test Plan

- [x] `tests/fm-brief.test.sh` extended to assert the new wording in **both** generated variants — passes.
- [x] Generated a ship brief and a scout brief and confirmed the new rule 3 appears in the rendered output of each, not merely in the source diff.
- [x] `fm-lint` green.
- [x] Pipeline review, test, document and lint steps green.
- [x] Both scaffold variants verified in step with each other — a fix to one and not the other is the defect this repo hit once before.

### Not automated - for the reviewer to assert

- [ ] That the wording reads clearly to a worker encountering it cold, and is tight enough at its current length.

