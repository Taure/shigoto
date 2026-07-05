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

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    erlang:send_after(shigoto_config:stage_interval(), self(), stage),
    {ok, #{}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(stage, State) ->
    _ =
        case safe_with_leader_lock(fun stage/0) of
            ok -> ok;
            retry -> ok
        end,
    erlang:send_after(shigoto_config:stage_interval(), self(), stage),
    {noreply, State};
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

safe_with_leader_lock(Fun) ->
    try
        with_leader_lock(Fun),
        ok
    catch
        Class:Reason ->
            ?LOG_DEBUG(#{event => stager_tick_failed, class => Class, reason => Reason}),
            retry
    end.

with_leader_lock(Fun) ->
    Pool = shigoto_config:pool(),
    pgo:transaction(
        fun() ->
            case
                pgo:query(
                    ~"SELECT pg_try_advisory_xact_lock($1)::text",
                    [?STAGE_LOCK_ID],
                    #{pool => Pool}
                )
            of
                #{rows := [{~"true"}]} ->
                    Fun();
                _ ->
                    ok
            end
        end,
        #{pool => Pool}
    ).

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
    case
        pgo:query(SQL, [], #{
            pool => Pool, decode_opts => [return_rows_as_maps, column_name_as_atom]
        })
    of
        #{rows := Rows} ->
            {ok, [maps:get(queue, Row) || Row <- Rows]};
        {error, _} = Err ->
            Err
    end.

notify(Pool, Queue) ->
    _ = pgo:query(~"SELECT pg_notify($1, $2)", [?CHANNEL, Queue], #{pool => Pool}),
    ok.
