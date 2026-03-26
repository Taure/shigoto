# Shigoto 仕事

PostgreSQL-backed background job processing for Erlang.

Shigoto (仕事, "work") is a feature-rich job queue built on PostgreSQL's `FOR UPDATE SKIP LOCKED` for safe multi-node operation. No Redis or external broker needed — if you have PostgreSQL, you have a job queue.

## Features

### Core
- **PostgreSQL-backed** — Jobs stored in PostgreSQL via [pgo](https://github.com/erleans/pgo). Transactional enqueue using the same pool as your application.
- **Multi-node safe** — `FOR UPDATE SKIP LOCKED` ensures each job is claimed by exactly one node. No coordination required.
- **Priority queues** — Higher priority jobs are claimed first. Multiple queues with independent concurrency limits.
- **Dynamic queues** — Add and remove queues at runtime without restart.
- **Exponential backoff** — Failed jobs retry with `min(attempt^4 + jitter, 1800)` second delays, or provide a custom `backoff/2` callback.

### Scheduling
- **Cron scheduling** — Built-in 5-field cron parser with leader election via advisory locks. Catches up on missed intervals after restarts.
- **Scheduled jobs** — Enqueue jobs for future execution with `scheduled_at`.
- **Job snoozing** — Workers can return `{snooze, Seconds}` to reschedule without consuming a retry attempt.

### Reliability
- **Job dependencies** — `depends_on` chains ensure jobs execute in order. Cycle detection prevents deadlocks.
- **Batches** — Group jobs with completion callbacks. Batch state tracks completed/discarded counts.
- **Unique jobs** — Prevent duplicates with configurable keys, states, time windows, debounce, and field replacement on conflict.
- **Stale job rescue** — Heartbeat-based detection of zombie jobs with automatic rescheduling.
- **Graceful shutdown** — Waits for in-flight jobs to finish before stopping.

### Resilience ([seki](https://github.com/Taure/seki) integration)
- **Rate limiting** — Per-worker token bucket, sliding window, GCRA, or leaky bucket.
- **Circuit breaking** — Auto-opens on repeated failures, configurable per worker.
- **Bulkhead** — Per-worker concurrency limits (local node) and global concurrency limits (across nodes via PostgreSQL).
- **Load shedding** — CoDel-based system-level protection, shedding low-priority jobs first.

### Operations
- **Encryption** — AES-256-GCM encryption for job args at rest with key rotation support.
- **Middleware** — Composable before/after hooks for logging, metrics, authorization.
- **Telemetry** — 16+ telemetry events covering job lifecycle, queue operations, resilience, batches, and cron.
- **Health check** — `shigoto:health/0` reports pool status, job counts, stale jobs, and queue health.
- **Bulk operations** — `insert_all/1`, `cancel_by/2`, `retry_by/2` for batch operations.
- **Auto-archival** — Old jobs archived to `shigoto_jobs_archive` table, then pruned.
- **Dashboard** — [shigoto_board](https://github.com/Taure/shigoto_board) provides a real-time web dashboard.

### Testing
- **Synchronous drain** — `drain_queue/1` processes all jobs synchronously for deterministic tests.
- **74 tests** — Comprehensive test coverage across 3 Common Test suites.

## Quick Start

Add to your deps:

```erlang
{deps, [
    {shigoto, {git, "https://github.com/Taure/shigoto.git", {branch, "main"}}}
]}.
```

Configure in `sys.config`:

```erlang
{shigoto, [
    {pool, my_app_db},
    {queues, [{<<"default">>, 10}, {<<"emails">>, 5}]},
    {poll_interval, 5000},
    {cron, [
        {<<"daily_cleanup">>, <<"0 3 * * *">>, my_cleanup_worker, #{}}
    ]}
]}
```

Run the migration:

```erlang
shigoto_migration:up(my_app_db).
```

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

## Job Lifecycle

```
available → executing → completed
                     ↘ retryable → available (retry with backoff)
                     ↘ discarded (max attempts reached)
                     ↘ snoozed → available (rescheduled, attempt preserved)
```

Jobs can also be `cancelled` via `shigoto:cancel/2` and retried via `shigoto:retry/2`.

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
| `pool` | *required* | pgo pool name |
| `queues` | `[{<<"default">>, 10}]` | Queue names and concurrency limits |
| `poll_interval` | `5000` | Milliseconds between polling |
| `cron` | `[]` | `{Name, Schedule, Worker, Args}` tuples |
| `prune_after_days` | `14` | Days to keep completed/discarded jobs |
| `shutdown_timeout` | `15000` | Milliseconds to wait for in-flight jobs |
| `middleware` | `[]` | Global middleware chain |
| `encryption_key` | — | 32-byte AES-256-GCM key |
| `encryption_keys` | `[]` | Ordered key list for rotation (newest first) |
| `heartbeat_interval` | `30000` | Stale job detection interval |
| `load_shedding` | — | CoDel config map for seki |
| `queue_weights` | `#{}` | Weighted polling distribution |
| `fair_queues` | `[]` | Queues using partition-key fair claiming |
| `notifier` | — | LISTEN/NOTIFY connection config |

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
  └─ shigoto_notifier        — LISTEN/NOTIFY (optional)
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
- [Testing](guides/testing.md)

## Ecosystem

- [shigoto_board](https://github.com/Taure/shigoto_board) — Real-time Arizona LiveView dashboard
- [opentelemetry_shigoto](https://github.com/Taure/opentelemetry_shigoto) — OpenTelemetry instrumentation

## Requirements

- Erlang/OTP 27+
- PostgreSQL 9.5+

## License

MIT
