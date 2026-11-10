#!/usr/bin/env bash
# Template: signal-file dispatcher hook for the Space Async Jobs pattern.
# Replace the __PLACEHOLDER__ values, save as ~/hooks/scripts/<producer>-signal.sh,
# and register it as a hook with the worker prompt from worker-prompt.md.
#
# Guarantees this script provides:
# - at most one wake per poll, with no signal values inside the wake payload
# - seen is keyed on event_id (UUID), never on job_id
# - a trailing line without a final newline is ignored (may be mid-write)
# - while a fresh worker lock exists, it stays silent WITHOUT consuming seen
# - on any read/parse failure it stays silent rather than waking spuriously
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

PRODUCER="__PRODUCER__"              # ^[a-z0-9-]+$
INSTANCE_ID="__INSTANCE_ID__"        # UUID stored in the production DB meta row
LOCK_TTL_SECS="__LOCK_TTL_SECS__"    # > longest expected worker batch, e.g. 3600

STATE_DIR="$HOME/hooks/state"
SIGNAL="$STATE_DIR/$PRODUCER-signal.jsonl"
SEEN="$STATE_DIR/$PRODUCER-seen.txt"
LOCK="$STATE_DIR/$PRODUCER-worker.lock"
HEARTBEAT="$STATE_DIR/$PRODUCER-hook.heartbeat"
mkdir -p "$STATE_DIR"
touch "$SEEN"

# Heartbeat on every real poll so the reconciler can detect a dead hook.
if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
  date +%s > "$HEARTBEAT"
fi

if [ ! -s "$SIGNAL" ]; then
  silent "no signal file or empty" '{}'
fi

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
if [ -n "$(tail -c 1 "$SIGNAL")" ]; then
  complete="$(head -n -1 "$SIGNAL" || true)"
else
  complete="$(cat "$SIGNAL")"
fi
if [ -z "$complete" ]; then
  silent "no complete signal lines" '{}'
fi

# Strictly validate each line and extract event_ids of valid lines only.
# A line must be one JSON object with v=1, event="queued", env=INSTANCE_ID,
# an event_id in UUID form and a job_id matching ^[A-Za-z0-9_-]{1,64}$.
valid_ids="$(printf '%s\n' "$complete" | jq -Rr --arg inst "$INSTANCE_ID" '
  (fromjson? // empty)
  | select(type == "object")
  | select(.v == 1 and .event == "queued" and .env == $inst)
  | select(.event_id | type == "string"
      and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
  | select(.job_id | type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))
  | .event_id
' 2>/dev/null | awk '!seen[$0]++' || true)"
if [ -z "$valid_ids" ]; then
  silent "no valid signal lines" '{}'
fi

new_ids=""
while IFS= read -r id; do
  if ! grep -Fxq "$id" "$SEEN"; then
    new_ids="${new_ids}${id}
"
  fi
done <<EOF
$valid_ids
EOF
if [ -z "$new_ids" ]; then
  silent "no new events" '{}'
fi

if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
  printf '%s' "$new_ids" >> "$SEEN"
fi
log "new async job signal" '{}'
# The payload deliberately carries no signal values. The worker sweeps the
# store for queued jobs, so values would only add an injection surface.
wake "new async jobs queued" '{}'
