# Getting Started

## Installation

### Erlang (rebar3)

Add `shigoto` to your `rebar.config` dependencies:

```erlang
{deps, [
    {shigoto, "~> 1.10"}
]}.
```

### Elixir (Mix)

Add `shigoto` to your `mix.exs`:

```elixir
defp deps do
  [
    {:shigoto, "~> 1.10"}
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
| `repo` | none | kura repo whose minato pool shigoto shares; read before `pool` |
| `pool` | none | minato pool name, when not using `repo`; one of the two is required |
| `queues` | `[{<<"default">>, 10}]` | Queue names with concurrency limits |
| `poll_interval` | `5000` | Milliseconds between polling for new jobs |
| `prune_after_days` | `14` | Days before completed/discarded jobs are archived |
| `shutdown_timeout` | `15000` | Milliseconds to wait for in-flight jobs during shutdown. A job still running after that is stopped and given back to the queue without using an attempt |
| `cron` | `[]` | Cron entries (see the [Cron](cron.md) guide) |
| `middleware` | `[]` | Global middleware chain (see [Middleware](middleware.md)) |
| `encryption_key` | `undefined` | 32-byte AES-256-GCM key (see [Encryption](encryption.md)) |
| `workers` | `undefined` | Modules allowed to run as workers (see [Security](security.md)) |
| `heartbeat_interval` | `30000` | Heartbeat interval in ms for executing jobs; a job is stale after twice this without a heartbeat |
| `rescue_interval` | `60000` | Milliseconds between the passes of a node that rescue stale jobs, release jobs waiting on a job that has ended, and settle finished batches. One process per node runs them, and only one node of a cluster at a time |
| `on_discard_timeout` | `60000` | Milliseconds an `on_discard/2` callback may run before it is stopped (see [Workers](workers.md#on_discard-callback)) |
| `propagator` | `undefined` | Module that carries a trace context from insert to run (see [Context Propagation](context-propagation.md)) |
| `on_dependency_failure` | `run` | What a waiting job does when a dependency fails, unless the job sets it (see [Dependencies](dependencies.md)) |
| `load_shedding` | `undefined` | Seki load shedding config (see [Resilience](resilience.md)) |
| `queue_weights` | `#{}` | Queue weight map for weighted polling |
| `fair_queues` | `[]` | Queue names that use partition-key fair claiming |
| `fanout_queues` | `[]` | Broadcast queues where all nodes process every job (see [Fanout Queues](fanout-queues.md)) |

### Stopping a node

When the application stops, each queue waits up to `shutdown_timeout` for its
running jobs, one queue after the other, and stops claiming. Jobs keep their
heartbeat for all of that time, so no other node takes them over. A job still
running at the end is stopped and given back: it is `available` again and the
interrupted run uses no attempt.

The node has to allow that much time. `kernel`'s `shutdown_timeout` is
`infinity` unless set; if you set it, keep it above
`shigoto_config:shutdown_budget()`. Below that the node kills shigoto in the
middle, the cut-off jobs wait for the stale-job rescue, and shigoto logs
`shigoto_shutdown_cut_short` at boot.

## Run the Migration

The shigoto application creates or updates its tables when it starts. It tries
up to 5 times, 1 to 5 seconds apart. If the schema is still not current (the
database does not exist yet, the pool cannot reach it, or the migration could
not get its table locks within 500 ms), the application starts without its
queues:

- it logs `shigoto_migration_pending` at error level and emits
  `[shigoto, migration, pending]` telemetry;
- it retries every 30 seconds, and starts the queues as soon as the migration
  succeeds;
- meanwhile `shigoto:add_queue/2` answers `{error, migration_pending}` and
  `shigoto:health/0` answers `{error, #{reason => migration_pending}}`.

