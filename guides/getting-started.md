# Getting Started

## Installation

### Erlang (rebar3)

Add `shigoto` to your `rebar.config` dependencies:

```erlang
{deps, [
    {shigoto, "~> 1.9"}
]}.
```

### Elixir (Mix)

Add `shigoto` to your `mix.exs`:

```elixir
defp deps do
  [
    {:shigoto, "~> 1.9"}
  ]
end
```

## Configuration

shigoto runs on a [minato](https://hex.pm/packages/minato) pool. In an app on
[kura](https://hex.pm/packages/kura), name the repo with `repo`: `kura_postgres`
starts a minato pool named after the repo, and shigoto shares it and its
transactions. `repo` must equal that pool's name: the repo module, or the
repo's `pool` key when kura's config sets one. Without kura, start a pool with `shigoto_db:start_pool/2` and name
it with `pool`.

### Erlang (sys.config)

```erlang
{shigoto, [
    {repo, my_app_repo},
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
  repo: :my_app_repo,
  queues: [{"default", 10}, {"mailers", 5}],
  poll_interval: 5000,
  prune_after_days: 14,
  shutdown_timeout: 15000,
  cron: []
```

### Configuration Reference

| Key | Default | Description |
|-----|---------|-------------|
| `repo` | — | kura repo whose minato pool shigoto shares; read before `pool` |
| `pool` | — | minato pool name, when not using `repo`; one of the two is required |
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
| `fanout_queues` | `[]` | Broadcast queues where all nodes process every job (see [Fanout Queues](fanout-queues.md)) |

## Run the Migration

The shigoto application creates or updates its tables when it starts. That
needs the pool up and the database there; if it is not, the application logs
`shigoto_migration_failed` with the reason and starts without tables. On the
first boot of a fresh database, where kura's migrator creates it after shigoto
has started, run the migration again once it exists:

```erlang
ok = shigoto_migration:up(my_app_repo).
```

```elixir
:ok = :shigoto_migration.up(:my_app_repo)
```

`up/1` is idempotent and answers `{error, Reason}` for the first statement that
fails. Nodes that boot together migrate one at a time, and a schema that is
already current is left alone without taking a table lock. When a statement has
to wait more than 2 seconds for a table lock (a long query on a shigoto table),
`up/1` rolls back and answers `{error, lock_timeout}` instead of stalling job
claims behind it: retry it, or run migrations from one node at a quiet moment.

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

With `{repo, Repo}`, a job inserted inside the repo's transaction is part of
it, and commits or rolls back with your writes:

```erlang
my_app_repo:transaction(fun() ->
    {ok, User} = my_app_repo:insert(UserChangeset),
    {ok, _Job} = shigoto:insert(#{
        worker => welcome_email_worker,
        args => #{<<"user_id">> => maps:get(id, User)}
    }),
    User
end).
```

If the transaction rolls back (e.g. a unique constraint violation on the user),
the job is never inserted. No "user created but email lost" or "email sent but
user creation failed" bugs.

`shigoto:transaction/1` works the other way round: kura writes made inside it
join the same transaction, and `job_inserted` telemetry for its jobs fires only
after the commit. Inside `Repo:transaction/1` that telemetry fires on insert,
before the commit, so use `shigoto:transaction/1` as the outer boundary when
telemetry has to be commit-accurate.

```erlang
shigoto:transaction(fun() ->
    {ok, User} = my_app_repo:insert(UserChangeset),
    {ok, _Job} = shigoto:insert(#{worker => welcome_email_worker, args => #{}}),
    User
end).
```

Jobs inserted inside a kura transaction on a pool of the same name join it
whether shigoto is configured with `repo` or `pool`. Only the other direction
needs `repo`: with `{pool, Pool}`, `shigoto:transaction/1` covers shigoto's own
statements on that pool.

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
- [Fanout Queues](fanout-queues.md) — Broadcast delivery to all nodes (cloud-native pub/sub)
- [Resilience](resilience.md) — Rate limiting, circuit breaking, and load shedding via seki
