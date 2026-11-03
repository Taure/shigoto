-module(shigoto_stager).
-moduledoc """
Latency accelerator for delayed jobs. On a short interval it finds
queues with work due to run now (a job's `scheduled_at` has elapsed,
including a failed job rescheduled after its backoff) and issues a
`pg_notify('shigoto_jobs_insert', Queue)` so the existing notifier
wakes the matching queue immediately instead of waiting up to
`poll_interval`.

Uses `pg_try_advisory_xact_lock` so only one node stages in a
multi-node deployment; the notification still reaches every node.

Started only when the `notifier` is configured. The per-queue polling
fallback remains the correctness backstop; the stager only reduces
latency, and fails soft on any database error so a transient fault
never crashes the supervision tree.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, stage_once/0, due_queues/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(STAGE_LOCK_ID, 839274629).
-define(CHANNEL, ~"shigoto_jobs_insert").
%% A peer holds the lock for one pass, a few milliseconds of each interval, and
%% its ticks drift against ours, so a follower misses now and then but not for a
%% minute on end. At least ten passes, and at least a minute of them.
-define(STUCK_AFTER_MS, 60000).
-define(MIN_STUCK_PASSES, 10).

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    erlang:send_after(shigoto_config:stage_interval(), self(), stage),
    {ok, #{misses => 0}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(stage, State) ->
    Outcome = safe_with_leader_lock(fun stage/0),
    erlang:send_after(shigoto_config:stage_interval(), self(), stage),
    {noreply, counted(Outcome, State)};
handle_info(_Info, State) ->
    {noreply, State}.

-doc "Run one staging pass synchronously (leader-gated). Fails soft. Mainly for testing.".
-spec stage_once() -> ok.
stage_once() ->
    _ = safe_with_leader_lock(fun stage/0),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

counted(missed, #{misses := Misses0} = State) ->
    Misses = Misses0 + 1,
    Threshold = max(?MIN_STUCK_PASSES, ?STUCK_AFTER_MS div shigoto_config:stage_interval()),
    case Misses >= Threshold andalso (Misses - Threshold) rem Threshold =:= 0 of
        true ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_stager_lock_held_elsewhere",
                lock => ?STAGE_LOCK_ID,
                consecutive_misses => Misses,
                action =>
                    ~"staging is not running on any node while this lock is taken; find the session holding it in pg_locks"
            }),
            shigoto_telemetry:leader_lock_unavailable(stager, Misses);
        false ->
            ok
    end,
    State#{misses := Misses};
counted(retry, State) ->
    State;
counted(held, State) ->
    State#{misses := 0}.

safe_with_leader_lock(Fun) ->
    try
        with_leader_lock(Fun)
    catch
        Class:Reason ->
            ?LOG_DEBUG(#{event => stager_tick_failed, class => Class, reason => Reason}),
            retry
    end.

with_leader_lock(Fun) ->
    Pool = shigoto_config:pool(),
    shigoto_db:transaction(Pool, fun() ->
        case shigoto_repo:try_advisory_xact_lock(Pool, ?STAGE_LOCK_ID) of
            true ->
                Fun(),
                held;
            false ->
                missed;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    msg => ~"shigoto_stager_lock_failed", reason => shigoto_db:reduced(Reason)
                }),
                retry
        end
    end).

stage() ->
    Pool = shigoto_config:pool(),
    case due_queues(Pool) of
        {ok, Queues} ->
            lists:foreach(fun(Queue) -> notify(Pool, Queue) end, Queues);
        {error, _} ->
            ok
    end.

-doc "Return the distinct queues with jobs that are due to run right now.".
-spec due_queues(atom()) -> {ok, [binary()]} | {error, term()}.
due_queues(Pool) ->
    SQL =
        ~"""
        SELECT DISTINCT queue FROM shigoto_jobs
        WHERE state = 'available'
        AND scheduled_at <= now()
        AND depends_on = '{}'
        """,
    case shigoto_db:query(Pool, SQL, []) of
        #{rows := Rows} ->
            {ok, [maps:get(queue, Row) || Row <- Rows]};
        {error, _} = Err ->
            Err
    end.

notify(Pool, Queue) ->
    _ = shigoto_db:query(Pool, ~"SELECT pg_notify($1, $2)", [?CHANNEL, Queue]),
    ok.
