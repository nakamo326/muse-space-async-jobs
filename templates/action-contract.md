# Action contract and emit template (Space side)

The Space owns the job store. All reads and writes go through actions.
Replace `<Job>` and the field names with the domain's, keeping the semantics.

## Job row

| Field | Meaning |
|---|---|
| `id` | Store-local id. Display number and internal identity stay separate. |
| `request_id` | Client-generated id, UNIQUE. Makes creation idempotent. |
| `status` | draft / queued / claimed / done / failed / cancelled |
| `claimed_at`, `claimed_by` | When the claim happened, and the worker token holding it. |
| `attempts` | Count of successful claims. |
| `last_error` | Reason passed to `fail`, shown to the user. |
| `result_ref` | Link, file id or summary of the deliverable, set by `complete`. |
| `delivered_at` | When the worker actually delivered the result to the chat. |
| `cancel_requested` | Set when a cancel arrives while claimed (if the job type allows it). |
| `updated_at` | Touched on every transition. The reconciler keys on it. |

Also keep a `meta` table with one row, created at production setup:
`env = 'prod'`, `instance_id = <UUID generated once at production setup>`.
Its presence is the environment marker (see Emit) — but only if sandbox
copies of the DB do not carry the row. A sandbox that is a full data copy
of production carries the same `instance_id`, and then this marker does
not separate anything. Verify which case you are in (checklist A10);
if the copy carries the row, strip it in sandbox copies or give the
sandbox its own `instance_id`.

## Actions (every transition is compare-and-swap)

- `createJob(request_id, payload)` → inserts with status draft or queued.
  On a duplicate `request_id`, return the existing job instead of inserting.
  If the initial status is queued, emit after the insert commits.
- `submit(id)` → draft → queued with `WHERE id=:id AND status='draft'`,
  and emit inside the same action. A draft job has no other path to queued.
- `listJobs(status)` / `getJob(id)` → read-only, used by the worker sweep.
- `claim(id, token)` → one conditional update:
  `UPDATE jobs SET status='claimed', claimed_by=:token, claimed_at=now, attempts=attempts+1, updated_at=now WHERE id=:id AND status='queued'`.
  Return success only when exactly one row changed.
- `complete(id, token, result_ref)` → same shape with
  `WHERE status='claimed' AND claimed_by=:token`, setting status done,
  result_ref and `updated_at=now`.
- `fail(id, token, reason)` → same WHERE as complete, setting status failed,
  last_error and `updated_at=now`.
- `rejectInvalid(id, reason)` → the fail path for a job that was never
  claimed (unreadable or invalid payload found during the sweep):
  `WHERE status='queued'`, setting status failed, last_error and
  `updated_at=now`. This is a CAS like every other transition; never write
  an unconditional status update to work around a missing path.
- `cancel(id)` → `WHERE status IN ('draft','queued')`. For a claimed job either
  refuse, or set `cancel_requested=true` if the job type defines that flow.
  Decide per job type and write the choice down. Where the flow exists, the
  worker checks `cancel_requested` before completing and, if set, calls
  `cancelClaimed(id, token)` instead:
  `WHERE status='claimed' AND claimed_by=:token AND cancel_requested=true`,
  setting status cancelled and `updated_at=now`, and does not deliver.
- `reset(id, expected_token)` → manual recovery with
  `WHERE status='claimed' AND claimed_by=:expected_token`, back to queued.
  Clears `claimed_by` and `claimed_at`; keeps `attempts` and `last_error`
  (a reset is an unlock, not a retry grant, so a repeatedly dying job
  still walks into the attempts cap). Emits inside the same action.
- `requeue(id)` → failed → queued by explicit user action, with
  `WHERE status='failed'`. Sets `attempts=0` and clears `claimed_by`,
  `claimed_at` and `last_error`: a human requeue after fixing the cause
  must always become a processing target again. Emits inside the
  same action.
- `markDelivered(id)` → sets `delivered_at` and `updated_at=now` with
  `WHERE status='done' AND delivered_at IS NULL`, after the chat delivery.

Claim atomicity, in order of preference:
1. A single conditional UPDATE, judging success by the changed-row count
   (Drizzle and similar ORMs can express this; verify the count is readable).
2. If the DB API is synchronous and the server is a single process, a
   read-check-write with no `await` between read and write.
3. Otherwise rely on the worker lock and document that user cancel can race.
   With this option the reconciler must take and respect the same worker
   lock while it processes recovered jobs (see reconciler-prompt.md),
   or the worker and the reconciler can process the same job twice.

## Emit (inside the Space server code)

```ts
// After the DB write has completed (awaited). Never before it.
async function emitSignal(jobId: string, src: "producer" | "worker" | "reconciler", hop = 0) {
  try {
    // readMetaRow: a read of the meta table described above. It returns
    // null in sandbox copies ONLY if the copy carries no meta row —
    // verify that (checklist A10); a full data copy carries the row.
    const meta = await readMetaRow();
    const env = meta?.instance_id ?? "sandbox";
    // Absolute path under the agent account's home (server code cannot
    // rely on "~" expansion); replace <home> with the real home directory.
    const path = meta
      ? "<home>/hooks/state/<producer>-signal.jsonl"
      : "<home>/hooks/state/<producer>-signal.test.jsonl";
    const line = JSON.stringify({
      v: 1,
      event_id: crypto.randomUUID(),
      job_id: String(jobId),
      env,
      src,
      hop,
      ts: new Date().toISOString(),
      event: "queued",
    }) + "\n";
    // appendLine: the file-append call that the preflight (SKILL.md,
    // step 1) verified can write outside the Space's own directory.
    // One single write of the whole line.
    await appendLine(path, line);
  } catch {
    // Swallow. The DB is the source of truth; the reconciler recovers the job.
    // Never surface an emit failure as an action error: the user would resend
    // and double-register the job.
  }
}
```

Rules:

- One emit per transition into queued, from inside the same action.
- One single write per line. Never split a line across writes, never stream it.
- If `crypto.randomUUID()` is unavailable, fall back to
  `` `${Date.now()}-${randomHex(8)}` `` from a crypto random source.
  Never fall back to a composite of env, producer and job id: in a sandbox
  copy the env value is the same constant, so the key collides exactly like
  the incident this pattern learned from.