An error a retry cannot fix (SQLSTATE class 42, such as
`42501 insufficient_privilege`) skips the remaining boot attempts and goes
straight to the background retry. Boot blocks the release while it migrates:
about 45 seconds at worst with the database unreachable, plus any wait for
another node's migration. On Kubernetes, cover that with a `startupProbe`.

Jobs inserted while the queues wait (once the tables exist) run when the
queues start. To migrate sooner, for example right after kura's migrator creates the
database on a first boot, run it yourself, then tell the waiting migrator to
start the queues now rather than at its next 30 second tick:

```erlang
ok = shigoto_migration:up(my_app_repo),
_ = shigoto_migrator:retry_now().
```

```elixir
:ok = :shigoto_migration.up(:my_app_repo)
_ = :shigoto_migrator.retry_now()
```

`retry_now/0` answers `not_running` when no migration is pending (the queues
are already running).

`up/1` is idempotent and answers `{error, Reason}` for the first statement that
fails. Nodes that boot together migrate one at a time, and a schema that is
already current is left alone without taking a table lock. Otherwise `up/1`
locks the existing shigoto tables all at once, waiting at most 500 ms; claims and
inserts wait behind it for no longer than that, and steady short writes do not
keep it out. When a long transaction holds a table past 500 ms (a slow query on
a shigoto table), `up/1` rolls back and answers `{error, lock_timeout}` instead
of stalling job claims behind it. Retry it, or run migrations from one node at
a quiet moment.

Upgrading from shigoto 1.9.x, whose schema carries no version comment: when the
tables already have the newest columns, `up/1` treats the schema as current,
logs `shigoto_schema_unstamped` once and runs no DDL, so an application role
that may only read and write rows still boots with its queues. Run
`shigoto_migration:up/1` once as the table owner to record the version.

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

`insert_all/1,2` does not deduplicate. Given a job whose worker defines
`unique/0`, or `unique` in its options, it answers
`{error, {insert_all_unsupported, unique, Workers}}` and inserts nothing. Use
`insert/1,2` for unique jobs, or pass `#{unique => false}` to insert the list
as it is. A `depends_on` that names a job that does not exist answers
`{error, {missing_dependencies, Ids}}`.

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

## Connection Poolers

shigoto keeps nothing on a session between statements: its advisory locks are
transaction scoped, the only setting it changes is made with `SET LOCAL`, and
whatever takes more than one statement runs in a transaction. It runs behind a
pooler in session mode, and behind PgBouncer in transaction mode with two
conditions:

- `max_prepared_statements` is above 0 (PgBouncer 1.21 or later). minato
  prepares the statements it runs more than once, and PgBouncer has to know
  them to hand a transaction to another server connection. With it at 0, jobs
  fail to move between states.
- `notifier` points at PostgreSQL itself, not at the pooler. `LISTEN` belongs
  to a session, so through transaction mode no notification arrives. The
  `notifier` map has its own `host` and `port` for this. Without `notifier`,
  queues poll.

```erlang
{shigoto, [
    {pool, my_pool},                       %% a minato pool on PgBouncer, 6432
    {notifier, #{host => "db.internal", port => 5432,
                 database => "mydb", user => "shigoto", password => "secret"}}
]}
```

The lifecycle suite passes through PgBouncer 1.26 in transaction mode:
`docker compose --profile pgbouncer up -d --wait`, then
`SHIGOTO_TEST_DB_PORT=5557 SHIGOTO_TEST_LISTEN_PORT=5556 rebar3 ct --suite test/shigoto_lifecycle_SUITE`.

## Next Steps

- [Workers](workers.md) — Error handling, retries, backoff, timeouts, and optional callbacks
- [Cron](cron.md) — Scheduled recurring jobs
- [Batches](batches.md) — Group jobs with completion callbacks
- [Middleware](middleware.md) — Before/after hooks for job execution
- [Fanout Queues](fanout-queues.md) — Broadcast delivery to all nodes (cloud-native pub/sub)
- [Resilience](resilience.md) — Rate limiting, circuit breaking, and load shedding via seki
