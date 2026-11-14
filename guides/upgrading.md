# Upgrading from 1.10

What changes for an application that runs 1.10 today, and the order to do
things in. Nothing here needs a change in a worker.

## Before you deploy

1. **Encryption, rolling deploy.** If a key is configured and 1.10 nodes will
   run beside the new release for a while, set
   `{encryption_write_format, v1}` in the configuration the new release is
   deployed with. The default is now `v2`, which 1.10 cannot read: a 1.10 node
   that claims a `v2` job passes the stored string to `perform/1` instead of
   the args, and the attempt fails. Stopping every node and upgrading them
   together needs no setting.
2. **Workers.** Set `workers` to the list of your worker, batch callback and
   cron worker modules. It is optional in 1.x and will be required in 2.0.
3. **Settings are checked.** The application does not start with an
   encryption key that is not 32 bytes, an unknown `encryption_write_format`
   or `encryption_read_formats`, a `workers` that is not a list of modules, an
   `instance` outside `[a-z0-9_]{1,32}`, or a `propagator` that is not a
   module implementing `shigoto_propagator`. A setting of the wrong type
   (`poll_interval` as a string, say) raises `{shigoto_config, {invalid,
   Setting, Value}}` where it is read, instead of failing at a timer.

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

6. Remove `{encryption_write_format, v1}` if you set it in step 1.
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
| A job naming a module that is not a worker | crashed the executor, was rescued, ran again | fails with `{unknown_worker,<<"name">>}`, retried, then discarded |
| `perform/1` returning something other than `ok`, `{ok, _}`, `{error, _}`, `{snooze, _}` | crashed the executor | fails the attempt |
| `errors` with an encryption key | the reason as raised, with its values | the shape of the reason; see [Security](security.md#what-is-recorded-about-a-failure) |
| A dependency that is discarded or cancelled | its dependents ran; after `cancel_by/1` they waited for ever | each dependent runs, is cancelled or is discarded, by `on_dependency_failure` (default `run`), whichever way the dependency ended |
| A cancelled job in a batch | held the batch open | counts as ended; the callback gets `_batch_event => discard` |
| Retrying a discarded job of a batch | the batch could finish one job early | the job is counted again when it ends |
| `shigoto:cancel/1` on a job that cannot be cancelled | `ok`, and a `cancelled` event | `ok`, and no event |
| `insert_all/1,2` with a unique worker | inserted duplicates | inserts each unique job once, in one transaction; a duplicate is answered as the job already there. Pass `unique => false` to insert duplicates |
| A worker with `rate_limit/0` or `concurrency/0` when seki is not running | ran ungated | does not run; the job is snoozed |
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
