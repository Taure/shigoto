# Getting Started

## Installation

Add `shigoto` to your `rebar.config` dependencies:

```erlang
{deps, [
    {shigoto, {git, "https://github.com/Taure/shigoto.git", {branch, "main"}}}
]}.
```

## Configuration

Configure Shigoto in your `sys.config`:

```erlang
{shigoto, [
    {pool, my_app_db},
    {queues, [{<<"default">>, 10}, {<<"mailers">>, 5}]},
    {poll_interval, 5000},
    {prune_after_days, 14},
    {cron, []}
]}
```

| Key | Default | Description |
|-----|---------|-------------|
| `pool` | *required* | Your pgo pool name |
| `queues` | `[{<<"default">>, 10}]` | Queue names with concurrency limits |
| `poll_interval` | `5000` | Milliseconds between polling for new jobs |
| `prune_after_days` | `14` | Days before completed/discarded jobs are pruned |
| `cron` | `[]` | Cron entries (see the [Cron](cron.md) guide) |

## Run the Migration

Create the `shigoto_jobs` and `shigoto_cron` tables:

```erlang
shigoto_migration:up(my_app_db).
```

This creates the necessary tables and indexes. Call `shigoto_migration:down(my_app_db)`
to drop them.

## Create a Worker

Implement the `shigoto_worker` behaviour:

```erlang
-module(my_email_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"to">> := To, <<"subject">> := Subject, <<"body">> := Body}) ->
    my_mailer:send(To, Subject, Body),
    ok.
```

See the [Workers](workers.md) guide for error handling and retries.

## Insert a Job

```erlang
shigoto:insert(#{
    worker => my_email_worker,
    args => #{
        <<"to">> => <<"user@example.com">>,
        <<"subject">> => <<"Welcome">>,
        <<"body">> => <<"Hello!">>
    }
}).
```

Jobs are inserted into the `default` queue by default. Specify a different
queue, priority, or schedule:

```erlang
shigoto:insert(#{
    worker => my_email_worker,
    args => #{<<"to">> => <<"user@example.com">>},
    queue => <<"mailers">>,
    priority => 5,
    max_attempts => 5,
    scheduled_at => {{2026, 3, 19}, {10, 0, 0}}
}).
```

## Testing with drain_queue

In tests, use `shigoto:drain_queue/1` to process all pending jobs synchronously:

```erlang
my_test(_Config) ->
    shigoto:insert(#{worker => my_email_worker, args => #{<<"to">> => <<"test@example.com">>}}),
    shigoto:drain_queue(<<"default">>),
    %% Assert side effects
    ok.
```

Pass a timeout option for long-running jobs:

```erlang
shigoto:drain_queue(<<"default">>, #{timeout => 30000}).
```
