# Upgrading from 1.10

What changes for an application that runs 1.10 today, and the order to do
things in. Nothing here needs a change in a worker.

## Before you deploy

1. **Encryption.** Nothing to set. With a key configured this release writes
   what 1.10 writes (`v1`) and reads both formats, so 1.10 nodes can run beside
   it and a rollback to 1.10 loses nothing. The stronger `v2` format is opt-in,
   after the upgrade: step 6.
2. **Workers.** Set `workers` to the list of your worker, batch callback and
   cron worker modules. It is optional in 1.x and will be required in 2.0.
3. **Settings are checked.** Every setting is checked before anything starts,
   and the application does not start with one it cannot run with: a value of
   the wrong type (`poll_interval` as a string), an interval or timeout that is
   zero or negative, an encryption key that is not 32 bytes, an unknown
   `encryption_write_format`, `encryption_read_formats` or
   `on_dependency_failure`, a `workers` that is not a list of modules, an
   `instance` outside `[a-z0-9_]{1,32}`, or a `propagator` that is not a
   module implementing `shigoto_propagator`. The reason always has one shape,
   `{shigoto_config, {invalid, Setting, Value}}`. In 1.10 such a setting failed
   later, at a timer or in a statement.

## Deploy

4. **Migration.** `shigoto_migration:up/1` runs on boot as before and takes
   the schema to version 7: a partial index for claiming replaces the old one,
   two small partial indexes are added, and `shigoto_jobs` gets the nullable
   column `on_dependency_failure`. It builds the indexes with the jobs table
   locked, so no node claims or inserts until it is done: unnoticed on a small
   table, minutes on one of many millions of rows. For such a table, build the
   three indexes with `CREATE INDEX CONCURRENTLY` before you deploy; the
   statements, and the lock each step takes, are in `shigoto_migration:up/1`.
   The migration then finds them and only changes the catalog. A concurrent
   build that failed leaves an invalid index: the migration answers
   `{error, {invalid_index, Names}}`, changes nothing, and the node starts with
   its queues held back until you drop and rebuild it. 1.10 nodes keep working
   against a version 7 schema, so nodes can be upgraded one at a time.
