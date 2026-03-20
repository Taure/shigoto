-module(shigoto_worker).
-moduledoc """
Behaviour for Shigoto job workers. Implement `perform/1` to handle jobs.

The `perform/1` callback receives the job's args map and should return
`ok` on success or `{error, Reason}` on failure. Failed jobs are retried
with configurable backoff up to `max_attempts`.

## Optional Callbacks

Workers can declare defaults via optional callbacks:

- `max_attempts/0` — Maximum retry attempts (default: 3)
- `queue/0` — Default queue name (default: `<<\"default\">>`)
- `priority/0` — Default priority (default: 0)
- `timeout/0` — Execution timeout in ms (default: 300000 / 5 min)
- `unique/0` — Uniqueness constraints (see below)
- `tags/0` — Default tags for this worker
- `backoff/2` — Custom backoff strategy (attempt, error -> seconds)
- `rate_limit/0` — Per-worker rate limit config for seki
- `concurrency/0` — Max concurrent executions across all queues
- `middleware/0` — Worker-specific middleware list
- `on_discard/2` — Called when a job is permanently discarded

These are used as defaults when inserting jobs. Per-insert options
in the params map always take precedence.

## Uniqueness

Implement `unique/0` to prevent duplicate jobs:

```erlang
unique() ->
    #{
        keys => [worker, args],     %% Fields to check (worker, args, queue)
        states => [available, executing, retryable],  %% States to check against
        period => 300               %% Seconds (or infinity)
    }.
```

## Rate Limiting

Implement `rate_limit/0` to limit job execution rate:

```erlang
rate_limit() ->
    #{
        limit => 100,           %% Max requests per window
        window => 60000,        %% Window in milliseconds
        algorithm => sliding_window  %% token_bucket | sliding_window | gcra | leaky_bucket
    }.
```

## Custom Backoff

Implement `backoff/2` to control retry delays:

```erlang
backoff(Attempt, _Error) ->
    min(Attempt * 10, 300).  %% Linear backoff, max 5 minutes
```

## Example

```erlang
-module(cleanup_worker).
-behaviour(shigoto_worker).
-export([perform/1, max_attempts/0, queue/0, timeout/0, unique/0]).

perform(#{<<\"days\">> := Days}) ->
    delete_old_records(Days),
    ok.

max_attempts() -> 5.
queue() -> <<\"maintenance\">>.
timeout() -> 60000. %% 1 minute
unique() -> #{keys => [worker, args], period => 300}.
```
""".

-callback perform(Args :: map()) -> ok | {error, term()} | {snooze, pos_integer()}.
-callback max_attempts() -> pos_integer().
-callback queue() -> binary().
-callback priority() -> integer().
-callback timeout() -> pos_integer().
-callback unique() -> unique_opts().
-callback tags() -> [binary()].
-callback backoff(Attempt :: pos_integer(), Error :: term()) -> pos_integer().
-callback rate_limit() -> rate_limit_opts().
-callback concurrency() -> pos_integer().
-callback middleware() -> [shigoto_middleware:middleware()].
-callback on_discard(Args :: map(), Errors :: [map()]) -> ok.

-optional_callbacks([
    max_attempts/0,
    queue/0,
    priority/0,
    timeout/0,
    unique/0,
    tags/0,
    backoff/2,
    rate_limit/0,
    concurrency/0,
    middleware/0,
    on_discard/2
]).

-type unique_opts() :: #{
    keys => [worker | args | queue],
    states => [available | executing | retryable | completed | discarded | cancelled],
    period => pos_integer() | infinity,
    replace => [args | priority | max_attempts | scheduled_at],
    debounce => pos_integer() | undefined
}.

-type rate_limit_opts() :: #{
    limit := pos_integer(),
    window := pos_integer(),
    algorithm => token_bucket | sliding_window | gcra | leaky_bucket,
    burst => pos_integer()
}.

-export_type([unique_opts/0, rate_limit_opts/0]).
