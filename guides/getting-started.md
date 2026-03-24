# Getting Started

## Installation

### Erlang (rebar3)

Add `shigoto` to your `rebar.config` dependencies:

```erlang
{deps, [
    {shigoto, {git, "https://github.com/Taure/shigoto.git", {branch, "main"}}}
]}.
```

### Elixir (Mix)

Add `shigoto` to your `mix.exs`:

```elixir
defp deps do
  [
    {:shigoto, github: "Taure/shigoto", branch: "main"}
  ]
end
```

## Configuration

### Erlang (sys.config)

```erlang
{shigoto, [
    {pool, my_app_db},
    {queues, [{<<"default">>, 10}, {<<"mailers">>, 5}]},
    {poll_interval, 5000},
    {prune_after_days, 14},
    {shutdown_timeout, 15000},
    {cron, []}
]}
```

### Elixir (config.exs)

```elixir
config :shigoto,
  pool: :my_app_db,
  queues: [{"default", 10}, {"mailers", 5}],
  poll_interval: 5000,
  prune_after_days: 14,
  shutdown_timeout: 15000,
  cron: []
```

### Configuration Reference

| Key | Default | Description |
|-----|---------|-------------|
| `pool` | *required* | Your pgo pool name |
| `queues` | `[{<<"default">>, 10}]` | Queue names with concurrency limits |
| `poll_interval` | `5000` | Milliseconds between polling for new jobs |
| `prune_after_days` | `14` | Days before completed/discarded jobs are archived |
| `shutdown_timeout` | `15000` | Milliseconds to wait for in-flight jobs during shutdown |
| `cron` | `[]` | Cron entries (see the [Cron](cron.md) guide) |
| `middleware` | `[]` | Global middleware chain (see [Middleware](middleware.md)) |
| `encryption_key` | `undefined` | 32-byte AES-256-GCM key for encrypting job args |
| `heartbeat_interval` | `30000` | Heartbeat interval in ms for executing jobs |
| `load_shedding` | `undefined` | Seki load shedding config (see [Resilience](resilience.md)) |
| `queue_weights` | `#{}` | Queue weight map for weighted polling |
| `fair_queues` | `[]` | Queue names that use partition-key fair claiming |

## Run the Migration

Create the necessary tables:

```erlang
shigoto_migration:up(my_app_db).
```

```elixir
:shigoto_migration.up(:my_app_db)
```

## Create a Worker

### Erlang

```erlang
-module(my_email_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"to">> := To, <<"subject">> := Subject, <<"body">> := Body}) ->
    my_mailer:send(To, Subject, Body),
    ok.
```

### Elixir

```elixir
defmodule MyEmailWorker do
  @behaviour :shigoto_worker

  @impl true
  def perform(%{"to" => to, "subject" => subject, "body" => body}) do
    MyMailer.send(to, subject, body)
    :ok
  end
end
```

> **Note:** Job args always have binary keys (`<<"key">>` / `"key"`) because
> they are stored as JSONB in PostgreSQL.

## Insert a Job

### Erlang

```erlang
shigoto:insert(#{
    worker => my_email_worker,
    args => #{<<"to">> => <<"user@example.com">>, <<"subject">> => <<"Welcome">>}
}).
```

### Elixir

```elixir
:shigoto.insert(%{
  worker: MyEmailWorker,
  args: %{"to" => "user@example.com", "subject" => "Welcome"}
})
```

With options:

```elixir
:shigoto.insert(%{
  worker: MyEmailWorker,
  args: %{"to" => "user@example.com"},
  queue: "mailers",
  priority: 5,
  max_attempts: 10,
  tags: ["email", "onboarding"],
  scheduled_at: {{2026, 3, 19}, {10, 0, 0}}
})
```

## Bulk Insert

Insert many jobs in a single SQL roundtrip:

```erlang
shigoto:insert_all([
    #{worker => my_worker, args => #{<<"id">> => 1}},
    #{worker => my_worker, args => #{<<"id">> => 2}},
    #{worker => my_worker, args => #{<<"id">> => 3}}
]).
```

```elixir
:shigoto.insert_all([
  %{worker: MyWorker, args: %{"id" => 1}},
  %{worker: MyWorker, args: %{"id" => 2}},
  %{worker: MyWorker, args: %{"id" => 3}}
])
```

## Transactional Enqueue

If shigoto uses the same pgo pool as your application, job inserts participate in
your database transactions. The job is only enqueued if the transaction commits:

```erlang
pgo:transaction(fun() ->
    pgo:query(~"INSERT INTO users (name, email) VALUES ($1, $2)", [Name, Email]),
    shigoto:insert(#{worker => welcome_email_worker, args => #{<<"email">> => Email}})
end).
```

If the transaction rolls back (e.g. a unique constraint violation on the user),
the job is never inserted. No "user created but email lost" or "email sent but
user creation failed" bugs.

This works with Kura too — just configure shigoto to use the same pool:

```erlang
{pgo, [{pools, [{default, #{...}}]}]},
{shigoto, [{pool, default}]}
```

## Testing with drain_queue

Process all pending jobs synchronously in tests:

```erlang
shigoto:drain_queue(<<"default">>).
shigoto:drain_queue(<<"default">>, #{timeout => 30000}).
```

```elixir
:shigoto.drain_queue("default")
:shigoto.drain_queue("default", %{timeout: 30000})
```

## Next Steps

- [Workers](workers.md) — Error handling, retries, backoff, timeouts, and optional callbacks
- [Cron](cron.md) — Scheduled recurring jobs
- [Batches](batches.md) — Group jobs with completion callbacks
- [Middleware](middleware.md) — Before/after hooks for job execution
- [Resilience](resilience.md) — Rate limiting, circuit breaking, and load shedding via seki
