# Unique Jobs

Shigoto can deduplicate jobs so that enqueuing "the same" job twice does not
create two rows. Uniqueness is **opt-in** and scoped: it is defined by which job
fields make up the key, which job states count, and an optional time window.

A plain `insert` with no unique options **never** deduplicates. Two identical
`insert` calls produce two independent jobs. Deduplication only happens when you
either pass a `unique` option or the worker exports a `unique/0` callback.

## Configuring Uniqueness

Provide a `unique` map, either per-insert or as a worker default via `unique/0`.
Any keys you omit fall back to `?DEFAULT_UNIQUE` in `shigoto_repo`:

```erlang
#{
    keys => [worker, args],
    states => [available, executing, retryable],
    period => infinity,
    replace => [],
    debounce => undefined
}
```

- **keys** - which fields form the identity of the job. Supported: `worker`,
  `args`, `queue`. The key is built by `build_unique_key/4`: the selected fields
  are sorted, `args` is JSON-encoded, and the parts are joined with `:` into the
  job's `unique_key` column. With an encryption key configured the stored key
  is an HMAC-SHA256 of that string instead, so it carries no arg values (see
  the [Encryption](encryption.md) guide).
- **states** - a new insert only conflicts with an existing job whose `state` is
  in this list. The default covers in-flight work (`available`, `executing`,
  `retryable`) but **not** terminal states, so a `completed`, `discarded`, or
  `cancelled` job never blocks a fresh enqueue.
- **period** - `infinity` (match any existing job in the given states) or a
  number of seconds. With a period, `find_existing_job/3` adds
  `inserted_at >= now() - make_interval(secs => Period)`, so a job older than the
  window no longer blocks a new one.
- **replace** - a list of fields to overwrite on the existing job when a
  conflict is found (`args`, `priority`, `max_attempts`, `scheduled_at`). Empty
  means "keep the existing job untouched".
- **debounce** - seconds; when set, a conflict pushes the existing job's
  `scheduled_at` forward to `now() + debounce`, so a burst of enqueues keeps
  sliding the run time later.

A worker default:

```erlang
-module(sync_worker).
-behaviour(shigoto_worker).
-export([perform/1, unique/0]).

perform(Args) -> do_sync(Args).

unique() ->
    #{keys => [worker, args], period => 300}.
```

When a conflict is detected, the insert returns `{ok, {conflict, Job}}` instead
of `{ok, Job}`, so callers can tell a deduplicated enqueue from a fresh one.

## How It Works

`insert_job/3` calls `resolve_unique/2`. If that returns `none` (no unique opts
and no `unique/0` callback) it goes straight to `do_insert/4` - a plain insert
with no deduplication. Otherwise it calls `insert_unique/4`, which:

1. Builds the `unique_key`s with `unique_keys/4`. With encryption keys
   configured there is one per key, the current key's first, so a job stored
   before a key rotation is still found. While a job from before encryption
   was turned on is still stored (and `require_encrypted` is not set) the
   form in the clear is added, so that job is found as well; see
   [Encryption](encryption.md#unique-jobs). Only the first is ever stored.
2. Derives a lock key with `erlang:phash2/1` from each.
3. Opens a `shigoto_db:transaction/2` (or joins the one already open) and takes a **Postgres advisory transaction
   lock** per key with `pg_try_advisory_xact_lock`, in one statement. This
   serialises concurrent inserts that hash to the same key; the lock is
   released automatically when the transaction commits or rolls back.
4. Calls `find_existing_job/3` to look for a matching job within the configured
   `states` (and `period`, if set).
5. If one exists, `maybe_replace/4` applies the `replace`/`debounce` policy and
   returns `{ok, {conflict, Job}}`. If none exists, it does the real
   `do_insert/4`.

## Why an Advisory Lock, Not a UNIQUE Index

The obvious alternative - a `UNIQUE` index on `unique_key` - is too blunt for
Shigoto's semantics:

- **Uniqueness is state-scoped.** A `completed` job may legitimately share a key
  with a brand-new job you want to run again. A blanket UNIQUE index would reject
  that second insert forever, even though the first job is long finished.
- **Uniqueness is period-scoped.** With `period => 300`, a job from an hour ago
  must not block a new one. A UNIQUE index has no notion of a time window; it
  would keep colliding regardless of age.
- **Replace/debounce need read-then-write.** Overwriting fields or sliding
  `scheduled_at` on the existing job requires finding it first and then updating
  it. A UNIQUE index only gives you insert-or-fail, not the conditional
  find-and-update this policy needs.

The advisory transaction lock gives exactly the guarantee that is needed and no
more: it prevents two concurrent transactions from both seeing "no existing job"
and both inserting, while leaving the actual "is this a duplicate?" decision to a
normal scoped query that respects states and period. It locks a hash of the key
rather than a real row, so it costs nothing when there is no contention and never
leaves a constraint behind that would wrongly block a legitimate future job.

## When the Lock Is Held

Advisory locks are shared by everything that can connect to the database, so
the lock for a key can be held by a session that is not shigoto. The insert
waits for it for at most `advisory_lock_timeout` (default 5000 ms) and then
answers `{error, {lock_timeout, unique}}` with nothing inserted. Treat it like
any other failed insert: retry, or surface it. See [Security](security.md).

## Opting Out and Bulk Inserts

`#{unique => false}` in the options of `insert/2` skips the worker's `unique/0`
for that insert.

`insert_all/1,2` deduplicates as `insert/1,2` does. A list with a unique job in
it is inserted in one transaction: the unique locks of the whole list are taken
first, then the jobs go in, in the order given. A lock that cannot be had
answers `{error, {lock_timeout, unique}}` and nothing is inserted.

The locks are held until the call ends, in a lock table the whole PostgreSQL
server shares, so one call may take `unique_lock_limit` of them: 1000 unless
set, at most 5000. A unique job takes one lock per configured encryption key
(one without a key), and one more while unique keys from before encryption
are still looked for (see [Encryption](encryption.md#unique-jobs)). A call
that needs more answers `{error, {too_many_unique_locks, Needed, Limit}}` and
inserts nothing. Split the list and insert each part with its own call; each
call is then its own all-or-nothing unit. Calls made inside one
`shigoto:transaction/1` keep their locks until it ends, so there they add up:
keep the whole transaction under the limit.

An insert the database refuses is answered, not raised: `{error, Reason}`
with a `{pgsql_error, _}` cut down to its code, and nothing of the call is
kept.

The answer is still `{ok, Jobs}` with one job per job given. Where a job was a
duplicate (of a stored job, or of an earlier one in the same list) its place
holds the job that is already there, so the same id can appear twice, and no
`[shigoto, job, inserted]` is emitted for it. Compare ids if you need to know
which were new.

Each unique job costs a lookup and a statement of its own, so a list of unique
jobs is a few times faster than inserting them one by one, not the single
statement a plain list is. `#{unique => false}` inserts the list as it is.

## Replacing Args

With `replace => [args]`, the new args are stored on the existing row and are
encrypted for that row's worker. When `keys` leaves out `worker`, two workers
can conflict: the existing job keeps its worker and runs with the new args.
