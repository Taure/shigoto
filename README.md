# Shigoto 仕事

PostgreSQL-backed background job processing for the [Nova](https://github.com/novaframework/nova) ecosystem.

Reliable job queuing with `FOR UPDATE SKIP LOCKED` for safe multi-node operation, exponential backoff with jitter, cron scheduling, and a `drain_queue` helper for synchronous testing.

## Features

- **PostgreSQL-backed** — Jobs stored in PostgreSQL via Kura. No Redis or external broker needed.
- **Multi-node safe** — `FOR UPDATE SKIP LOCKED` ensures each job is claimed by exactly one node.
- **Exponential backoff** — Failed jobs retry with `min(attempt^4 + jitter, 1800)` second delays.
- **Cron scheduling** — Built-in cron expression parser supporting standard 5-field syntax.
- **Priority queues** — Higher priority jobs are claimed first within each queue.
- **Telemetry** — Emits `[shigoto, job, completed|failed|inserted]` events.
- **Test-friendly** — `drain_queue/1` processes jobs synchronously for deterministic tests.
- **Auto-pruning** — Completed and discarded jobs cleaned up automatically.
- **Stale job rescue** — Executing jobs older than 5 minutes are presumed dead and rescheduled.

## Quick Start

Add `shigoto` to your deps:

```erlang
{deps, [
    {shigoto, {git, "https://github.com/Taure/shigoto.git", {branch, "main"}}}
]}.
```

Configure in `sys.config`:

```erlang
{shigoto, [
    {repo, my_repo},
    {queues, [{<<"default">>, 10}, {<<"emails">>, 5}]},
    {poll_interval, 5000}
]}
```

Run the migration:

```erlang
shigoto_migration:up(my_repo).
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
shigoto:insert(#{
    worker => my_email_worker,
    args => #{<<"to">> => <<"user@example.com">>, <<"subject">> => <<"Welcome">>},
    queue => <<"emails">>
}).

%% Schedule for later
shigoto:insert(#{
    worker => my_cleanup_worker,
    scheduled_at => {{2026, 3, 20}, {3, 0, 0}}
}).

%% With priority (higher = claimed first)
shigoto:insert(#{
    worker => my_urgent_worker,
    priority => 10
}).
```

## Job Lifecycle

```
available → executing → completed
                     ↘ retryable → available (retry)
                     ↘ discarded (max attempts reached)
```

Jobs can also be `cancelled` via `shigoto:cancel/2` and retried via `shigoto:retry/2`.

## Cron Scheduling

Configure recurring jobs in `sys.config`:

```erlang
{shigoto, [
    {repo, my_repo},
    {cron, [
        {<<"daily_cleanup">>, <<"0 3 * * *">>, my_cleanup_worker, #{}},
        {<<"hourly_stats">>,  <<"0 * * * *">>, my_stats_worker, #{}}
    ]}
]}
```

Supported syntax: `* */5 1-15 1,6,12 MON-FRI`

## Testing

Use `drain_queue/1` for synchronous job execution in tests:

```erlang
my_test(_Config) ->
    shigoto:insert(#{worker => my_worker, args => #{}}),
    ok = shigoto:drain_queue(<<"default">>),
    %% Job has been executed synchronously
    ?assert(my_worker_did_its_thing()).
```

## Supervision Tree

```
shigoto_sup (one_for_one)
  ├─ shigoto_executor_sup    — simple_one_for_one for job runners
  ├─ shigoto_queue_sup       — one gen_server per configured queue
  │    ├─ shigoto_queue:default
  │    └─ shigoto_queue:emails
  ├─ shigoto_cron            — checks cron expressions every minute
  └─ shigoto_pruner          — hourly cleanup of old jobs
```

## Configuration Reference

| Option | Default | Description |
|--------|---------|-------------|
| `repo` | *required* | Kura repo module |
| `queues` | `[{<<"default">>, 10}]` | Queue names and concurrency limits |
| `poll_interval` | `5000` | Milliseconds between polling for new jobs |
| `cron` | `[]` | List of `{Name, Schedule, Worker, Args}` tuples |
| `prune_after_days` | `14` | Days to keep completed/discarded jobs |

## Requirements

- Erlang/OTP 27+
- PostgreSQL 9.5+ (for `FOR UPDATE SKIP LOCKED`)

## License

MIT
