# Middleware

Middleware wraps job execution with before/after logic. Each middleware is a
function that receives the job map and a `Next` function.

## Writing Middleware

### Erlang

```erlang
my_logging_middleware(Job, Next) ->
    JobId = maps:get(id, Job),
    logger:info("starting job ~p", [JobId]),
    Result = Next(),
    logger:info("finished job ~p: ~p", [JobId, Result]),
    Result.
```

### Elixir

```elixir
def my_logging_middleware(job, next) do
  job_id = job.id
  Logger.info("starting job #{job_id}")
  result = next.()
  Logger.info("finished job #{job_id}: #{inspect(result)}")
  result
end
```

## Global Middleware

Applied to all jobs via configuration:

```erlang
{shigoto, [
    {middleware, [fun my_app_middleware:timing/2, fun my_app_middleware:tracing/2]}
]}
```

```elixir
config :shigoto,
  middleware: [&MyAppMiddleware.timing/2, &MyAppMiddleware.tracing/2]
```

## Worker Middleware

Workers can define their own middleware via the `middleware/0` callback:

```erlang
-module(audited_worker).
-behaviour(shigoto_worker).
-export([perform/1, middleware/0]).

perform(Args) -> do_work(Args).

middleware() ->
    [fun audit_middleware/2].

audit_middleware(Job, Next) ->
    audit_log:record(started, Job),
    Result = Next(),
    audit_log:record(finished, Job),
    Result.
```

## Execution Order

Middleware runs in this order:

1. Global middleware (from config, in order)
2. Worker middleware (from `middleware/0` callback, in order)
3. `Worker:perform/1`

## Short-Circuiting

Return early without calling `Next()` to skip execution:

```erlang
maintenance_gate(Job, Next) ->
    case application:get_env(my_app, maintenance_mode, false) of
        true -> {snooze, 300};  %% Snooze for 5 minutes
        false -> Next()
    end.
```

## Built-in Resilience

Seki resilience checks (rate limiting, circuit breaking, bulkhead, load
shedding) run *before* the middleware chain. See [Resilience](resilience.md).
