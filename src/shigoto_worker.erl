-module(shigoto_worker).
-moduledoc ~"""
Behaviour for Shigoto job workers. Implement `perform/1` to handle jobs.

The `perform/1` callback receives the job's args map and should return
`ok` on success or `{error, Reason}` on failure. Failed jobs are retried
with exponential backoff up to `max_attempts`.

## Example

```erlang
-module(cleanup_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"days">> := Days}) ->
    delete_old_records(Days),
    ok.
```
""".

-callback perform(Args :: map()) -> ok | {error, term()}.
