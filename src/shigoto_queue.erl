-module(shigoto_queue).
-moduledoc """
Per-queue gen_server that polls for available jobs and dispatches
them to the executor supervisor. Supports graceful shutdown, queue
weights, and pause/resume.
""".
-behaviour(gen_server).

-export([start_link/2, pause/1, resume/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    queue :: binary(),
    concurrency :: pos_integer(),
    active :: non_neg_integer(),
    pool :: atom(),
    paused :: boolean(),
    shutting_down :: boolean(),
    executors :: #{pid() => reference()},
    weight :: pos_integer(),
    weight_counter :: non_neg_integer(),
    fair :: boolean()
}).

-doc false.
start_link(Queue, Concurrency) ->
    gen_server:start_link(?MODULE, {Queue, Concurrency}, []).

-doc false.
init({Queue, Concurrency}) ->
    process_flag(trap_exit, true),
    Pool = shigoto_config:pool(),
    Weights = shigoto_config:queue_weights(),
    Weight = maps:get(Queue, Weights, 1),
    FairQueues = shigoto_config:fair_queues(),
    Fair = lists:member(Queue, FairQueues),
    schedule_poll(),
    schedule_rescue(),
    {ok, #state{
        queue = Queue,
        concurrency = Concurrency,
        active = 0,
        pool = Pool,
        paused = false,
        shutting_down = false,
        executors = #{},
        weight = Weight,
        weight_counter = 0,
        fair = Fair
    }}.

-doc "Pause a queue — stops claiming new jobs but lets in-flight jobs finish.".
-spec pause(pid()) -> ok.
pause(Pid) ->
    gen_server:call(Pid, pause).

-doc "Resume a paused queue.".
-spec resume(pid()) -> ok.
resume(Pid) ->
    gen_server:call(Pid, resume).

-doc false.
handle_call(pause, _From, State) ->
    {reply, ok, State#state{paused = true}};
handle_call(resume, _From, State) ->
    {reply, ok, State#state{paused = false}};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
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

-doc false.
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
        executors = Execs,
        weight = Weight,
        weight_counter = Counter,
        fair = Fair
    } = State
) ->
    NewCounter = Counter + 1,
    case should_poll(Weight, NewCounter) of
        false ->
            schedule_poll(),
            {noreply, State#state{weight_counter = NewCounter}};
        true ->
            Available = Conc - Active,
            {NewActive, NewExecs} =
                case Available > 0 of
                    true ->
                        case claim(Pool, Queue, Available, Fair) of
                            {ok, Jobs} ->
                                shigoto_telemetry:queue_poll(Queue, length(Jobs)),
                                lists:foreach(fun shigoto_telemetry:job_claimed/1, Jobs),
                                {Started, Execs1} = lists:foldl(
                                    fun(Job, {Count, AccExecs}) ->
                                        case
                                            shigoto_executor_sup:start_executor(Job, Pool, self())
                                        of
                                            {ok, Pid} ->
                                                Ref = erlang:monitor(process, Pid),
                                                {Count + 1, AccExecs#{Pid => Ref}};
                                            {error, _} ->
                                                {Count, AccExecs}
                                        end
                                    end,
                                    {0, Execs},
                                    Jobs
                                ),
                                {Active + Started, Execs1};
                            {error, _} ->
                                {Active, Execs}
                        end;
                    false ->
                        {Active, Execs}
                end,
            schedule_poll(),
            {noreply, State#state{
                active = NewActive, executors = NewExecs, weight_counter = NewCounter
            }}
    end;
handle_info(rescue, #state{shutting_down = true} = State) ->
    {noreply, State};
handle_info(rescue, #state{pool = Pool} = State) ->
    StaleSeconds = stale_threshold(),
    _ = shigoto_repo:rescue_stale_jobs(Pool, StaleSeconds),
    schedule_rescue(),
    {noreply, State};
handle_info(
    {'DOWN', _Ref, process, Pid, _Reason}, #state{active = Active, executors = Execs} = State
) ->
    NewExecs = maps:remove(Pid, Execs),
    NewActive = max(0, Active - 1),
    {noreply, State#state{active = NewActive, executors = NewExecs}};
handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #state{executors = Execs}) ->
    case map_size(Execs) of
        0 ->
            ok;
        _ ->
            Timeout = shigoto_config:shutdown_timeout(),
            wait_for_executors(Execs, Timeout)
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

claim(Pool, Queue, Limit, true) ->
    shigoto_repo:claim_jobs_fair(Pool, Queue, Limit);
claim(Pool, Queue, Limit, false) ->
    shigoto_repo:claim_jobs(Pool, Queue, Limit).

schedule_poll() ->
    erlang:send_after(shigoto_config:poll_interval(), self(), poll).

schedule_rescue() ->
    erlang:send_after(60000, self(), rescue).

stale_threshold() ->
    HeartbeatInterval = shigoto_config:heartbeat_interval(),
    HeartbeatInterval * 2 div 1000.

should_poll(1, _Counter) ->
    true;
should_poll(Weight, Counter) ->
    Counter rem Weight =:= 0.

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
