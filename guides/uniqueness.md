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
  job's `unique_key` column.
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

1. Builds the `unique_key` with `build_unique_key/4`.
2. Derives a lock key with `erlang:phash2(UniqueKey)`.
3. Opens a `pgo:transaction/2` and takes a **Postgres advisory transaction
   lock**: `SELECT pg_advisory_xact_lock($1)`. This serialises concurrent
   inserts that hash to the same key; the lock is released automatically when
   the transaction commits or rolls back.
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
