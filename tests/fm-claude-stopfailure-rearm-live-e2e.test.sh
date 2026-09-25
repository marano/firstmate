#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the API-error turn end
# (bin/fm-claude-stop-autoarm.sh --stop-failure, registered on StopFailure).
# Replays the 2026-09-24 overnight stall against the real installed Claude Code
# and the real tracked hook registration: a Stop-owned rewake is delivered, its
# handling turn ends in an API error because the network is cut, Claude runs
# StopFailure instead of Stop, and the StopFailure registration must re-arm and
# wake the idle session again once the network is back. Before the fix nothing
# was registered there, so this session would stay silent until a human typed.
#
# The session runs with streaming input, because a plain -p run exits right
# after the API error without waiting for its StopFailure hook, so no rewake
# could follow; an interactive primary, like a streaming-input one, stays open.
# The network cut is a local CONNECT proxy that drops api.anthropic.com tunnels
# while a flag file exists; the arm fixture sets and clears that flag, so the
# cut lands exactly on the rewake's handling turn.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude python3 jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-stopfailure-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
OUT="$LAB/claude.jsonl"
FIFO="$LAB/in.fifo"
CLAUDE_VERSION=$(claude --version)
PROXY_PID=
CLAUDE_PID=

cleanup() {
  exec 3>&- 2>/dev/null || true
  [ -z "$CLAUDE_PID" ] || kill "$CLAUDE_PID" 2>/dev/null || true
  [ -z "$PROXY_PID" ] || kill "$PROXY_PID" 2>/dev/null || true
  [ -z "$CLAUDE_PID" ] || wait "$CLAUDE_PID" 2>/dev/null || true
  [ -z "$PROXY_PID" ] || wait "$PROXY_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone carries only committed state, so copy the working-tree surfaces
# under test (same pattern as the Stop auto-arm live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# owner, which session start reclaims for this session.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Arm fixture. Run 1 (the Stop after the first reply) cuts the network and
# closes actionable, so the rewake's handling turn fails. Run 2 must come from
# the StopFailure registration: it restores the network and closes actionable
# again. Later runs end the supervision need so the session settles. Every run
# records the API-error streak it saw, which proves which event armed it.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
printf 'arm-run=%s streak=%s\n' "$N" "$(cut -d' ' -f1 "$FM_HOME/state/.claude-autoarm-stopfailure" 2>/dev/null || echo none)" \
  >> "$FM_HOME/state/arm-ran"
case "$N" in
  1) : > "$FM_HOME/state/net-block" ;;
  2) rm -f "$FM_HOME/state/net-block" ;;
  *)
    rm -f "$FM_HOME/state/task.meta"
    printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
    exit 0
    ;;
esac
printf 'pending:downtime:fixture-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-api-error-%s\n' "$N"
exit 0
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh"

cat > "$LAB/proxy.py" <<'PY'
import asyncio, os, sys
PORT_FILE, BLOCK = sys.argv[1], sys.argv[2]
LIVE = set()
async def cut_on_block():
    # A real outage also kills connections already open, so a kept-alive
    # tunnel cannot carry the turn that must fail.
    while True:
        if os.path.exists(BLOCK):
            for w in list(LIVE):
                try:
                    w.close()
                except Exception:
                    pass
            LIVE.clear()
        await asyncio.sleep(0.05)
async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d:
                break
            w.write(d)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass
async def handle(r, w):
    try:
        parts = (await r.readline()).decode(errors="replace").split()
        while (await r.readline()) not in (b"\r\n", b"\n", b""):
            pass
        if len(parts) < 2 or parts[0] != "CONNECT":
            w.close()
            return
        host, port = parts[1].rsplit(":", 1)
        if os.path.exists(BLOCK) and host.endswith("anthropic.com"):
            with open(BLOCK + ".hits", "a") as f:
                f.write(host + "\n")
            w.close()
            return
        ur, uw = await asyncio.open_connection(host, int(port))
        w.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await w.drain()
        if host.endswith("anthropic.com"):
            LIVE.update((w, uw))
        await asyncio.gather(pipe(r, uw), pipe(ur, w))
        LIVE.discard(w)
        LIVE.discard(uw)
    except Exception:
        try:
            w.close()
        except Exception:
            pass
async def main():
    srv = await asyncio.start_server(handle, "127.0.0.1", 0)
    with open(PORT_FILE + ".tmp", "w") as f:
        f.write(str(srv.sockets[0].getsockname()[1]))
    os.rename(PORT_FILE + ".tmp", PORT_FILE)
    asyncio.ensure_future(cut_on_block())
    async with srv:
        await srv.serve_forever()
asyncio.run(main())
PY

python3 "$LAB/proxy.py" "$LAB/proxy.port" "$HOME_DIR/state/net-block" &
PROXY_PID=$!
for _ in $(seq 1 100); do [ -s "$LAB/proxy.port" ] && break; sleep 0.1; done
[ -s "$LAB/proxy.port" ] || fail "the lab network proxy did not start"
PROXY_URL="http://127.0.0.1:$(cat "$LAB/proxy.port")"

