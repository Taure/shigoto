# Resilience

Shigoto integrates with [seki](https://github.com/Taure/seki) to provide
per-worker rate limiting, circuit breaking, bulkhead (concurrency limiting),
and system-level load shedding. All primitives are lazily initialized on
first use.

When seki is not running, all resilience checks are no-ops.

## Rate Limiting

Limit how fast a worker's jobs are executed. Seki provides four algorithms:
token bucket, sliding window, GCRA, and leaky bucket.

### Erlang

```erlang
-module(api_worker).
-behaviour(shigoto_worker).
-export([perform/1, rate_limit/0]).

perform(Args) -> call_external_api(Args).

rate_limit() ->
    #{
        limit => 100,              %% 100 requests
        window => 60000,           %% per minute
        algorithm => sliding_window %% or: token_bucket, gcra, leaky_bucket
    }.
```

### Elixir

```elixir
defmodule ApiWorker do
  @behaviour :shigoto_worker

  @impl true
  def perform(args), do: call_external_api(args)

  def rate_limit do
    %{limit: 100, window: 60_000, algorithm: :sliding_window}
  end
end
```

When the rate limit is hit, jobs are **snoozed** (not retried), preserving
the attempt count.

## Circuit Breaking

Every worker automatically gets a circuit breaker. When a worker fails
repeatedly (50% failure rate over 20 calls), the breaker opens and subsequent
jobs are snoozed for 10 seconds until the breaker transitions to half-open.

This prevents burning through retry attempts against a known-broken dependency.

The circuit breaker is configured with sensible defaults:
- Window: 20 calls (count-based)
- Failure threshold: 50%
- Wait duration: 30 seconds before half-open
- Half-open requests: 3

## Bulkhead (Concurrency Limiting)

Limit how many instances of a worker can execute concurrently across all queues
and nodes:

```erlang
-module(heavy_worker).
-behaviour(shigoto_worker).
-export([perform/1, concurrency/0]).

perform(Args) -> heavy_computation(Args).

concurrency() -> 5.  %% Max 5 concurrent executions
```

```elixir
defmodule HeavyWorker do
  @behaviour :shigoto_worker

  @impl true
  def perform(args), do: heavy_computation(args)

  def concurrency, do: 5
end
```

When the bulkhead is full, jobs are snoozed for 5 seconds.

## Load Shedding

System-level CoDel-based load shedding protects the entire job system from
overload. Enable via configuration:

```erlang
{shigoto, [
    {load_shedding, #{
        target => 5,           %% CoDel target sojourn time (ms)
        interval => 100,       %% CoDel interval (ms)
        max_in_flight => 1000  %% Max concurrent jobs system-wide
    }}
]}
```

Low-priority jobs are shed first. Shigoto maps job priorities to seki levels:

| Job Priority | Seki Level | Behavior |
|-------------|-----------|----------|
| >= 10 | 0 (critical) | Last to be shed |
| 5-9 | 1 (high) | |
| 0-4 | 2 (normal) | |
| < 0 | 3 (low) | First to be shed |

## Execution Pipeline

The full resilience pipeline for each job:

```
1. Load shedding check (system-level)
2. Rate limit check (per-worker)
3. Bulkhead check (per-worker concurrency)
4. Circuit breaker check (per-worker health)
5. Global middleware chain
6. Worker middleware chain
7. Worker:perform/1
```

Any check that fails results in a **snooze** — the job is rescheduled without
counting as a failure attempt.
