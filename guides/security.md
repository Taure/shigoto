# Security

What shigoto protects, against whom, and what it leaves to you.

## Who is assumed to do what

| Someone who can | Must not be able to | How |
|---|---|---|
| read the jobs table, a backup or a replica | read job data | [Encryption](encryption.md) of `args`, `meta`, `result`, `deps_results`, batch `callback_args`, cron `args` |
| write to the jobs table, without the key | have shigoto decrypt a value for them, or run code that is not a worker | values are bound to their column and worker; the worker is checked before anything is decrypted |
| connect to the database at all | stall or flood the queue | every advisory lock is taken with a bound; notifications are rate limited |
| read the logs, telemetry or the `errors` column | read job data | failures are recorded by shape, not by value |

Someone who holds the encryption key, or runs code on a shigoto node, is
trusted. So is the code of your workers.

## The worker is checked first

A row names its worker as text. Before a row is decrypted, the name must be:

1. an atom that already exists on the node (a name is never turned into a new
   atom),
2. in `workers`, when that option is set,
3. a module that exports `perform/1`.

A row that fails is failed with `{unknown_worker,<<"name">>}`. Its args are not
decrypted and nothing in the module is called. The check is remembered per
name: a known worker costs one ETS read and one `erlang:function_exported/3`
per job.

A module name has at most 255 characters, 1020 bytes. A longer name is refused
without being looked up, and `errors`, the log and the events hold its first
255 bytes: the name is copied into every `errors` entry, so the row's own text
would otherwise be written 50 times over. The entry a rescue or a failed
dependency adds is built by PostgreSQL, which keeps the first 255 characters
of the name.

Set `workers` in production. It is optional in 1.x and will be required in
2.0. Without it every loaded module that exports `perform/1` can be run by
whoever can insert a row:

```erlang
{shigoto, [
    {workers, [my_app_email_worker, my_app_report_worker]}
]}.
```

With the list, a module outside it is not even loaded. Batch callback workers
and cron workers go through the same check, so list them too.

## What a moved ciphertext does

In the `v2` format, which is written once `encryption_write_format` is set to
`v2`, a ciphertext is bound to the column it was written to and to the worker
its row names. A job's result is bound to
the id of the job that produced it, and a job is handed only the results of
the jobs it was inserted to wait for: their ids are kept in its `meta`, under
`_shigoto_deps`, which is sealed for its worker.

| Moved from | To | Outcome |
|---|---|---|
| `args` of worker A | `args` of worker B | job fails, `decrypt_failed` |
| `args` | `meta`, `result`, `callback_args` | fails, `decrypt_failed` |
| `result` of job 1 | `deps_results` entry for job 2 | the waiting job fails, `decrypt_failed` |
| `result` of job 1 | `deps_results` entry for job 1, in a job that did not wait for job 1 | fails, `decrypt_failed`, with `require_encrypted` set. Without it the row can leave the list out and the result **opens** |
| `result` of job 1 | `deps_results` entry for job 1, with the `meta` of a job of the same worker that did wait for job 1 | **opens**: that worker was to read it |
| `args` of worker A | `args` of another job of worker A | **opens**: worker A runs again with args it was given before |

The rows that open are the limit of the binding: a value is not bound to its
row. The id of a job is not known when its args are encrypted, and binding to
it would cost a second statement per insert. Make workers idempotent, which
at-least-once delivery asks for anyway.

The list of jobs a job waited for only holds once `require_encrypted` is set.
Until then a row without the list is accepted, because a job inserted by 1.10,
or before a key was configured, has none, and because plaintext `meta` can say
anything. `shigoto:reencrypt/0,1` gives every waiting job its list, so setting
`require_encrypted` after it loses no job. A worker that sends its
`deps_results` on (an email, a webhook) is where a copied result would
surface: set `require_encrypted`.

A key of `deps_results` names a job only when it is the id as PostgreSQL
writes it: `5`, never `05`, `+5` or ` 5`. Under any other key the waiting
job fails with `decrypt_failed`, `shigoto:reencrypt/0,1` counts the value as
`failed`, and the job is not put on the list.

