-module(shigoto_testing).
-moduledoc """
Test helpers for Shigoto: run workers with no database, and assert on the jobs
your code enqueued.

## Running a worker (`shigoto:perform_job/2,3`)

`shigoto:perform_job/2,3` runs a worker through the exact perform path production
uses (the middleware chain and `deps_results` injection) and returns the raw
worker result, with no database, no queue, no retry, and no resilience gating
(rate limits, circuit breakers, concurrency caps are skipped). It is a pure,
in-process unit-test runner — it must never be used on a production path.

```erlang
ok = shigoto:perform_job(email_worker, #{~"to" => ~"a@b.com"}),
{ok, Total} = shigoto:perform_job(sum_worker, #{~"xs" => [1, 2, 3]}),
%% predecessors' results, exactly as a real dependent would see them:
{ok, _} = shigoto:perform_job(rollup_worker, #{}, #{deps_results => #{41 => #{~"n" => 7}}}).
```

## Testing modes

Set a testing mode so `insert/1,2` and `insert_all/1,2` stop persisting. Both keys
are required — see `shigoto_config:testing_mode/0` for why:

```erlang
application:set_env(shigoto, testing, manual),
application:set_env(shigoto, testing_confirm_no_persistence, true).
```

- `inline` runs each inserted job synchronously and keeps no row. A job that
  returns `{error, _}` raises `{shigoto_inline_job_failed, Worker, Reason}` so
  failures surface loudly in the test.
- `manual` captures inserted jobs in a **process-local** buffer without running
  or persisting them, for the assertions below.

`manual` capture is per-process: it sees enqueues made by the calling process,
not by other processes it spawned. For cross-process expectations, run against a
real test pool (the assertions fall back to querying the pool when not in
`manual` mode) and clean the table between tests.

## Assertions

```erlang
my_code_that_enqueues(),
shigoto_testing:assert_enqueued(#{worker => email_worker}),
shigoto_testing:refute_enqueued(#{queue => ~"sms"}),
[_ | _] = shigoto_testing:all_enqueued().
```

Filters: `worker`, `queue`, `args` (containment), `tags` (containment), `state`.
Call `reset/0` in your test setup to clear the `manual` buffer.
""".

-include_lib("kernel/include/logger.hrl").

-export([
    perform_job/2,
    perform_job/3,
    assert_enqueued/1,
    assert_enqueued/2,
    refute_enqueued/1,
    all_enqueued/0,
    all_enqueued/1,
    reset/0
]).

%% Used by shigoto:insert/2 and insert_all/2 when a testing mode is armed.
-export([handle_insert/3, handle_insert_all/3]).

-define(BUFFER_KEY, '$shigoto_test_enqueued').
-define(SEQ_KEY, '$shigoto_test_seq').
-define(DEFAULT_TIMEOUT, 300000).

%%----------------------------------------------------------------------
%% perform_job — DB-free worker runner
%%----------------------------------------------------------------------

-doc "Run a worker with default job context. See the module doc.".
-spec perform_job(module(), map()) ->
    ok | {ok, term()} | {error, term()} | {snooze, pos_integer()}.
