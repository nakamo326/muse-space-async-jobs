#!/usr/bin/env bash
# Template: signal-file dispatcher hook for the Space Async Jobs pattern.
# Replace the __PLACEHOLDER__ values, save as ~/hooks/scripts/<producer>-signal.sh,
# and register it as a hook with the worker prompt from worker-prompt.md.
#
# Runtime contract this script relies on:
# - $HATCH_HOOK_RUNTIME provides the functions silent(), wake() and log().
#   silent and wake print the hook's decision AND END THE SCRIPT; every
#   call site below relies on that. If your runtime's versions do not
#   exit, append "; exit 0" at each call site instead.
# - jq must be installed. The script checks and stays silent without it.
#
# Guarantees this script provides:
# - at most one wake per poll; the wake payload carries no ids or job
#   data, only the max hop scalar (see the wake at the bottom)
# - seen is keyed on event_id (UUID), never on job_id
# - a trailing line without a final newline is ignored (may be mid-write)
# - while a fresh worker lock exists, it stays silent WITHOUT consuming seen
# - on read/parse failures of its own state it stays silent; it never
#   treats unreadable state as "everything is new"
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

PRODUCER="__PRODUCER__"              # ^[a-z0-9-]+$
INSTANCE_ID="__INSTANCE_ID__"        # UUID stored in the production DB meta row
LOCK_TTL_SECS="__LOCK_TTL_SECS__"    # > longest expected worker batch, e.g. 3600

# An unsubstituted placeholder must never run: with a placeholder
# INSTANCE_ID every line fails the env check and the hook stays silent
# forever, with no visible error anywhere.
case "$PRODUCER$INSTANCE_ID$LOCK_TTL_SECS" in
  *__*) silent "template placeholders not replaced" '{}' ;;
esac
command -v jq >/dev/null 2>&1 || silent "jq missing" '{}'

STATE_DIR="$HOME/hooks/state"
SIGNAL="$STATE_DIR/$PRODUCER-signal.jsonl"
SEEN="$STATE_DIR/$PRODUCER-seen.txt"
LOCK="$STATE_DIR/$PRODUCER-worker.lock"
HEARTBEAT="$STATE_DIR/$PRODUCER-hook.heartbeat"
mkdir -p "$STATE_DIR"
touch "$SEEN" || silent "state dir not writable" '{}'

# Heartbeat on every real poll so the reconciler can detect a dead hook.
if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
  date +%s > "$HEARTBEAT" || silent "heartbeat write failed" '{}'
fi

if [ ! -s "$SIGNAL" ]; then
  silent "no signal file or empty" '{}'
fi
[ -r "$SIGNAL" ] || silent "signal file unreadable" '{}'

# Worker already running: stay silent and do NOT consume seen, so the pending
# events are picked up by the first poll after the worker finishes.
if [ -f "$LOCK" ]; then
  lock_ts="$(cat "$LOCK" 2>/dev/null || echo 0)"
  case "$lock_ts" in (*[!0-9]*|"") lock_ts=0 ;; esac
  now="$(date +%s)"
  if [ $(( now - lock_ts )) -lt "$LOCK_TTL_SECS" ]; then
    silent "worker lock fresh" '{}'
  fi
fi

# Drop a trailing partial line (no final newline yet): it may be mid-write.
# Note: a line that stays unterminated forever (a crashed emit) glues itself
# to the next line; both then fail JSON parsing and are dropped. That is a
# lost signal, recovered by the worker sweep or the reconciler like any
# other lost signal — but on a tier B queue it stalls until then.
last_char="$(tail -c 1 "$SIGNAL" 2>/dev/null || true)"
if [ -n "$last_char" ]; then
  complete="$(head -n -1 "$SIGNAL")" || silent "signal read failed" '{}'
else
  complete="$(cat "$SIGNAL")" || silent "signal read failed" '{}'
fi
if [ -z "$complete" ]; then
  silent "no complete signal lines" '{}'
fi

# Strictly validate each line and extract "event_id hop" of valid lines.
# A line must be one JSON object with v=1, event="queued", env=INSTANCE_ID,
# an event_id in UUID form, a job_id matching ^[A-Za-z0-9_-]{1,64}$ and a
# hop that is an integer within the cap (0..20). Lines over the hop cap are
# dropped here, so a self-continuation chain cannot loop forever even if a
# worker misbehaves.
valid_lines="$(printf '%s\n' "$complete" | jq -Rr --arg inst "$INSTANCE_ID" '
  (fromjson? // empty)
  | select(type == "object")
  | select(.v == 1 and .event == "queued" and .env == $inst)
  | select(.event_id | type == "string"
      and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
  | select(.job_id | type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))
  | select(.hop | type == "number" and . == floor and . >= 0 and . <= 20)
  | "\(.event_id) \(.hop)"
' 2>/dev/null | awk '!seen[$0]++' || true)"
if [ -z "$valid_lines" ]; then
  silent "no valid signal lines" '{}'
fi

new_ids=""
max_hop=0
while IFS=' ' read -r id hop; do
  # grep exit codes: 0 = already seen, 1 = new, 2 = error. An unreadable
  # seen file must end the poll silently, never mark everything as new.
  rc=0
  grep -Fxq "$id" "$SEEN" || rc=$?
  if [ "$rc" -eq 2 ]; then
    silent "seen file unreadable" '{}'
  fi
  if [ "$rc" -eq 1 ]; then
    new_ids="${new_ids}${id}
"
    if [ "$hop" -gt "$max_hop" ]; then max_hop="$hop"; fi
  fi
done <<EOF
$valid_lines
EOF
if [ -z "$new_ids" ]; then
  silent "no new events" '{}'
fi

# seen is written BEFORE the wake. If the wake itself fails, the event is
# consumed but nothing is lost: the job is still queued in the store, and
# the next sweep (or the reconciler, tier A) recovers it.
if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
  printf '%s' "$new_ids" >> "$SEEN"
fi
log "new async job signal" '{}'
# The payload deliberately carries no ids or job values: the worker sweeps
# the store for queued jobs, so values would only add an injection surface.
# The one exception is max_hop, a bare counter an opted-in worker needs to
# continue its own chain (it writes max_hop + 1, and this script drops
# lines past the cap).
wake "new async jobs queued" "{\"max_hop\":$max_hop}"