5. **Database role.** Run the migration as the role that owns the tables. See
   [Security](security.md#the-database-role).

## After every node is upgraded

6. With a key configured, set `{encryption_write_format, v2}` on every node,
   once every node runs this release and you will not roll back to 1.10. See
   [Encryption](encryption.md#upgrading-encryption) for what `v2` adds and why
   it must wait.
7. Run `shigoto:reencrypt()` once. It rewrites jobs, archived jobs and batches
   as `v2`, encrypts what was stored in the clear, replaces every
   `unique_key` with the HMAC under the current key, and gives every waiting
   job the list of jobs it waits for (`_shigoto_deps` in its `meta`). It is
   safe while queues run and can be run again.
8. When it reports `failed => 0` and `skipped => 0`, set
   `{encryption_read_formats, [v2]}` and `{require_encrypted, true}`.
9. Only then remove an old key from `encryption_keys`.

The steps for encryption are described in full in
[Encryption](encryption.md#upgrading-encryption).

## What behaves differently

Running a job:

| | 1.10 | Now |
|---|---|---|
| A failed job with attempts left | stayed `retryable` and never ran again | runs again when its backoff is over. A retry now really happens, so `perform/1` has to be safe to run twice |
| A job whose node died (stale) | put back whatever its attempt count; a job that kills its node ran for ever | put back, or discarded at `max_attempts` like a failed last attempt (`on_discard/2` runs); `errors` gain a `rescued` entry |
| A run whose job was rescued, claimed again or cancelled meanwhile | wrote its outcome over the newer state | writes nothing; `shigoto_job_transition_lost` is logged and `[shigoto, job, lost]` emitted |
| Cancelling a job that is running | the process running `perform/1` carried on to the end | it is stopped (`shutdown`, `kill` after 5 seconds), on whichever node runs it, within one `heartbeat_interval` |
| A job still running when `shutdown_timeout` is over | cut off with its row left `executing`; the rescue put it back and the attempt was used | stopped and given back: `available`, without using an attempt |
| Jobs running while the node shuts down | the heartbeat stopped first, so another node could rescue and rerun a job still running here | the heartbeat runs until the executors have stopped |
| A job naming a module that is not a worker on the node that claims it | crashed the executor, was rescued, ran again | put back for 30 seconds without using an attempt, `unrunnable_snooze_limit` (20) times in a row; then fails with `{unknown_worker,<<"name">>}`, retried, discarded. See [Workers](workers.md#a-job-whose-worker-is-missing) |
| `perform/1` returning something other than `ok`, `{ok, _}`, `{error, _}`, `{snooze, _}` | crashed the executor | fails the attempt |
| A worker with `rate_limit/0` or `concurrency/0` when seki is not running | ran ungated | does not run; the job is snoozed, and after `unrunnable_snooze_limit` (20) snoozes in a row its attempt fails with `gate_failed` |
| `on_discard/2` | ran in the process that discarded the job (an executor, a queue's rescue, the caller of `cancel/1`), for as long as it took | runs in a process of its own, for at most `on_discard_timeout` (60000 ms), 10 at a time. See [Workers](workers.md#on_discard-callback) |
| A fanout job | the first node to finish wrote the outcome to the row, and the nodes after it never saw the job | no node writes the row; every node runs it |
| The stale-job rescue and the sweeps | run by every queue of every node | run by one process per node, one node at a time, every `rescue_interval` |
| The seki limiter, bulkhead and breaker of a worker | named by the atoms `shigoto_rl_<worker>`, `shigoto_bh_<worker>` and `shigoto_cb_<worker>` | named `{shigoto_limiter, Worker}`, `{shigoto_bulkhead, Worker}` and `{shigoto_breaker, Worker}`, which is the `name` in seki's telemetry. Needs seki 0.6. A `rate_limit/0` on `seki_backend_pg` gossips under the new name: until every node is upgraded, old and new nodes count on their own |

What is recorded:

| | 1.10 | Now |
|---|---|---|
| `errors` with an encryption key | the reason as raised, with its values | the shape of the reason; see [Security](security.md#what-is-recorded-about-a-failure) |
| `{error, {Tag, X}}` returned from `perform/1` | recorded as `Tag:X`, like an exception | recorded as the term, `{Tag,X}`, also for `{error, {error, X}}`; only what was raised is `Class:Reason` |
| `errors` of a job that was put back | | has an entry per time, with `snoozed`; an entry without it is a failed attempt |
| `errors` | grew without a bound | the 50 newest entries, 1024 bytes per reason |
| A row whose `worker` is longer than a module name can be (1020 bytes) | written whole to every `errors` entry, log report and event | refused without being looked up; `errors`, logs and events hold its first 255 bytes |
| Archiving | copied, then deleted: a job that finished in between was deleted without a copy | one statement deletes and archives |

Inserting:

| | 1.10 | Now |
|---|---|---|
| `insert_all/1,2` | answered, and inserted, the jobs in reverse | in the order given |
| `insert_all/1,2` with a unique worker | inserted duplicates | inserts each unique job once, in one transaction; a duplicate is answered as the job already there. Pass `unique => false` to insert duplicates |
| A unique insert that finds a job which finishes meanwhile | wrote `replace` or `debounce` to the finished job and answered `{ok, {conflict, Job}}`; the new args never ran | inserts the new job |
| `depends_on` a job that has already finished | waited for ever | not waited for; its result is in `deps_results` |
| `depends_on` jobs that depend on one another | refused as a cycle | accepted |
| A job with `batch` for a fanout queue | inserted; the batch never finished | refused: `{error, {fanout_job_in_batch, Queue}}` |
| A unique insert with an encryption key | sent only the HMAC of the unique fields, and did not find a job stored before the key was configured | also finds such a job, by sending the unique fields in the clear, but only while one is stored: checked when the application starts and after `shigoto:reencrypt()`. See [Encryption](encryption.md#unique-jobs) for what a rollout that turns encryption on node by node does not deduplicate |
| Advisory locks | waited without a bound | at most `advisory_lock_timeout` (5000 ms); a unique insert can answer `{error, {lock_timeout, unique}}` |
| `insert_all/1,2` with more unique jobs than `unique_lock_limit` (1000) allows locks for | | refused: `{error, {too_many_unique_locks, Needed, Limit}}`. Split the list. See [Unique Jobs](uniqueness.md#opting-out-and-bulk-inserts) |
| A unique insert PostgreSQL refuses | raised `transaction_rolled_back` | answers `{error, {pgsql_error, _}}` with the code |

Dependencies and batches:

| | 1.10 | Now |
|---|---|---|
| A dependency that is discarded or cancelled | its dependents ran; after `cancel_by/1` they waited for ever | each dependent runs, is cancelled or is discarded, by `on_dependency_failure` (default `run`), whichever way the dependency ended |
| Retrying a job that was cancelled or discarded for a failed dependency | | it waits on that dependency again, and follows it again if it is still failed. See [Job Dependencies](dependencies.md#retrying) |
| The `meta` of a job with `depends_on`, with an encryption key | as given | also holds `_shigoto_deps`, the ids it was inserted to wait for. With `require_encrypted` and `v2`, a job without that list is handed no result and fails with `decrypt_failed`: run `shigoto:reencrypt()` first (step 7), which adds it |
| A cancelled job in a batch | held the batch open | counts as ended; the callback gets `_batch_event => discard` |
| Retrying a discarded job of a batch | the batch could finish one job early | the job is counted again when it ends |
| A batch finished on a node that cannot run its callback | could be left `callback_*` with no callback job | stays `active` until a node that can run the callback settles it. See [Batches](batches.md#a-callback-a-node-cannot-run) |

The API:

| | 1.10 | Now |
|---|---|---|
| `shigoto:cancel/1` on a job that cannot be cancelled | `ok`, and a `cancelled` event | `ok`, and no event |
| `shigoto_repo:claim_jobs/3`, `claim_jobs_fair/3` with an encryption key | answered the jobs decrypted | answer the rows as stored, still encrypted; only the run decrypts |
| `shigoto_repo:complete_job/3`, `fail_job/4`, `snooze_job/3` | wrote by job id, whatever had become of the job since it was claimed | given the claimed job, write only while its claim holds, and answer `{error, lost}` otherwise |
| `shigoto_crypto:decrypt/1` of a frame that does not open | answered the ciphertext | raises `{shigoto_crypto, decrypt_failed}` |
| The same key twice in `encryption_keys` | accepted | the application does not start |
| A setting shigoto cannot use | failed where it was used, each in its own way | the application does not start: `{shigoto_config, {invalid, Setting, Value}}` (step 3) |
| `{require_encrypted, true}` without an encryption key | started, stored and ran plaintext | the application does not start: `{shigoto_config, {invalid, require_encrypted, no_encryption_key}}` |
| `require_encrypted` or `instance` changed to something invalid while the application runs | read as `false`, and as no instance | `require_encrypted` is on unless it is `false`; an invalid `instance` raises `{shigoto_config, {invalid, instance, Value}}` where it is read |

## New, and off until you use it

- `encryption_write_format` `v2`: steps 6 to 9.
- `on_dependency_failure`, per job or as a setting. See
  [Job Dependencies](dependencies.md).
- `instance`, for two installations in one database.
- `propagator`, to carry a trace from insert to run. See
  [Context Propagation](context-propagation.md).
- `[shigoto, job, start]`, `[shigoto, job, stop]`, `[shigoto, job, exception]`
  and `[shigoto, job, lost | rescued | transition_failed]` telemetry events.

New settings with a default: `on_discard_timeout` (60000),
`unrunnable_snooze_limit` (20), `rescue_interval` (60000),
`advisory_lock_timeout` (5000), `unique_lock_limit` (1000),
`notify_min_interval` (10). They are described
in [Getting Started](getting-started.md).

## Connection poolers

Nothing changes here: shigoto ran behind PgBouncer in transaction mode before
and does now. The conditions are written down in
[Getting Started](getting-started.md#connection-poolers).