A v1 ciphertext, written by 1.10 and by this release until
`encryption_write_format` is set to `v2`, is bound to nothing: none of the
rows above fail for it. `v1` is the default because a 1.10 node cannot read
`v2`. Set `v2` once every node runs this release and none will go back to
1.10; a 1.10 node that claims a `v2` job fails it, and after `max_attempts` the
job is discarded. See [Upgrading encryption](encryption.md#upgrading-encryption).

A value that does not open never reaches a worker. The job fails with one of
`decrypt_failed`, `format_refused` or `plaintext_refused`, retries like any
other failure, and is discarded when it is out of attempts.

## What is recorded about a failure

The `errors` column, log events and telemetry metadata are not encrypted. With
an encryption key configured they carry the shape of a failure and none of its
values:

- A stack frame keeps module, function, arity, file and line. The argument
  list of a `function_clause` or `undef` frame becomes its length.
- A reason keeps its atoms. Every other term becomes `'_'`:
  `{http_error, 503, <<"body">>}` is recorded as `{http_error,'_','_'}`.
- An error that embeds the value it failed on keeps its tag only:
  `{badmatch, V}` is recorded as `badmatch`.

That goes for the `Reason` of `{error, Reason}` returned from `perform/1` as
well. Return an atom, or a tuple of atoms, for what you want to read later.

What `perform/1` raised is recorded as `Class:Reason`, with a `stacktrace`. What
it returned is recorded as the term: `{error, {error, quota}}` gives
`{error,quota}` and no stacktrace, not `error:quota`.

Without a key the reason is recorded as it is; the args are in the clear in the
same row. Stack frames lose their arguments either way.

Bounds, with or without a key: 1024 bytes per reason, 16 frames and 4096
bytes per stack, the 50 newest entries per job.

Log events and telemetry metadata carry the job's id, worker, queue, attempt
and priority, never its args, meta or result. The one exception is the carrier
a [propagator](context-propagation.md) put in `meta`, which the `start`, `stop`
and `exception` events carry: keep secrets out of it.

## Advisory locks

shigoto takes PostgreSQL advisory locks for unique inserts, global concurrency,
the cron and stager passes, and migrations. Advisory locks belong to the whole
database: any role that can connect can take any of them and hold it for as
long as its session lives. shigoto cannot prevent that. What it does:

- It never waits without a bound. A lock is tried, and tried again for at most
  `advisory_lock_timeout` (default 5000 ms).
- The outcome is explicit. A unique insert answers
  `{error, {lock_timeout, unique}}`. A job whose global concurrency lock is
  held is snoozed and `[shigoto, resilience, gate_failed]` is emitted. A cron
  or stager pass is skipped until the next one. A migration answers
  `{error, lock_timeout}`.
- No gate fails open. If the concurrency check cannot be made, the job does
  not run.
- One call takes a bounded number of them. The locks of every session share
  one table in PostgreSQL (`max_locks_per_transaction * max_connections`
  entries, 6400 by default), and a session that fills it makes the others
  fail with `out of shared memory`. A single insert takes a handful.
  `insert_all/1,2` takes at most `unique_lock_limit` for its unique jobs
  (default 1000) and refuses a longer list with
  `{error, {too_many_unique_locks, Needed, Limit}}`. Do not hand it a list
  whose length a user chooses without splitting it.

With `instance` set, the lock keys and the notification channel are derived
from that name, so two installations in one database do not share them:

```erlang
{shigoto, [{instance, <<"billing">>}]}.
```

Set it on every node at the same time. A node with an instance and one without
do not exclude each other, and a node without one does not hear the other's
insert notifications (it still polls). The channel name is part of the insert
trigger function, which `shigoto_migration:up/1` replaces when the configured
channel differs; that takes the role that owns the function.

## Notifications

Any role that can connect can `NOTIFY` on shigoto's channel. A notification
only names a queue: it is never trusted for more than "poll this queue".
Names that are not a configured queue are dropped, and a queue is woken at
most once per `notify_min_interval` (default 10 ms), with one more poll at the
end of a burst.

## The database role

Give the application its own role, and give nothing else access to the
shigoto tables:

```sql
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CONNECT ON DATABASE my_app FROM PUBLIC;
GRANT CONNECT ON DATABASE my_app TO my_app;
GRANT USAGE ON SCHEMA public TO my_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON
    shigoto_jobs, shigoto_jobs_archive, shigoto_batches, shigoto_cron
    TO my_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO my_app;
```

Run migrations as the role that owns the tables, not as the application role.
A role that only reads (reporting, a dashboard replica) needs `SELECT` and
sees ciphertext.

## Configuration is checked at boot

The application does not start with a key that is not 32 bytes, a key listed
twice, an unknown `encryption_write_format` or `encryption_read_formats`, a
`workers` that is not a list of atoms, an `instance` that is not lower-case
letters, digits and `_`, `require_encrypted` without a key, a `notifier`
minato would not connect with (`ssl_options` without `ssl => true`, which
would not be encrypted), or any other setting it cannot run with. The error is
`{shigoto_config, {invalid, Setting, Value}}`. It names the setting and never
contains a key: a key is described by its position in the list and what is
wrong with it.

With a key configured, `shigoto_plaintext_jobs_accepted` is logged once per
boot while `require_encrypted` is not set, and `shigoto_workers_not_listed`
while `workers` is not set.

A setting changed while the application runs (`application:set_env/3`, a
release upgrade) is not checked again, so the two that guard something are
read to fail closed. `require_encrypted` is on unless it is exactly `false`.
An `instance` that is not a valid name raises
`{shigoto_config, {invalid, instance, Value}}` wherever it is read (a lock,
the stager, the migration, which answers it as `{error, _}`): it is never
taken for no instance. On that node a unique insert then raises in its
caller, and the passes that take a lock (rescue, cron, staging) fail and are
tried again until the value is valid; the node stays up. Change `instance`
in the configuration and restart the node.

## Options

| Option | Default | |
|---|---|---|
| `workers` | `undefined` | Modules that may run as workers. `undefined` allows every module that exports `perform/1`. Optional in 1.x, required from 2.0: set it now |
| `encryption_write_format` | `v1` | `v1` is what 1.10 writes and reads. `v2` binds ciphertexts and also encrypts results and batch callback args, and 1.10 cannot read it: set it once every node runs this release and none will be rolled back, or the 1.10 nodes fail those jobs and in the end discard them. Planned to become the default in a later release |
| `encryption_read_formats` | `[v1, v2]` | Frames that are opened. Drop `v1` once `shigoto:reencrypt/0` has rewritten everything |
| `require_encrypted` | `false` | Refuse to run a job whose args or meta are plaintext (and, in `v2`, to hand on a plaintext result). Needs a key: with `true` and no key the application does not start (`{invalid, require_encrypted, no_encryption_key}`) |
| `instance` | `undefined` | Name of this installation, for its own locks and notification channel |
| `advisory_lock_timeout` | `5000` | Milliseconds to wait for an advisory lock |
| `unique_lock_limit` | `1000` | Advisory locks one `insert_all/1,2` call may take for its unique jobs, at most 5000 |
| `notify_min_interval` | `10` | Minimum milliseconds between polls caused by notifications, per queue |

## What is not protected

- `worker`, `queue`, `priority`, `state`, `tags`, `partition_key`, timestamps,
  dependency ids and cron `name` and `schedule` are stored in the clear. Do
  not put secrets in tags or partition keys.
- `errors` is in the clear, with the limits above.
- `unique_key` is an HMAC of the unique fields when a key is configured, and
  the fields themselves otherwise. A key stored before encryption was turned
  on stays in the clear until `shigoto:reencrypt/0` replaces it. While one is
  stored, and `require_encrypted` is not set, a unique insert sends the
  unique fields to PostgreSQL as a query parameter to find such jobs, where
  statement logging can record them; with none stored it sends HMACs only
  (see [Unique jobs](encryption.md#unique-jobs)).
- Do not remove an old key from `encryption_keys` before
  `shigoto:reencrypt/0` reports `failed => 0` and `skipped => 0`.
- With `encryption_write_format` `v1`, the default: `result`, `deps_results`
  and batch `callback_args` are in the clear, and a ciphertext can be moved
  between rows and columns.
- Someone who can write to the table can still delete jobs, change their
  state, schedule or priority, and replay a job's args to the same worker.
- Job data is plaintext in the memory of the node while a job runs.
