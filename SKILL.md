# Space Async Jobs

## Decide whether the pattern fits

- Use this pattern when a Space (fullstack web artifact) must trigger agent work from a data change, such as an order, a submission or an approval, and the work itself lives outside the Space in the agent environment.

- Check first that the job cannot simply run inside a synchronous action in a few seconds, because the pattern adds a queue, a dispatcher and a worker to maintain.

- Rule the pattern out when the job needs latency of a few seconds, exactly-once external side effects such as payments or posts, or high volume, and say so plainly instead of building it.

- Verify with a tiny test action that the Space server code can write a file outside its own directory, for example under `~/hooks/state/`, before designing anything else, because the whole signal route depends on that one fact.

## Hold the core principles

- Treat the signal as a hint and the Space DB as the only truth, so a lost, duplicated or forged signal can never cause real damage by itself.

- Treat the claim as the lock, and check the lock owner on every later transition with a per-run worker token.

- Design for at-least-once delivery, where waking twice is expected and harmless, instead of trying to prevent the second wake.

- Never retry a failed job automatically, because a human requeue after reading the failure reason is what keeps a broken job from looping forever.

## Design the job store and its actions

- Give the job table the standard statuses draft, queued, claimed, done, failed and cancelled, and map domain display names to them in one table instead of inventing new status names per Space.

- Store the fields status, claimed_at, claimed_by, attempts, last_error, result_ref, delivered_at, cancel_requested and updated_at on every job row from the start.

- Add a unique client-generated request_id to job creation, so a double click or a resend after an error cannot register the same job twice.

- Make every status transition a compare-and-swap that writes only when the current status matches the expected one and returns whether it wrote, following the contract in [templates/action-contract.md](templates/action-contract.md).

- Emit a signal inside every action that moves a job into queued, including manual requeue and reset, or the job will sit still until the next unrelated job or the reconciler arrives.

## Emit and read the signal

- Append one JSON line per event with the fields v, event_id, job_id, env, src, hop, ts and event, where event stays the single value queued in this version.

- Generate a fresh event_id with `crypto.randomUUID()` on every emit and key the dispatcher's seen record on event_id, never on the job id, because job ids are only unique inside one DB and collide across sandbox and production copies.

- Write each line as one single write of the stringified JSON plus a newline, wrapped so a failed emit never fails the action itself, and let the reconciler recover the job later.

- Put the production DB instance_id in the env field, read from a meta row that only the production DB carries, and have the dispatcher ignore lines whose env does not match its configured instance.

- Keep job content, instructions, personal data, file paths and credentials out of the signal, because the worker re-reads everything from the store anyway and anything in the signal is an injection surface.

## Dispatch with a hook

- Build the dispatcher from [templates/hook-script.sh](templates/hook-script.sh), a bash polling hook under `~/hooks/scripts/` with its state under `~/hooks/state/`, and dry-run it for both the silent and the wake outcome before enabling it.

- Cap the hook at one wake per poll no matter how many new events arrived, and pass no signal values inside the wake payload.

- Parse each signal line strictly, drop lines that fail the field patterns, and ignore a trailing line that does not end with a newline because it may still be mid-write.

- Skip the wake while a fresh worker lock exists and leave the seen record untouched in that case, so pending events are picked up after the running worker finishes.

- Have the hook write a heartbeat file on every poll, so the reconciler can tell a dead hook apart from a quiet queue.

## Write the worker instructions

- Write the worker prompt from [templates/worker-prompt.md](templates/worker-prompt.md) and fix it inside the hook definition, never in the signal.

- Make the worker sweep the store for every queued job on each wake instead of trusting the payload ids, oldest first, up to a per-run cap set by how heavy one job is.

- Make the worker create the worker lock at start, refresh it per job and delete it at the end, and generate its worker token once per run for the claim calls.

- Fail a job whose payload cannot be read or validated before claiming, instead of leaving it queued where it blocks the head of the queue on every sweep.

- Count attempts as successful claims, and move jobs at three or more attempts out of the sweep into a report, so one poison job cannot consume the queue.

- Deliver in the order complete with result_ref, then deliver to the chat, then record delivered_at, and stop the delivery when complete fails because the job no longer belongs to this worker.

- Allow a self-continuation signal only as an opt-in, only when the run moved at least one job out of queued, with hop incremented and capped, and as the worker's last action.

## Add the reconciler by tier

- Decide the tier before building, where tier A means a user waits for the result or a lost job causes real harm, and tier B means an experiment where a stuck job is acceptable.

- Give every tier A queue a reconciler from [templates/reconciler-prompt.md](templates/reconciler-prompt.md) on a slow cron, and write down for tier B that nobody will notice a stuck job.

- Make the reconciler process stale queued jobs itself, report only claimed jobs stuck beyond twice the expected processing time and done jobs missing delivered_at, and stay silent when nothing is wrong.

- Suppress repeat reports of the same stuck job until its status or updated_at changes, and check the hook heartbeat before reporting a stall.

## Verify before enabling, and recover when stuck

- Run the full checklist in [templates/verification-checklist.md](templates/verification-checklist.md), including the duplicate signal, lost signal, cancel race and sandbox contamination cases, before calling the queue live.

- Run the three measurement tests in that checklist at least once per environment, covering claim atomicity under parallel calls, wake multiplicity of the hook runtime and the sandbox versus production difference visible to Space code.

- Recover a stuck queue with the runbook in the checklist, stopping the hook, cleaning test lines from the signal, resetting the seen record, restarting the hook and letting the sweep recover real jobs from the store.

- Record known gaps honestly when an existing implementation does not meet the contract yet, as the café reference implementation still uses an unconditional status update instead of CAS, instead of claiming the standard is already met.

## Available connectors

- Use `muse.connector_search` to find other connectors and `muse.skill_search` to find related skills.

- If nothing here fits, look on the web for a maintained API or MCP server and set it up with [Custom Connectors and MCPs](/opt/muse/skills/custom-connector-setup/SKILL.md), or build a custom connector.
