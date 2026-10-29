#!/usr/bin/env bash
# Live driver: real Claude Code worker in an isolated fm-lab-* Herdr session,
# real fm-watch.sh inbox_steer_check (the watcher's per-poll steering check)
# from <bin-root>, against a disposable lab FM_HOME.
#
# Usage: drive-steer-idle-rering.sh <repo-root-for-lab-helper> <bin-root-under-test> <label> <transcript-out>
set -u
ROOT=$1 BIN=$2 LABEL=$3 OUT=$4
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name "steer-$LABEL")
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-steer-live.XXXXXX")
LAB="$TMP/home"
WORK="$TMP/work"; mkdir -p "$WORK"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
exec > >(tee "$OUT") 2>&1
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

cleanup() {
  trap - EXIT
  log "teardown: $SESSION"
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || log "teardown reported failure"
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2; exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { log "lab home create failed"; exit 1; }
STATE="$LAB/state"
"$LAB_HELPER" provision "$SESSION" >/dev/null || { log "provision failed"; exit 1; }
export HERDR_SESSION="$SESSION"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

log "code under test: $BIN ($LABEL)  herdr=$(herdr --version)  claude=$(claude --version 2>/dev/null | head -1)"
WS=$(lab workspace create --cwd "$WORK" --label fm-steerlive --no-focus) || { log "ws create failed"; exit 1; }
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"
INBOX="$STATE/t1.inbox"
lab pane run "$PANE" "export FM_TASK_INBOX='$INBOX'; CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null

idle=0; trusted=0; i=0
while [ $i -lt 90 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*)
      st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$st" in idle|done) idle=1; break ;; esac ;;
    *'Yes, I trust this folder'*)
      [ $trusted = 1 ] || { trusted=1; lab pane send-keys "$PANE" down enter >/dev/null; } ;;
  esac
  i=$((i+1)); sleep 1
done
[ $idle = 1 ] || { log "claude never reached idle composer"; exit 1; }
log "claude idle in lab pane $TARGET"

# The task record a spawn would have written for this worker.
printf 'window=%s\nbackend=herdr\nkind=ship\nharness=claude\nendpoint_task_id=t1\n' "$TARGET" > "$STATE/t1.meta"

status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // "?"'; }

# 1. Put the worker mid-turn.
lab pane send-text "$PANE" "Without using any tools, write a long, detailed essay (at least 1500 words) on the history of lighthouses, then stop." >/dev/null
sleep 0.5; lab pane send-keys "$PANE" enter >/dev/null
i=0; while [ $i -lt 30 ] && [ "$(status)" != working ]; do sleep 1; i=$((i+1)); done
log "worker native status after prompt: $(status)"

# 2. Firstmate sends a durable steer while the worker is mid-turn.
TOKEN="STEERACK$RANDOM$RANDOM"
REC=$(env -u FM_STATE_OVERRIDE FM_HOME="$LAB" bash -c '. "$1/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 "$3"' _ "$BIN" "$STATE" \
  "Reply with exactly $TOKEN, then move this message file into the handled/ directory next to it.")
touch -t 202001010000 "$REC"
log "steer written while busy: $REC (token $TOKEN)"

poll() {
  env PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$LAB" HERDR_SESSION="$SESSION" \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_BUSY_MAX=2 \
    bash -c '. "$1/fm-watch.sh" && inbox_steer_check "$2" t1' _ "$BIN" "$TARGET" >/dev/null 2>&1
}

rang_at=; idle_at=; acked_at=; n=0
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 240 ]; do
  n=$((n+1))
  st=$(status)
  if [ -z "$idle_at" ] && { [ "$st" = idle ] || [ "$st" = done ]; }; then idle_at=$(date +%H:%M:%S); fi
  poll
  wakes=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || echo 0)
  esc=$(tr '\t' '|' < "$INBOX/.escalated" 2>/dev/null || echo -)
  scr=$(lab pane read "$PANE" --source recent --lines 300 2>/dev/null || true)
  bell=no; case "$scr" in *'Firstmate instruction waiting'*) bell=yes; [ -n "$rang_at" ] || rang_at=$(date +%H:%M:%S) ;; esac
  handled=no; [ -f "$REC" ] || handled=yes
  log "poll $n: worker=$st wakes=$wakes escalated=[$esc] doorbell-in-pane=$bell steer-handled=$handled"
  if [ $handled = yes ]; then acked_at=$(date +%H:%M:%S); break; fi
  if [ -n "$idle_at" ] && [ -z "$rang_at" ] && [ $(( $(date +%s) - start )) -gt 200 ]; then break; fi
  sleep 3
done

log "---- wake queue ----"; cat "$STATE/.wake-queue" 2>/dev/null || log "(empty)"
log "---- final pane tail ----"
lab pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -v '^\s*$' | tail -25
log "SUMMARY label=$LABEL worker-idle-first-seen=${idle_at:-never} doorbell-first-seen=${rang_at:-never} steer-handled=${acked_at:-never} token-in-pane=$(lab pane read "$PANE" --source recent --lines 300 2>/dev/null | grep -c "$TOKEN")"
