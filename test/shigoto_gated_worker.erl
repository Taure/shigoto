-module(shigoto_gated_worker).
-moduledoc """
`shigoto_lifecycle_worker` behind a rate limit and a bulkhead, for the cases
that need a worker that declares a resilience gate.
""".
-behaviour(shigoto_worker).

-export([perform/1, backoff/2, rate_limit/0, concurrency/0]).

perform(Args) -> shigoto_lifecycle_worker:perform(Args).

backoff(Attempt, Error) -> shigoto_lifecycle_worker:backoff(Attempt, Error).

rate_limit() -> #{limit => 1000, window => 1000, algorithm => sliding_window}.

concurrency() -> 2.
