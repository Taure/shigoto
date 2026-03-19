-module(shigoto_worker).
-moduledoc ~"""
Behaviour for Shigoto job workers. Implement `perform/1` to handle jobs.

The `perform/1` callback receives the job's args map and should return
`ok` on success or `{error, Reason}` on failure. Failed jobs are retried
with exponential backoff up to `max_attempts`.

## Optional Callbacks

Workers can declare defaults via optional callbacks:

- `max_attempts/0` — Maximum retry attempts (default: 3)
- `queue/0` — Default queue name (default: `<<"default">>`)
- `priority/0` — Default priority (default: 0)
- `timeout/0` — Execution timeout in ms (default: 300000 / 5 min)
- `unique/0` — Uniqueness constraints (see below)

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

## Example

```erlang
-module(cleanup_worker).
-behaviour(shigoto_worker).
-export([perform/1, max_attempts/0, queue/0, timeout/0, unique/0]).

perform(#{<<"days">> := Days}) ->
    delete_old_records(Days),
    ok.

max_attempts() -> 5.
queue() -> <<"maintenance">>.
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

-optional_callbacks([max_attempts/0, queue/0, priority/0, timeout/0, unique/0]).

-type unique_opts() :: #{
    keys => [worker | args | queue],
    states => [available | executing | retryable | completed | discarded | cancelled],
    period => pos_integer() | infinity,
    replace => [args | priority | max_attempts | scheduled_at]
}.
-export_type([unique_opts/0]).
