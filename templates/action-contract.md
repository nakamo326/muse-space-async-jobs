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

Also keep a `meta` table with one row in the production DB only:
`env = 'prod'`, `instance_id = <UUID generated once at production setup>`.
Its presence is the environment marker (see Emit).

## Actions (every transition is compare-and-swap)

- `createJob(request_id, payload)` → inserts with status draft or queued.
  On a duplicate `request_id`, return the existing job instead of inserting.
  If the initial status is queued, emit after the insert commits.
- `listJobs(status)` / `getJob(id)` → read-only, used by the worker sweep.
- `claim(id, token)` → one conditional update:
  `UPDATE jobs SET status='claimed', claimed_by=:token, claimed_at=now, attempts=attempts+1 WHERE id=:id AND status='queued'`.
  Return success only when exactly one row changed.
- `complete(id, token, result_ref)` → same shape with
  `WHERE status='claimed' AND claimed_by=:token`, setting status done and result_ref.
- `fail(id, token, reason)` → same WHERE as complete, setting status failed and last_error.
- `cancel(id)` → `WHERE status IN ('draft','queued')`. For a claimed job either
  refuse, or set `cancel_requested=true` if the job type defines that flow.
  Decide per job type and write the choice down.
- `reset(id, expected_token)` → manual recovery with
  `WHERE status='claimed' AND claimed_by=:expected_token`, back to queued,
  and emit inside the same action.
- `requeue(id)` → failed → queued by explicit user action, and emit inside
  the same action.
- `markDelivered(id)` → sets `delivered_at` after the chat delivery.

Claim atomicity, in order of preference:
1. A single conditional UPDATE, judging success by the changed-row count
   (Drizzle and similar ORMs can express this; verify the count is readable).
2. If the DB API is synchronous and the server is a single process, a
   read-check-write with no `await` between read and write.
3. Otherwise rely on the worker lock and document that user cancel can race.

## Emit (inside the Space server code)

```ts
// After the DB write has completed (awaited). Never before it.
async function emitSignal(jobId: string, src: "producer" | "worker" | "reconciler", hop = 0) {
  try {
    const meta = await readMetaRow(); // null in sandbox copies of the DB
    const env = meta?.instance_id ?? "sandbox";
    const path = meta
      ? "/home/hatch/hooks/state/<producer>-signal.jsonl"
      : "/home/hatch/hooks/state/<producer>-signal.test.jsonl";
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
    await privilegedAppendLine(path, line); // one single write of the whole line
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
