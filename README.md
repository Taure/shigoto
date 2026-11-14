# Shigoto 仕事

PostgreSQL-backed background job processing for Erlang. If you know [Oban](https://github.com/oban-bg/oban) from Elixir, shigoto fills the same role on a plain Erlang/OTP stack.

Shigoto (仕事, "work") is a feature-rich job queue built on PostgreSQL's `FOR UPDATE SKIP LOCKED` for safe multi-node operation. No Redis or external broker needed — if you have PostgreSQL, you have a job queue.

## Features

### Core
- **PostgreSQL-backed** — Jobs stored in PostgreSQL via [minato](https://hex.pm/packages/minato). With [kura](https://hex.pm/packages/kura), shigoto shares the repo's pool and its transactions, so a job enqueued with your writes commits or rolls back with them.
- **Multi-node safe** — `FOR UPDATE SKIP LOCKED` ensures each job is claimed by exactly one node. No coordination required.
- **Priority queues** — Higher priority jobs are claimed first. Multiple queues with independent concurrency limits.
- **Dynamic queues** — Add and remove queues at runtime without restart.
- **Exponential backoff** — Failed jobs retry with `min(attempt^4 + jitter, 1800)` second delays, or provide a custom `backoff/2` callback.

### Scheduling
- **Cron scheduling** — Built-in 5-field cron parser with leader election via advisory locks. Each minute is scheduled once across nodes, and a run missed in the last hour is caught up after a restart.
- **Scheduled jobs** — Enqueue jobs for future execution with `scheduled_at`.
- **Job snoozing** — Workers can return `{snooze, Seconds}` to reschedule without using up a retry attempt.

### Reliability
- **Job dependencies** — `depends_on` chains ensure jobs execute in order. `on_dependency_failure` decides whether a job runs, is cancelled or is discarded when a job it waits on fails.
- **Batches** — Group jobs with completion callbacks. Batch state tracks completed/discarded counts.
- **Unique jobs** — Prevent duplicates with configurable keys, states, time windows, debounce, and field replacement on conflict.
- **Stale job rescue** — Heartbeat-based detection of zombie jobs. A rescued job runs again, and is discarded once it is out of attempts.
- **Graceful shutdown** — Waits for in-flight jobs to finish before stopping.

### Resilience ([seki](https://github.com/Taure/seki) integration)
- **Rate limiting** — Per-worker token bucket, sliding window, GCRA, or leaky bucket.
- **Circuit breaking** — Auto-opens on repeated failures, configurable per worker.
- **Bulkhead** — Per-worker concurrency limits (local node) and global concurrency limits (across nodes via PostgreSQL).
- **Load shedding** — CoDel-based system-level protection, shedding low-priority jobs first.

### Operations
- **Encryption** — AES-256-GCM for job `args`, `meta`, cron args, results and batch callback args at rest (`encryption_write_format` `v1`, for a rolling upgrade from 1.10, leaves results and callback args in the clear). Key rotation, `shigoto:reencrypt/0`. `errors`, `worker`, `queue` and `tags` are not encrypted; see [Encryption](guides/encryption.md).
- **Hardened against the database** — the worker a row names is checked (optionally against an allow-list) before anything is decrypted or called, failures are recorded without job data, and no advisory lock is waited for without a bound. See [Security](guides/security.md).
- **Middleware** — Composable before/after hooks for logging, metrics, authorization.
- **Telemetry** — 16+ telemetry events covering job lifecycle, queue operations, resilience, batches, and cron.
- **Health check** — `shigoto:health/0` reports pool status, job counts, stale jobs, and queue health.
- **Bulk operations** — `insert_all/1,2`, `cancel_by/2`, `retry_by/2` for batch operations.
- **Auto-archival** — Old jobs archived to `shigoto_jobs_archive` table, then pruned.
- **Dashboard** — [shigoto_board](https://github.com/Taure/shigoto_board) provides a real-time web dashboard.

### Testing
- **DB-free worker runner** — `perform_job/2,3` runs a worker through the real perform path (middleware + `deps_results`) with no database.
- **Enqueue assertions** — `assert_enqueued/1,2`, `refute_enqueued/1`, `all_enqueued/0,1` in `shigoto_testing`.
- **Testing modes** — `inline` (run on insert) / `manual` (capture without running), armed via a two-key confirmation so they can never silently activate in production.
- **Synchronous drain** — `drain_queue/1` processes all jobs synchronously for integration tests.

## Quick Start

Add to your deps:

```erlang
{deps, [
    {shigoto, "~> 1.10"}
]}.
```

Configure in `sys.config`. With kura, name the repo; shigoto runs on the
minato pool `kura_postgres` starts for it. `repo` must equal that pool's name:
the repo module, or the repo's `pool` key when kura's config sets one.

```erlang
{shigoto, [
    {repo, my_app_repo},
    {queues, [{<<"default">>, 10}, {<<"emails">>, 5}]},
    {poll_interval, 5000},
    {cron, [
        {<<"daily_cleanup">>, <<"0 3 * * *">>, my_cleanup_worker, #{}}
    ]}
]}
```

Without kura, start a pool of its own and name it with `pool`:

```erlang
{ok, _} = shigoto_db:start_pool(my_app_jobs, #{
    host => "localhost", database => "my_app", user => "postgres", password => "postgres"
}).
```

`shigoto` creates or updates its tables when it starts, which needs the pool
running and the database there. It tries 5 times; if the schema is still not
current it starts without its queues, logs `shigoto_migration_pending`, retries
every 30 seconds and starts the queues once the migration succeeds (see the
getting-started guide). Meanwhile `shigoto:add_queue/2` answers
`{error, migration_pending}` and `shigoto:health/0` reports
`reason => migration_pending`. To migrate sooner, for instance right after
kura's migrator has created the database, call it yourself and start the queues
at once:

```erlang
ok = shigoto_migration:up(my_app_repo),
_ = shigoto_migrator:retry_now().
```

`retry_now/0` answers `not_running` when nothing is pending.

Define a worker:

```erlang
-module(my_email_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"to">> := To, <<"subject">> := Subject}) ->
    send_email(To, Subject),
    ok.
```

Enqueue jobs:

```erlang
%% Simple insert
shigoto:insert(#{
    worker => my_email_worker,
    args => #{<<"to">> => <<"user@example.com">>, <<"subject">> => <<"Welcome">>}
}).

%% Scheduled for later
shigoto:insert(#{
    worker => my_cleanup_worker,
    scheduled_at => {{2026, 3, 20}, {3, 0, 0}}
}).

%% With priority and queue
shigoto:insert(#{
    worker => my_urgent_worker,
    args => #{},
    priority => 10,
    queue => <<"critical">>
}).
```

## Transactional Enqueue

With `{repo, Repo}`, shigoto and kura share transactions on the repo's pool, in
both directions:

```erlang
%% A job inserted inside a kura transaction commits or rolls back with it.
my_app_repo:transaction(fun() ->
    {ok, User} = my_app_repo:insert(UserChangeset),
    {ok, _Job} = shigoto:insert(#{
        worker => welcome_email_worker,
        args => #{<<"user_id">> => maps:get(id, User)}
    }),
    User
end).

%% kura writes inside shigoto:transaction/1 join it too.
shigoto:transaction(fun() ->
    {ok, User} = my_app_repo:insert(UserChangeset),
    {ok, _Job} = shigoto:insert(#{worker => welcome_email_worker, args => #{}}),
    User
end).
```

A raise inside either rolls back both the rows and the jobs. Telemetry for jobs
inserted inside `shigoto:transaction/1` fires after the commit; inside a kura
transaction it fires on insert, before the commit. Use `shigoto:transaction/1`
as the outer boundary when telemetry has to be commit-accurate.

Jobs inserted inside a kura transaction on a pool of the same name join it
whether shigoto is configured with `repo` or `pool`. Only the other direction,
kura writes joining `shigoto:transaction/1`, needs `repo`; with `{pool, Pool}`,
`shigoto:transaction/1` covers shigoto's own statements on that pool.

In tests, jobs join `kura_sandbox`: a job inserted while the test has the
repo's sandbox checked out is rolled back at checkin with the test's other
writes. See [Testing](guides/testing.md#with-kura_sandbox).

## Job Lifecycle

```
available → executing → completed
                     ↘ retryable → executing (claimed again once the backoff is over)
                     ↘ discarded (max attempts reached)
                     ↘ snoozed → available (rescheduled, the attempt given back)
```

A failed job with attempts left is `retryable`, with `scheduled_at` set to the
end of its backoff. The queue claims `retryable` jobs exactly as it claims
`available` ones, so the retry needs nothing but the polling loop.

Jobs can also be `cancelled` via `shigoto:cancel/2` and retried via `shigoto:retry/2`.
Cancelling a job that is running stops its worker process: at once on the node
running it, and within `heartbeat_interval` when the cancel was made on another
node.

## Worker Callbacks

All optional except `perform/1`:

| Callback | Default | Description |
|----------|---------|-------------|
| `perform/1` | *required* | Execute the job. Return `ok`, `{error, Reason}`, or `{snooze, Seconds}` |
| `max_attempts/0` | `3` | Maximum retry attempts before discarding |
| `queue/0` | `<<"default">>` | Default queue name |
| `priority/0` | `0` | Default priority (higher = claimed first) |
| `timeout/0` | `300000` | Execution timeout in milliseconds |
| `unique/0` | — | Uniqueness constraints |
| `tags/0` | `[]` | Default tags for filtering |
| `backoff/2` | exponential | Custom retry delay: `(Attempt, Error) -> Seconds` |
| `rate_limit/0` | — | Seki rate limiter config |
| `concurrency/0` | — | Max concurrent executions per node (seki bulkhead) |
| `global_concurrency/0` | — | Max concurrent executions across all nodes |
| `circuit_breaker/0` | — | Per-worker circuit breaker thresholds |
| `middleware/0` | `[]` | Worker-specific middleware chain |
| `on_discard/2` | — | Called when a job is permanently discarded |

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `repo` | none | kura repo whose minato pool shigoto shares (read before `pool`) |
| `pool` | none | minato pool name, when not using `repo`; one of the two is required |
| `queues` | `[{<<"default">>, 10}]` | Queue names and concurrency limits |
| `poll_interval` | `5000` | Milliseconds between polling |
| `cron` | `[]` | `{Name, Schedule, Worker, Args}` tuples |
| `prune_after_days` | `14` | Days to keep completed/discarded jobs |
| `shutdown_timeout` | `15000` | Milliseconds to wait for in-flight jobs |
| `middleware` | `[]` | Global middleware chain |
| `encryption_key` | — | 32-byte AES-256-GCM key |
| `encryption_keys` | `[]` | Ordered key list for rotation (newest first) |
| `encryption_write_format` | `v2` | Frame written: `v2` (bound to column and worker; also covers results and batch callback args) or `v1` (what 1.10 reads, for a rolling upgrade) |
| `encryption_read_formats` | `[v1, v2]` | Frames that are opened |
| `require_encrypted` | `false` | Refuse to run a job with plaintext args or meta when a key is configured |
| `workers` | `undefined` | Modules allowed to run as workers; `undefined` allows any module exporting `perform/1` |
| `instance` | `undefined` | Name of this installation, giving it its own advisory locks and NOTIFY channel |
| `advisory_lock_timeout` | `5000` | Milliseconds to wait for an advisory lock before giving up |
| `notify_min_interval` | `10` | Minimum milliseconds between notification-driven polls of one queue |
| `heartbeat_interval` | `30000` | Milliseconds between heartbeats for executing jobs; a job is stale after twice this without one |
| `rescue_interval` | `60000` | Milliseconds between a node's sweeps that rescue stale jobs |
| `on_dependency_failure` | `run` | What a waiting job does when a dependency is discarded or cancelled, unless the job sets it: `run`, `cancel` or `discard` |
| `load_shedding` | — | CoDel config map for seki |
| `queue_weights` | `#{}` | Weighted polling distribution |
| `fair_queues` | `[]` | Queues using partition-key fair claiming |
| `notifier` | — | LISTEN/NOTIFY connection config |
| `stage_interval` | `1000` | Milliseconds between due-job stager sweeps (needs `notifier`) |

## Supervision Tree

```
shigoto_sup (one_for_one)
  ├─ shigoto_executor_sup    — simple_one_for_one for job execution
  ├─ shigoto_queue_sup       — one gen_server per queue
  │    ├─ shigoto_queue:default
  │    └─ shigoto_queue:emails
  ├─ shigoto_cron            — cron scheduling with leader election
  ├─ shigoto_pruner          — hourly archival and cleanup
  ├─ shigoto_heartbeat       — periodic heartbeat updates
  ├─ shigoto_notifier        — LISTEN/NOTIFY (optional)
  └─ shigoto_stager          — surfaces newly-due jobs, leader election (optional)
```

## Guides

- [Getting Started](guides/getting-started.md)
- [Workers](guides/workers.md)
- [Cron Scheduling](guides/cron.md)
- [Batches](guides/batches.md)
- [Middleware](guides/middleware.md)
- [Resilience](guides/resilience.md)
- [Job Dependencies](guides/dependencies.md)
- [Encryption](guides/encryption.md)
- [Security](guides/security.md)
- [Telemetry](guides/telemetry.md)
- [Context Propagation](guides/context-propagation.md)
- [Testing](guides/testing.md)
- [Upgrading from 1.10](guides/upgrading.md)

## Ecosystem

- [shigoto_board](https://github.com/Taure/shigoto_board) — Real-time Arizona LiveView dashboard
- [opentelemetry_shigoto](https://github.com/Taure/opentelemetry_shigoto) — OpenTelemetry instrumentation

## Requirements

- Erlang/OTP 27+
- PostgreSQL 9.5+

## License

MIT