perform_job(Worker, Args) ->
    perform_job(Worker, Args, #{}).

-doc """
Run a worker with extra job context in `Opts`: `deps_results`, `attempt`,
`max_attempts`, `queue`, `id`, `meta`, `tags`, `priority`, `timeout`.
""".
-spec perform_job(module(), map(), map()) ->
    ok | {ok, term()} | {error, term()} | {snooze, pos_integer()}.
perform_job(Worker, Args, Opts) when is_atom(Worker), is_map(Args), is_map(Opts) ->
    ensure_perform_exported(Worker),
    Job = build_test_job(Worker, Args, Opts),
    Timeout = maps:get(timeout, Opts, worker_timeout(Worker)),
    shigoto_executor:run_perform(Job, Worker, Args, Timeout).

ensure_perform_exported(Worker) ->
    _ = code:ensure_loaded(Worker),
    case erlang:function_exported(Worker, perform, 1) of
        true -> ok;
        false -> error({undefined_worker_perform, Worker})
    end.

build_test_job(Worker, Args, Opts) ->
    Job = #{
        id => maps:get(id, Opts, 0),
        worker => Worker,
        queue => maps:get(queue, Opts, worker_default(Worker, queue, ~"default")),
        args => Args,
        attempt => maps:get(attempt, Opts, 1),
        max_attempts => maps:get(max_attempts, Opts, worker_default(Worker, max_attempts, 3)),
        priority => maps:get(priority, Opts, 0),
        tags => maps:get(tags, Opts, []),
        meta => maps:get(meta, Opts, #{})
    },
    case maps:find(deps_results, Opts) of
        {ok, DepsResults} -> Job#{deps_results => DepsResults};
        error -> Job
    end.

%%----------------------------------------------------------------------
%% insert/insert_all in a testing mode (called from shigoto:insert/2)
%%----------------------------------------------------------------------

-doc false.
-spec handle_insert(map(), map(), inline | manual) -> {ok, map()}.
handle_insert(JobParams, _Opts, inline) ->
    run_inline(JobParams);
handle_insert(JobParams, _Opts, manual) ->
    {ok, capture(JobParams)}.

-doc false.
-spec handle_insert_all([map()], map(), inline | manual) -> {ok, [map()]}.
handle_insert_all(JobParamsList, _Opts, inline) ->
    {ok, [element(2, run_inline(P)) || P <- JobParamsList]};
handle_insert_all(JobParamsList, _Opts, manual) ->
    {ok, [capture(P) || P <- JobParamsList]}.

run_inline(JobParams) ->
    Worker = param_worker(JobParams),
    Args = maps:get(args, JobParams, #{}),
    warn_ignored_features(inline, JobParams),
    ensure_perform_exported(Worker),
    Job = job_from_params(JobParams, 1),
    Timeout = worker_timeout(Worker),
    case shigoto_executor:run_perform(Job, Worker, Args, Timeout) of
        ok ->
            {ok, Job#{state => ~"completed", result => null}};
        {ok, Result} ->
            {ok, Job#{state => ~"completed", result => Result}};
        {snooze, Seconds} ->
            {ok, Job#{state => ~"scheduled", snooze => Seconds}};
        {error, Reason} ->
            error({shigoto_inline_job_failed, Worker, Reason})
    end.

capture(JobParams) ->
    warn_ignored_features(manual, JobParams),
    Job = job_from_params(JobParams, 0),
    State =
        case maps:is_key(scheduled_at, JobParams) of
            true -> ~"scheduled";
            false -> ~"available"
        end,
    Stored = Job#{state => State},
    put(?BUFFER_KEY, [Stored | buffer()]),
    Stored.

%% inline additionally ignores scheduled_at (it runs the job now regardless);
%% manual reflects scheduled_at in the captured job's state instead.
warn_ignored_features(Mode, JobParams) ->
    Keys =
        case Mode of
            inline -> [batch, depends_on, unique, scheduled_at];
            manual -> [batch, depends_on, unique]
        end,
    Ignored = [K || K <- Keys, maps:is_key(K, JobParams)],
    case Ignored of
        [] ->
            ok;
        _ ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_testing_mode_ignores_features",
                mode => Mode,
                ignored => Ignored,
                note => ~"these params are no-ops under inline/manual testing modes"
            })
    end.

%% A job map mirroring the shape shigoto_repo returns (worker/queue/state as
%% binaries, args as a map), so assertions match uniformly against the buffer
%% or the database.
job_from_params(JobParams, Attempt) ->
    Worker = param_worker(JobParams),
    #{
        id => next_seq(),
        worker => atom_to_binary(Worker, utf8),
        queue => maps:get(queue, JobParams, worker_default(Worker, queue, ~"default")),
        args => maps:get(args, JobParams, #{}),
        priority => maps:get(priority, JobParams, 0),
        max_attempts => maps:get(max_attempts, JobParams, worker_default(Worker, max_attempts, 3)),
        attempt => Attempt,
        tags => maps:get(tags, JobParams, worker_default(Worker, tags, []))
    }.

param_worker(#{worker := W}) when is_atom(W) -> W;
param_worker(#{worker := W}) when is_binary(W) -> binary_to_existing_atom(W, utf8).

%%----------------------------------------------------------------------
%% Assertions
%%----------------------------------------------------------------------

-doc "All enqueued jobs (manual buffer, or the configured pool otherwise).".
-spec all_enqueued() -> [map()].
all_enqueued() ->
    all_enqueued(#{}).

-doc "Enqueued jobs matching a filter map.".
-spec all_enqueued(map()) -> [map()].
all_enqueued(Filters) when is_map(Filters) ->
    collect(Filters, default).

-doc "Assert at least one enqueued job matches the filter; raises otherwise.".
-spec assert_enqueued(map()) -> ok.
assert_enqueued(Filters) ->
    assert_enqueued(Filters, #{}).

-doc "Assert with options; `#{pool => Pool}` overrides the pool for the DB-backed path.".
-spec assert_enqueued(map(), map()) -> ok.
assert_enqueued(Filters, Opts) when is_map(Filters), is_map(Opts) ->
    PoolSpec = maps:get(pool, Opts, default),
    case collect(Filters, PoolSpec) of
        [_ | _] -> ok;
        [] -> error({assert_enqueued, Filters, redact(collect(#{}, PoolSpec))})
    end.

-doc "Assert NO enqueued job matches the filter; raises with the matches otherwise.".
-spec refute_enqueued(map()) -> ok.
refute_enqueued(Filters) when is_map(Filters) ->
    case collect(Filters, default) of
        [] -> ok;
        Matches -> error({refute_enqueued, Filters, redact(Matches)})
    end.

%% Job args may be sensitive (Shigoto supports encryption-at-rest), and
%% find_jobs returns them decrypted — never let plaintext args land in a raised
%% term that could be logged. Project to non-sensitive identifying fields.
redact(Jobs) ->
    [maps:with([id, worker, queue, state, tags], J) || J <- Jobs].

-doc "Clear the manual-mode capture buffer for the calling process.".
-spec reset() -> ok.
reset() ->
    erase(?BUFFER_KEY),
    erase(?SEQ_KEY),
    ok.

collect(Filters, PoolSpec) ->
    validate_filters(Filters),
    case shigoto_config:testing_mode() of
        manual ->
            [J || J <- lists:reverse(buffer()), matches(Filters, J)];
        inline ->
            %% inline runs jobs and retains nothing, so there is never anything
            %% to assert on — return empty rather than querying a (possibly
            %% unconfigured) pool.
            [];
        _ ->
            Pool = resolve_pool(PoolSpec),
            case shigoto_repo:find_jobs(Pool, Filters) of
                {ok, Jobs} -> Jobs;
                {error, Reason} -> error({shigoto_testing_query_failed, Reason})
            end
    end.

%% Reject unknown filter keys in BOTH backends so a typo fails loudly rather
%% than silently matching everything (manual) or crashing on function_clause (db).
validate_filters(Filters) ->
    case maps:keys(Filters) -- [worker, queue, args, tags, state] of
        [] -> ok;
        Unknown -> error({unknown_filter_key, Unknown})
    end.

resolve_pool(default) -> shigoto_config:pool();
resolve_pool(Pool) -> Pool.

%%----------------------------------------------------------------------
%% Internal: filter matching (mirrors shigoto_repo:find_jobs SQL semantics)
%%----------------------------------------------------------------------

matches(Filters, Job) ->
    maps:fold(
        fun(K, V, Acc) -> Acc andalso match_field(K, V, Job) end,
        true,
        Filters
    ).

match_field(worker, W, Job) ->
    to_bin(W) =:= maps:get(worker, Job, undefined);
match_field(queue, Q, Job) ->
    Q =:= maps:get(queue, Job, undefined);
match_field(state, S, Job) when is_binary(S) ->
    S =:= maps:get(state, Job, undefined);
match_field(state, States, Job) when is_list(States) ->
    lists:member(maps:get(state, Job, undefined), States);
match_field(tags, Tags, Job) when is_list(Tags) ->
    JobTags = maps:get(tags, Job, []),
    lists:all(fun(T) -> lists:member(T, JobTags) end, Tags);
match_field(args, ArgsMatch, Job) when is_map(ArgsMatch) ->
    JobArgs = maps:get(args, Job, #{}),
    maps:fold(
        fun(K, V, Acc) -> Acc andalso maps:get(K, JobArgs, '$absent') =:= V end,
        true,
        ArgsMatch
    );
match_field(_, _, _) ->
    true.

to_bin(W) when is_atom(W) -> atom_to_binary(W, utf8);
to_bin(W) when is_binary(W) -> W.

%%----------------------------------------------------------------------
%% Internal: worker defaults, buffer, sequence
%%----------------------------------------------------------------------

worker_timeout(Worker) ->
    worker_default(Worker, timeout, ?DEFAULT_TIMEOUT).

worker_default(Worker, Fun, Default) ->
    _ = code:ensure_loaded(Worker),
    case erlang:function_exported(Worker, Fun, 0) of
        true ->
            try
                Worker:Fun()
            catch
                _:_ -> Default
            end;
        false ->
            Default
    end.

buffer() ->
    case get(?BUFFER_KEY) of
        undefined -> [];
        List -> List
    end.

next_seq() ->
    N =
        case get(?SEQ_KEY) of
            Prev when is_integer(Prev) -> Prev + 1;
            _ -> 1
        end,
    put(?SEQ_KEY, N),
    N.