mkfifo "$FIFO"
(
  cd "$PROJECT" || exit 1
  exec env FM_HOME="$HOME_DIR" HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" \
    CLAUDE_CODE_MAX_RETRIES=0 FM_CLAUDE_STOPFAILURE_BACKOFF=1 \
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p --input-format stream-json --output-format stream-json --verbose \
      --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' --effort low --strict-mcp-config
) < "$FIFO" > "$OUT" 2>"$LAB/claude.err" &
CLAUDE_PID=$!
exec 3>"$FIFO"

PROMPT='Reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, reply with exactly ACK and stop. Never use any tool.'
jq -cn --arg p "$PROMPT" '{type:"user",message:{role:"user",content:$p}}' >&3

wait_for() {  # <seconds> <description> <command...>
  local seconds=$1 what=$2 i=0
  shift 2
  while [ "$i" -lt "$seconds" ]; do
    "$@" && return 0
    kill -0 "$CLAUDE_PID" 2>/dev/null || fail "claude exited while waiting for $what: $(tail -5 "$LAB/claude.err" "$OUT" 2>/dev/null)"
    sleep 1
    i=$((i + 1))
  done
  fail "timed out after ${seconds}s waiting for $what; arm runs: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null); output tail: $(tail -3 "$OUT")"
}
arm_runs_at_least() { [ "$(cat "$HOME_DIR/state/arm-count" 2>/dev/null || echo 0)" -ge "$1" ]; }
assistant_texts() { jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$OUT" 2>/dev/null; }
replies_with() { assistant_texts | grep -qx "$1"; }
ack_after_api_error() { assistant_texts | awk '/^API Error/ { e = 1 } e && /^ACK$/ { f = 1 } END { exit !f }'; }

wait_for 240 "the Stop-owned arm after the first reply" arm_runs_at_least 1
wait_for 240 "an API-error turn end on the cut network" grep -q '"text":"API Error' "$OUT"
wait_for 240 "the StopFailure-owned re-arm" arm_runs_at_least 2
wait_for 240 "the rewake's ACK after the network returned" ack_after_api_error
settled() { arm_runs_at_least 3 && grep -q 'outcome=clean' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null; }
wait_for 60 "the settling Stop firing to close quietly" settled
# A streaming-input session does not exit on end of input, so stop it once the
# settling Stop firing has run.
exec 3>&-
kill "$CLAUDE_PID" 2>/dev/null || true
wait "$CLAUDE_PID" 2>/dev/null || true
CLAUDE_PID=

replies_with CYCLE0 || fail "the first turn never replied CYCLE0"
[ -s "$HOME_DIR/state/net-block.hits" ] || fail "the network cut never refused an API connection, so no API error was exercised"
[ "$(sed -n '1p' "$HOME_DIR/state/arm-ran")" = 'arm-run=1 streak=none' ] \
  || fail "run 1 must come from an ordinary Stop with no API-error streak: $(cat "$HOME_DIR/state/arm-ran")"
[ "$(sed -n '2p' "$HOME_DIR/state/arm-ran")" = 'arm-run=2 streak=1' ] \
  || fail "run 2 must be armed by the StopFailure registration after one API-error turn end: $(cat "$HOME_DIR/state/arm-ran")"
[ ! -e "$HOME_DIR/state/.claude-autoarm-stopfailure" ] \
  || fail "the completed ACK turn's Stop firing must clear the API-error streak"

# The session transcript orders the proof: the API error, then the
# StopFailure-owned rewake carrying run 2's reason, then the model's ACK.
SESSION_ID=$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$OUT" | head -n 1)
[ -n "$SESSION_ID" ] || fail "no session id in the stream output"
TRANSCRIPT=$(find "$HOME/.claude/projects" -name "$SESSION_ID.jsonl" 2>/dev/null | head -n 1)
[ -n "$TRANSCRIPT" ] || fail "session transcript $SESSION_ID.jsonl not found"
ORDER=$(jq -r '
  if .isApiErrorMessage == true then "api-error"
  elif .type == "user" and ((.message.content | tostring) | contains("stale: fixture-api-error-2")) then "rewake-2"
  elif .type == "assistant" and ((.message.content | tostring) | contains("\"ACK\"")) then "ack"
  else empty end' "$TRANSCRIPT" | tr '\n' ' ')
case "$ORDER" in
  *api-error*rewake-2*ack*) : ;;
  *) fail "expected API error, then the StopFailure rewake, then ACK in the transcript; saw: $ORDER" ;;
esac

printf 'ok - Claude %s live E2E: a rewake whose handling turn hit an API error was re-armed through StopFailure and woke the idle session again\n' "$CLAUDE_VERSION"
