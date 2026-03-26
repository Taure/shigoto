-module(shigoto_middleware).
-moduledoc """
Composable middleware chain for job execution.

Middleware wraps job execution with before/after logic. Each middleware
is a function that receives the job map and a `Next` function. Call `Next()`
to continue the chain, or return early to short-circuit.

## Writing Middleware

```erlang
my_middleware(Job, Next) ->
    %% Before
    logger:info(\"starting job\", #{job_id => maps:get(id, Job)}),
    Result = Next(),
    %% After
    logger:info(\"finished job\", #{job_id => maps:get(id, Job)}),
    Result.
```

## Middleware Order

Built-in middleware runs in this order:
1. Logger metadata (sets structured log context)
2. Seki resilience (rate limit, bulkhead, circuit breaker)
3. Global middleware (from config)
4. Worker middleware (from worker callback)
5. Worker:perform/1
""".

-export([run/3, build_chain/3]).
-export_type([middleware/0, result/0]).

-type middleware() :: fun((map(), fun(() -> result())) -> result()).
-type result() :: ok | {snooze, pos_integer()} | {error, term()}.

-doc "Run the full middleware chain for a job.".
-spec run(map(), module(), fun((map()) -> result())) -> result().
run(Job, Worker, PerformFn) ->
    GlobalMiddleware = shigoto_config:middleware(),
    WorkerMiddleware = resolve_worker_middleware(Worker),
    Chain = GlobalMiddleware ++ WorkerMiddleware,
    Fn = build_chain(Job, Chain, fun() -> PerformFn(Job) end),
    Fn().

-doc "Build a composed function from a middleware list.".
-spec build_chain(map(), [middleware()], fun(() -> result())) -> fun(() -> result()).
build_chain(_Job, [], Final) ->
    Final;
build_chain(Job, [Mw | Rest], Final) ->
    Next = build_chain(Job, Rest, Final),
    fun() -> Mw(Job, Next) end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

resolve_worker_middleware(Worker) ->
    _ = code:ensure_loaded(Worker),
    case erlang:function_exported(Worker, middleware, 0) of
        true -> Worker:middleware();
        false -> []
    end.
