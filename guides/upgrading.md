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
| `on_discard/2` | ran in the process that discarded the job (an executor, a queue's rescue, the caller of `cancel/1`), for as long as it took | runs in a process of its own, for at most `on_discard_timeout` (60000 ms), 10 at a time, with at most 10000 rows of 64 MB together waiting. See [Workers](workers.md#on_discard-callback) |
| A fanout job | the first node to finish wrote the outcome to the row, and the nodes after it never saw the job | no node writes the row; every node runs it |
| The stale-job rescue and the sweeps | run by every queue of every node | run by one process per node, one node at a time, every `rescue_interval` |
| The seki limiter, bulkhead and breaker of a worker | named by the atoms `shigoto_rl_<worker>`, `shigoto_bh_<worker>` and `shigoto_cb_<worker>` | named `{shigoto_limiter, Worker}`, `{shigoto_bulkhead, Worker}` and `{shigoto_breaker, Worker}`, which is the `name` in seki's telemetry. Needs seki 0.6. A `rate_limit/0` on `seki_backend_pg` gossips under the new name: until every node is upgraded, old and new nodes count on their own, so the cluster as a whole may let through up to twice the limit during the deploy |

What is recorded:

| | 1.10 | Now |
|---|---|---|
| `errors` with an encryption key | the reason as raised, with its values | the shape of the reason; see [Security](security.md#what-is-recorded-about-a-failure) |
| `{error, {Tag, X}}` returned from `perform/1` | recorded as `Tag:X`, like an exception | recorded as the term, `{Tag,X}`, also for `{error, {error, X}}`; only what was raised is `Class:Reason` |
| `errors` of a job that was put back | | has an entry per time, with `snoozed`; an entry without it is a failed attempt |
| `errors` | grew without a bound | the 50 newest entries, 1024 bytes per reason |
| A row whose `worker` is longer than a module name can be (1020 bytes) | written whole to every `errors` entry, log report and event | refused without being looked up; `errors`, logs and events hold its first 255 bytes (255 characters in the entry of a rescue or of a failed dependency) |
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
| A unique insert with an encryption key | sent only the HMAC of the unique fields, and did not find a job stored before the key was configured | also finds such a job, by sending the unique fields in the clear, but only while one is stored: each node checks when it starts, the node that ran `shigoto:reencrypt()` when the run ends, and a node that found one again every `rescue_interval` until none is left. See [Encryption](encryption.md#unique-jobs) for what a rollout that turns encryption on node by node does not deduplicate |
| Advisory locks | waited without a bound | at most `advisory_lock_timeout` (5000 ms); a unique insert can answer `{error, {lock_timeout, unique}}` |
| `insert_all/1,2` with more unique jobs than `unique_lock_limit` (1000) allows locks for | | refused: `{error, {too_many_unique_locks, Needed, Limit}}`. Split the list. See [Unique Jobs](uniqueness.md#opting-out-and-bulk-inserts) |
| A unique insert PostgreSQL refuses | raised `transaction_rolled_back` | answers `{error, {pgsql_error, Fields}}`, cut down as in the next row |
| The reason of an insert PostgreSQL refuses, `{error, {pgsql_error, Fields}}` from `insert/1,2` and `insert_all/1,2` | `Fields` was everything PostgreSQL sent, with `message` and `detail` | `Fields` holds `code`, `constraint`, `severity` and `severity_non_localised` only: `message` and `detail` can quote the refused row, args included. Match on `code` or `constraint` |
| `meta` with a key that starts with `_shigoto` | inserted | refused: `{error, {reserved_key, meta, Key}}`. `_shigoto_carrier` is still accepted, to hand over a context by hand |
| `states` of a `unique` map that are not job states | put into the statement as given; a name that is no state matched nothing, so every insert went in | the insert is refused: `{error, {invalid_unique_states, States}}` |

Dependencies and batches:

| | 1.10 | Now |
|---|---|---|
| A dependency that is discarded or cancelled | its dependents ran; after `cancel_by/1` they waited for ever | each dependent runs, is cancelled or is discarded, by `on_dependency_failure` (default `run`), whichever way the dependency ended |
| Retrying a job that was cancelled or discarded for a failed dependency | | it waits on that dependency again, and follows it again if it is still failed. See [Job Dependencies](dependencies.md#retrying) |
| The `meta` of a job with `depends_on`, with an encryption key | as given | also holds `_shigoto_deps`, the ids it was inserted to wait for. With `require_encrypted` and `v2`, a job without that list is handed no result and fails with `decrypt_failed`: run `shigoto:reencrypt()` first (step 7), which adds it |
| `new_batch/1` with `_batch_event` or a `_shigoto` key in `callback_args` | stored; the callback of a completed batch saw `_batch_event => discard` | refused: `{error, {reserved_key, callback_args, Key}}`. A batch stored that way no longer hands a completed callback the key |
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
| `require_encrypted` or `instance` changed to something invalid while the application runs | read as `false`, and as no instance | `require_encrypted` is on unless it is `false`; an invalid `instance` raises `{shigoto_config, {invalid, instance, Value}}` where it is read: in the caller of a unique insert, and in the rescue, cron and staging passes, which fail until it is valid. See [Security](security.md#configuration-is-checked-at-boot) |

## New, and off until you use it

- `encryption_write_format` `v2`: steps 6 to 9.
- `on_dependency_failure`, per job or as a setting. See
  [Job Dependencies](dependencies.md).
- `instance`, for two installations in one database.
- `propagator`, to carry a trace from insert to run. See
  [Context Propagation](context-propagation.md).
- `[shigoto, job, start]`, `[shigoto, job, stop]`, `[shigoto, job, exception]`
  and `[shigoto, job, lost | rescued | transition_failed]` telemetry events.

New in the log: `shigoto_connection_keys_not_read`, a warning when a pool or
the notifier is started with keys that are no option of a connection (see
[minato 1.2](#minato-1-2)), `shigoto_workers_not_listed`, a warning once per
boot while an encryption key is configured and `workers` is not set, and
`shigoto_raw_unique_check_failed`, a warning when a node cannot find out
whether a unique key is still stored in the clear (see
[Encryption](encryption.md#unique-jobs)).

New settings with a default: `on_discard_timeout` (60000),
`unrunnable_snooze_limit` (20), `rescue_interval` (60000),
`advisory_lock_timeout` (5000), `unique_lock_limit` (1000),
`notify_min_interval` (10). They are described
in [Getting Started](getting-started.md).

## minato 1.2

shigoto needs minato 1.2 or later; 1.10 ran on any 1.x. rebar3 takes one
version of a package for a build, the one asked for nearest the top of the
dependency tree, and does not check it against what the other dependencies ask
for. So look at `rebar.lock` after upgrading: an application that also depends
on a package asking for an older minato (kura_postgres 1.1.9 asks for
`~> 1.1.6`) can be left on that one.

minato 1.2 refuses what 1.1 passed over and ends what 1.1 waited for. Its
[changelog](https://hexdocs.pm/minato/changelog.html) has all of it. This is
what reaches an application through shigoto, in the `notifier` map, in what
`shigoto_db:start_pool/2` is given, and in the statements shigoto runs:

| | minato 1.1 | minato 1.2 |
|---|---|---|
| `ssl_options` without `ssl => true` | ignored, and the connection opened without TLS | refused: `{invalid_option, ssl_options}`. Add `ssl => true`, or take the options out |
| An `ssl` that is not `true` or `false`, such as `"true"` out of the environment | raised in every attempt to connect | refused before anything is started: `{invalid_option, ssl}` |
| `ssl_options` that resume a TLS session (`reuse_sessions` other than `false`, `reuse_session`, `session_tickets` other than `disabled`, `use_ticket`), a `verify` that is neither `verify_peer` nor `verify_none`, or `{handshake, hello}` | handed to `ssl` | refused: `{invalid_option, ssl_options}` |
| `{server_name_indication, disable}` in `ssl_options` | also turned the hostname check off | the certificate is still checked for `host`, and one without it fails the connect: `{tls, {bad_cert, hostname_check_failed}}`. `{verify, verify_none}` is how to turn the check off |
| A pool named `minato_overdue` or `minato_sup` | | refused: `{reserved_name, Name}`. They are minato's own processes |
| A pool to another machine whose options do not mention `ssl` | | minato logs `unencrypted_connection` once when the pool starts. `ssl => false` says it was meant |
| A statement whose answer takes longer than the pool's `timeout` (15 seconds unless the pool was started with another) to arrive whole | read to its end, as long as rows kept coming | cancelled on the server: `{error, {pgsql_error, #{code := ~"57014"}}}`, or `{error, {socket, timeout}}` and a closed connection from a server that goes on sending. What shigoto runs for its queues answers with few rows. `insert_all/1,2` and `cancel_by/1` answer with every job they touched, so a very large call can reach the deadline: split it. A statement of your own through `shigoto_db:query/4` takes a `timeout`, and a pool started with `shigoto_db:start_pool/2` takes one for all of its statements |
| A write the server does not read | waited for ever | fails after the pool's `timeout`: `{error, {socket, timeout}}`, and the connection is closed. `{send_timeout, Ms}` in `socket_options` sets another bound |
| A column no module on the node names: one you added to a shigoto table, or an alias in a statement of your own | keyed by an atom made for it | keyed by its name as a binary. Every column of shigoto's own tables is still an atom |

A refused connection starts nothing. `shigoto_db:start_pool/2` answers
`{error, Reason}` with the reason in the table. The notifier logs
`shigoto_notifier_not_listening` once, with that reason, asks again every
5 seconds, and the queues poll meanwhile, as they do for any listener that
cannot be started.

The `notifier` map and `shigoto_db:start_pool/2` now hand every option of a
minato connection on to it, where 1.10 read `host`, `port`, `database`, `user`,
`password`, `ssl`, `ssl_options` and `socket_options` and left the rest out.
A map that held one of the others all along (`timeout`, `connect_timeout`,
`cancel_timeout`, `auth`, `channel_binding`, `parameters`, `transport`,
`prepared_statements`, `frame_opts`) is opened with it from this release on,
and refused if minato does not take its value: a `timeout` of `"5000"` is
`{invalid_option, timeout}`. They are listed in
[Getting Started](getting-started.md#connection-options).

A key that is none of them, such as `sslmode` or a misspelt `ssl_options`, is
left out as before, and the connection is opened as if it had not been given.
That is now said: each time a pool or a listener is started with such keys,
`shigoto_connection_keys_not_read` is logged as a warning that names them. A
later major release will refuse them. The keys of a kura repo's configuration
are not warned about.

## Connection poolers

Nothing changes here: shigoto ran behind PgBouncer in transaction mode before
and does now. The conditions are written down in
[Getting Started](getting-started.md#connection-poolers).
