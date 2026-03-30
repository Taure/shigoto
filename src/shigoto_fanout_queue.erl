-module(shigoto_fanout_queue).
-moduledoc """
Fanout queue — every node processes every job. Used for broadcast
events like session revocation, notifications, and cross-node chat.

Unlike the standard queue which uses FOR UPDATE SKIP LOCKED (single
consumer), fanout queues let all nodes read the same jobs. Each node
tracks which job IDs it has already processed in a local ETS table.

Jobs are read within a time window (default 120s). Older jobs are
ignored. On node restart, the ETS is empty so recent jobs within the
window are re-processed — workers must be idempotent.

The source of truth is always the database. Fanout is best-effort
push; if a node misses a job, the client catches up on reconnect.
""".
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_WINDOW, 120).

-record(state, {
    queue :: binary(),
    concurrency :: pos_integer(),
    active :: non_neg_integer(),
    pool :: atom(),
    window :: pos_integer(),
    seen :: ets:table(),
    executors :: #{pid() => reference()},
    paused :: boolean(),
    shutting_down :: boolean()
}).

-spec start_link(binary(), pos_integer(), map()) -> {ok, pid()}.
start_link(Queue, Concurrency, Opts) ->
    gen_server:start_link(?MODULE, {Queue, Concurrency, Opts}, []).

init({Queue, Concurrency, Opts}) ->
    process_flag(trap_exit, true),
    Pool = shigoto_config:pool(),
    Window = maps:get(window, Opts, ?DEFAULT_WINDOW),
    Seen = ets:new(seen_jobs, [set, private]),
    schedule_poll(),
    schedule_cleanup(Window),
    {ok, #state{
        queue = Queue,
        concurrency = Concurrency,
        active = 0,
        pool = Pool,
        window = Window,
        seen = Seen,
        executors = #{},
        paused = false,
        shutting_down = false
    }}.

handle_call(pause, _From, State) ->
    {reply, ok, State#state{paused = true}};
handle_call(resume, _From, State) ->
    {reply, ok, State#state{paused = false}};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({job_finished, _JobId, Pid}, #state{active = Active, executors = Execs} = State) ->
    NewExecs =
        case maps:find(Pid, Execs) of
            {ok, Ref} ->
                erlang:demonitor(Ref, [flush]),
                maps:remove(Pid, Execs);
            error ->
                Execs
        end,
    {noreply, State#state{active = Active - 1, executors = NewExecs}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll, #state{shutting_down = true} = State) ->
    {noreply, State};
handle_info(poll, #state{paused = true} = State) ->
    schedule_poll(),
    {noreply, State};
handle_info(
    poll,
    #state{
        queue = Queue,
        concurrency = Conc,
        active = Active,
        pool = Pool,
        window = Window,
        seen = Seen,
        executors = Execs
    } = State
) ->
    Available = Conc - Active,
    {NewActive, NewExecs} =
        case Available > 0 of
            true ->
                case fetch_recent_jobs(Pool, Queue, Window) of
                    {ok, Jobs} ->
                        Unseen = [J || #{id := Id} = J <- Jobs, not ets:member(Seen, Id)],
                        Take = lists:sublist(Unseen, Available),
                        lists:foreach(
                            fun(#{id := Id}) -> ets:insert(Seen, {Id}) end,
                            Take
                        ),
                        {Started, Execs1} = lists:foldl(
                            fun(Job, {Count, AccExecs}) ->
                                case
                                    shigoto_executor_sup:start_executor(
                                        Job, Pool, self()
                                    )
                                of
                                    {ok, Pid} ->
                                        Ref = erlang:monitor(process, Pid),
                                        {Count + 1, AccExecs#{Pid => Ref}};
                                    {error, _} ->
                                        {Count, AccExecs}
                                end
                            end,
                            {0, Execs},
                            Take
                        ),
                        {Active + Started, Execs1};
                    {error, _} ->
                        {Active, Execs}
                end;
            false ->
                {Active, Execs}
        end,
    schedule_poll(),
    {noreply, State#state{active = NewActive, executors = NewExecs}};
handle_info(cleanup, #state{seen = Seen, pool = Pool, queue = Queue, window = Window} = State) ->
    %% 1. Prune old jobs from the database (older than 2x window)
    PruneSQL =
        <<
            "DELETE FROM shigoto_jobs\n"
            "WHERE queue = $1\n"
            "AND state = 'available'\n"
            "AND inserted_at < now() - make_interval(secs => $2)"
        >>,
    _ = pgo:query(PruneSQL, [Queue, Window * 2], #{pool => Pool}),
    %% 2. Clear ETS dedup set if it gets too large
    case ets:info(Seen, size) > 10000 of
        true -> ets:delete_all_objects(Seen);
        false -> ok
    end,
    schedule_cleanup(Window),
    {noreply, State};
handle_info(
    {'DOWN', _Ref, process, Pid, _Reason}, #state{active = Active, executors = Execs} = State
) ->
    NewExecs = maps:remove(Pid, Execs),
    NewActive = max(0, Active - 1),
    {noreply, State#state{active = NewActive, executors = NewExecs}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{executors = Execs}) ->
    case map_size(Execs) of
        0 -> ok;
        _ -> wait_for_executors(Execs, shigoto_config:shutdown_timeout())
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

fetch_recent_jobs(Pool, Queue, WindowSeconds) ->
    shigoto_repo:fetch_fanout_jobs(Pool, Queue, WindowSeconds).

schedule_poll() ->
    erlang:send_after(shigoto_config:poll_interval(), self(), poll).

schedule_cleanup(Window) ->
    erlang:send_after(Window * 2 * 1000, self(), cleanup).

wait_for_executors(Execs, _Timeout) when map_size(Execs) =:= 0 ->
    ok;
wait_for_executors(_Execs, Timeout) when Timeout =< 0 ->
    ok;
wait_for_executors(Execs, Timeout) ->
    T0 = erlang:monotonic_time(millisecond),
    receive
        {'DOWN', _Ref, process, Pid, _Reason} ->
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            wait_for_executors(maps:remove(Pid, Execs), Timeout - Elapsed)
    after Timeout ->
        ok
    end.
