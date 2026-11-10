# Verification checklist and recovery runbook

Run all of section A before a queue goes live. Run section B at least once
per environment (they measure the runtime, not the Space). Section C is the
runbook for a stuck queue.

## A. Go-live checks

1. **External write preflight**: a test action in the real Space writes one
   line outside its own directory (for example under `~/hooks/state/`) and
   the line is verified on disk. Inside-only writes do not count.
2. **Hook dry-run, both outcomes**: with no signal the dry-run is silent;
   with a test signal it wakes; and the dry-run does not consume the seen
   record (the same signal still wakes on the first real poll).
3. **End to end with a dummy job**: create, queue, and watch the job move
   queued → claimed → done with delivered_at set, with no human message in
   between. Delete the dummy afterwards.
4. **Duplicate signal**: append the same event line twice, and emit two
   different events for the same job. The job is processed exactly once
   and delivered exactly once (on the second wake the job is no longer
   queued, so it is skipped, or its claim fails).
5. **Lost signal**: queue a job with the signal file deleted or the emit
   forced to fail. The reconciler (tier A) or the next wake's sweep
   recovers it, and the recovery is visible in the report.
6. **Cancel race**: cancel a queued job while its signal is still pending.
   The worker sweeps, sees it is not queued, and skips it. Then cancel a
   claimed job and confirm the defined behavior (refusal or
   cancel_requested) actually happens.
7. **Stuck claimed**: claim a job with a test token and walk away. The
   reconciler reports it after the threshold and does not reset it itself.
8. **Sandbox non-contamination**: run the builder's sandbox verification,
   then diff the production signal file, seen record and lock before and
   after. They must be unchanged. Sandbox writes must land on the `.test`
   signal path or nowhere.
9. **Poison job**: queue a job with an unreadable payload ahead of a good
   job. The broken one lands in failed with a reason, the good one still
   gets processed in the same run.
10. **Sandbox meta check**: from the sandbox, `readMetaRow()` must return
    null, or the sandbox emit must resolve to the `.test` signal path.
    If the sandbox DB is a data copy that carries the production meta
    row, the instance_id marker does not separate the environments:
    strip the meta row in sandbox copies (or give the sandbox its own
    instance_id) and re-run check 8 before trusting the marker.

## B. One-time measurement tests (runtime facts, about 15 minutes each)

1. **Claim atomicity**: against a test action on the sandbox DB with emit
   disabled, fire 20 parallel claim calls for the same job. Exactly one
   must succeed. If more than one succeeds, the claim is read-then-write
   and the contract falls back to the worker lock (and that limitation
   gets written into the Space's design note).
2. **Wake multiplicity**: use a dummy hook whose worker writes a start
   timestamp, waits 120 seconds, then writes an end timestamp. Append a
   signal at t=0 and another at t=45s and check whether the runs overlap.
   Then append 5 lines at once and count the wakes. Record the result,
   because the lock and one-wake-per-poll rules assume specific behavior.
3. **Environment difference**: a one-off debug action returns only the
   NAMES of environment variables, the cwd and the DB path (never values,
   which may contain secrets), once from the sandbox and once from
   production. Record any usable difference. If there is none, the DB
   meta-row (instance_id) marker is the environment check — which is
   fine only when check A10 holds (the sandbox copy carries no meta
   row). If A10 fails, the marker separates nothing and must be fixed
   there first.

## C. Recovery runbook (stuck queue)

Symptoms: jobs sit in queued and nothing wakes, or the seen record is
suspected of containing foreign ids (the sandbox-contamination incident
shape).

1. Disable the hook so no new wakes fire during the repair.
2. Inspect the signal file. Remove only lines that are demonstrably test
   data (wrong env/instance, sandbox timestamps, ids the store has never
   issued). Keep real lines. Note that with event_id-keyed seen and the
   env filter, foreign test lines are dropped by the hook and harmless:
   removing them is cleanup, not an emergency measure, so never delete
   lines in a hurry.
3. Reset the seen record to empty. This is safe because seen is only a
   delivery hint: the worst case is one extra wake, and the sweep plus
   claim sort out what is real.
4. Delete a stale worker lock if its timestamp is older than the TTL and
   no worker is actually running.
5. Re-enable the hook. The next wake sweeps the store and recovers every
   genuinely queued job. Claimed leftovers still need a token-checked
   manual reset each; never bulk-edit the store behind the actions.
6. Note the incident in the Space's design note: what polluted what, and
   which layer caught it. That note is the pattern's evidence base.
7. Rotate the signal and seen files when they grow large (both are
   scanned on every poll): with the hook disabled and no worker lock
   present, and every event_id in the signal file present in the seen
   record, truncate both files to empty. Jobs are unaffected — the
   store is the truth, and any genuinely queued job is recovered by
   the next sweep or the reconciler.
