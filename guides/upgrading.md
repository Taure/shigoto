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
   as `v2`, encrypts what was stored in the clear, and replaces every
   `unique_key` with the HMAC under the current key. It is safe while queues
   run and can be run again.
8. When it reports `failed => 0` and `skipped => 0`, set
   `{encryption_read_formats, [v2]}` and `{require_encrypted, true}`.
9. Only then remove an old key from `encryption_keys`.

The steps for encryption are described in full in
[Encryption](encryption.md#upgrading-encryption).

## What behaves differently

| | 1.10 | Now |
|---|---|---|
| A job naming a module that is not a worker on the node that claims it | crashed the executor, was rescued, ran again | put back for 30 seconds without using an attempt, `unrunnable_snooze_limit` (20) times in a row; then fails with `{unknown_worker,<<"name">>}`, retried, discarded. See [Workers](workers.md#a-job-whose-worker-is-missing) |
| `perform/1` returning something other than `ok`, `{ok, _}`, `{error, _}`, `{snooze, _}` | crashed the executor | fails the attempt |
| `errors` with an encryption key | the reason as raised, with its values | the shape of the reason; see [Security](security.md#what-is-recorded-about-a-failure) |
| A dependency that is discarded or cancelled | its dependents ran; after `cancel_by/1` they waited for ever | each dependent runs, is cancelled or is discarded, by `on_dependency_failure` (default `run`), whichever way the dependency ended |
| A cancelled job in a batch | held the batch open | counts as ended; the callback gets `_batch_event => discard` |
| Retrying a discarded job of a batch | the batch could finish one job early | the job is counted again when it ends |
| `shigoto:cancel/1` on a job that cannot be cancelled | `ok`, and a `cancelled` event | `ok`, and no event |
| `insert_all/1,2` with a unique worker | inserted duplicates | inserts each unique job once, in one transaction; a duplicate is answered as the job already there. Pass `unique => false` to insert duplicates |
| A worker with `rate_limit/0` or `concurrency/0` when seki is not running | ran ungated | does not run; the job is snoozed, and after `unrunnable_snooze_limit` (20) snoozes in a row its attempt fails with `gate_failed` |
| `{error, {Tag, X}}` returned from `perform/1` | recorded as `Tag:X`, like an exception | recorded as the term, `{Tag,X}`, also for `{error, {error, X}}`; only what was raised is `Class:Reason` |
| `errors` of a job that was put back | | has an entry per time, with `snoozed`; an entry without it is a failed attempt |
| `shigoto_crypto:decrypt/1` of a frame that does not open | answered the ciphertext | raises `{shigoto_crypto, decrypt_failed}` |
| Advisory locks | waited without a bound | at most `advisory_lock_timeout` (5000 ms); a unique insert can answer `{error, {lock_timeout, unique}}` |

## New, and off until you use it

- `on_dependency_failure`, per job or as a setting. See
  [Job Dependencies](dependencies.md).
- `instance`, for two installations in one database.
- `propagator`, to carry a trace from insert to run. See
  [Context Propagation](context-propagation.md).
- `[shigoto, job, start]`, `[shigoto, job, stop]`, `[shigoto, job, exception]`
  and `[shigoto, job, lost | rescued | transition_failed]` telemetry events.

## Connection poolers

Nothing changes here: shigoto ran behind PgBouncer in transaction mode before
and does now. The conditions are written down in
[Getting Started](getting-started.md#connection-poolers).
