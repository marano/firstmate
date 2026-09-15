## Summary

Prevent a readable shell endpoint from reusing a stale `working` status after its agent exits, while preserving terminal and blocked states.
Escalate active routed replies when their confirmed endpoint has stopped.

## What Changed

- `bin/fm-crew-state.sh` reconciles tmux and Herdr endpoint state before the status-log fallback, so `dead` and `missing` endpoints cannot make stale progress look current.
- `bin/fm-pending-reply-lib.sh` detects stopped endpoints and emits one durable `pending-reply-agent-stopped` escalation for active routed replies.
- `docs/architecture.md` and `docs/secondmate-parent-channel.md` document the endpoint-reconciliation boundary.
- `tests/fm-crew-state.test.sh` and `tests/fm-pending-reply.test.sh` cover shell-only endpoints, preserved terminal and blocked states, healthy endpoints, and stopped-endpoint reply escalation.

## Risk Assessment

✅ Low: The change is narrowly scoped, reuses the existing recovery-grade endpoint classifier, and preserves conservative handling for ambiguous, unreadable, and unverified endpoint states.

## Verification

- `bin/fm-test-run.sh tests/fm-crew-state.test.sh tests/fm-pending-reply.test.sh` - both focused behavior suites passed.
- Live tmux validation was skipped because tmux is unavailable in this environment.
- The no-mistakes validation completed with a live-check override because GitHub reported no checks for this pull request.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"5b081c6ea251bfa819346c5fd658dd31408ab3c8","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"skipped"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->

