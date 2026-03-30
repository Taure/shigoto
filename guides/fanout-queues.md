# Fanout Queues

Standard Shigoto queues are single-consumer: one node claims each job via
`FOR UPDATE SKIP LOCKED`. Fanout queues are multi-consumer: **every node
processes every job**.

## When to use

Fanout queues are for broadcast events that need to reach all connected
clients, regardless of which node they're on:

- Session revocation (ban, token expiry)
- Push notifications to connected WebSocket sessions
- Cross-node chat message delivery
- Presence updates

They replace the need for Redis pub/sub, NATS, or distributed Erlang in
cloud-native deployments. The only infrastructure required is PostgreSQL.

## How it works

Each node polls the `shigoto_jobs` table for recent jobs on fanout queues
using a time window (default 120 seconds). Unlike standard queues, there
is no row locking — all nodes read the same rows.

Each node tracks which job IDs it has already processed in a local ETS
table. On node restart, the ETS is empty, so recent jobs within the window
are re-processed. **Workers must be idempotent.**

```
Producer Node                 PostgreSQL              All Consumer Nodes
     |                            |                         |
     |-- shigoto:insert(...) ---->|                         |
     |                            |-- poll (no locking) --->|
     |                            |                         |-- ETS dedup
     |                            |                         |-- execute locally
     |                            |                         |
     |                            |-- cleanup (2x window) --|
```

## Configuration

### Erlang (sys.config)

```erlang
{shigoto, [
    {pool, my_app_db},
    {queues, [{<<"default">>, 10}]},
    {fanout_queues, [
        {<<"broadcast">>, 5, #{window => 120}}
    ]},
    {poll_interval, 500}
]}
```

### Elixir (config.exs)

```elixir
config :shigoto,
  pool: :my_app_db,
  queues: [{"default", 10}],
  fanout_queues: [
    {"broadcast", 5, %{window: 120}}
  ],
  poll_interval: 500
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `window` | 120 | Time window in seconds. Jobs older than this are ignored. |

The second element is concurrency — how many jobs this node can process
simultaneously from this fanout queue.

## Writing a fanout worker

Fanout workers are regular `shigoto_worker` implementations. The only
requirement is that `perform/1` must be idempotent.

```erlang
-module(my_broadcast_worker).
-behaviour(shigoto_worker).

-export([perform/1, queue/0, max_attempts/1]).

queue() -> <<"broadcast">>.

max_attempts(_Args) -> 1.

perform(#{type := <<"session_revoked">>, player_id := PlayerId, reason := Reason}) ->
    %% Local delivery — only reaches sessions on THIS node
    my_presence:disconnect(PlayerId, Reason);
perform(#{type := <<"notification">>, player_id := PlayerId} = Payload) ->
    my_presence:send(PlayerId, {notification, maps:without([type, player_id], Payload)}).
```

## Enqueuing broadcast jobs

Use the standard `shigoto:insert/1` API. The job goes to PostgreSQL and
all nodes pick it up on their next poll cycle.

```erlang
shigoto:insert(#{
    worker => my_broadcast_worker,
    args => #{
        type => <<"session_revoked">>,
        player_id => PlayerId,
        reason => <<"banned">>
    }
}).
```

Set high priority to ensure broadcast jobs are processed before regular
queue jobs within the same poll cycle:

```erlang
shigoto:insert(#{
    worker => my_broadcast_worker,
    args => #{type => <<"session_revoked">>, player_id => PlayerId},
    priority => 100
}).
```

## Cleanup

Fanout jobs stay in `available` state since no node claims them. The
fanout queue process automatically deletes jobs older than `2 x window`
to prevent unbounded table growth. The ETS dedup set is also cleared
periodically if it exceeds 10,000 entries.

## Design trade-offs

| Aspect | Standard Queue | Fanout Queue |
|--------|---------------|--------------|
| Delivery | Exactly once (one node) | At-least once (all nodes) |
| Idempotency | Nice to have | Required |
| Node restart | Picks up from last claimed ID | Re-processes recent window |
| Job state | `available` -> `executing` -> `completed` | Stays `available` until pruned |
| Locking | `FOR UPDATE SKIP LOCKED` | None |
| Use case | Background work | Broadcast events |

## What NOT to use fanout for

- **High-frequency events** (>10/sec) — the poll interval adds latency
  and the query load scales with job count in the window.
- **Large payloads** — every node reads every job. Keep args small.
- **Events that need exactly-once delivery** — use standard queues instead.
- **Real-time game state** (10Hz tick loops) — use local `pg` with sticky
  session placement. Fanout is for low-frequency cross-node events.
