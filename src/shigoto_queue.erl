-module(shigoto_queue).
-moduledoc """
Per-queue gen_server that polls for available jobs and dispatches
them to the executor supervisor. Supports graceful shutdown, queue
weights, and pause/resume.

The queue polls on its timer, when it is woken (a notification, the stager)
and, while its last claim left work behind, each time one of its jobs
finishes. A claim that fills every free slot may have left due jobs in the
table, and a poll that had no free slot did not look, so the next free slot
is filled at once instead of at the next tick. Without that a backlog drains
at `concurrency` jobs per `poll_interval`, however fast the jobs are.

At shutdown `terminate/2` waits up to `shutdown_timeout` for the running
executors; nothing is claimed while it waits.
""".
-behaviour(gen_server).

-export([start_link/2, pause/1, resume/1, is_paused/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    queue :: binary(),
    concurrency :: pos_integer(),
    active :: non_neg_integer(),
    pool :: atom(),
    paused :: boolean(),
    backlog :: boolean(),
    executors :: #{pid() => reference()},
    weight :: pos_integer(),
    weight_counter :: non_neg_integer(),
    fair :: boolean(),
    poll_timer :: reference() | undefined
}).

-doc false.
start_link(Queue, Concurrency) ->
    gen_server:start_link(?MODULE, {Queue, Concurrency}, []).

-doc false.
init({Queue, Concurrency}) ->
    ok = shigoto_db:ignore_sandbox(),
    process_flag(trap_exit, true),
    Pool = shigoto_config:pool(),
    Weights = shigoto_config:queue_weights(),
    Weight = maps:get(Queue, Weights, 1),
    FairQueues = shigoto_config:fair_queues(),
    Fair = lists:member(Queue, FairQueues),
    schedule_rescue(),
    {ok,
        schedule_poll(#state{
            queue = Queue,
            concurrency = Concurrency,
            active = 0,
            pool = Pool,
            paused = false,
            backlog = false,
            executors = #{},
            weight = Weight,
            weight_counter = 0,
            fair = Fair,
            poll_timer = undefined
        })}.

-doc "Pause a queue — stops claiming new jobs but lets in-flight jobs finish.".
-spec pause(pid()) -> ok.
pause(Pid) ->
    _ = gen_server:call(Pid, pause),
    ok.

-doc "Resume a paused queue.".
-spec resume(pid()) -> ok.
resume(Pid) ->
    _ = gen_server:call(Pid, resume),
    ok.

-doc "Whether this queue process is currently paused.".
-spec is_paused(pid()) -> boolean().
is_paused(Pid) ->
    gen_server:call(Pid, is_paused) =:= true.

-doc false.
handle_call(pause, _From, State) ->
    {reply, ok, State#state{paused = true}};
handle_call(resume, _From, State) ->
    {reply, ok, State#state{paused = false}};
handle_call(is_paused, _From, #state{paused = Paused} = State) ->
    {reply, Paused, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast({job_finished, _JobId, Pid}, #state{active = Active, executors = Execs} = State) ->
    case Execs of
        #{Pid := Ref} ->
            erlang:demonitor(Ref, [flush]),
            {noreply,
                refilled(State#state{
                    active = one_fewer(Active), executors = maps:remove(Pid, Execs)
                })};
        #{} ->
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(poll, #state{paused = true} = State) ->
    ok = drop_queued_polls(),
    {noreply, schedule_poll(State)};
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
    ok = drop_queued_polls(),
    NewCounter = Counter + 1,
    case should_poll(Weight, NewCounter) of
        false ->
            {noreply, schedule_poll(State#state{weight_counter = NewCounter})};
        true ->
            Available = Conc - Active,
            {NewActive, NewExecs, Backlog} =
                case Available > 0 of
                    true ->
                        case claim(Pool, Queue, Available, Fair) of
                            {ok, Jobs} ->
                                shigoto_telemetry:queue_poll(Queue, length(Jobs)),
                                _ = [shigoto_telemetry:job_claimed(Job) || Job <- Jobs],
                                Execs1 = executing(Jobs, Pool, Execs),
                                Started = map_size(Execs1) - map_size(Execs),
                                {Active + Started, Execs1, length(Jobs) >= Available};
                            {error, _} ->
                                {Active, Execs, true}
                        end;
                    false ->
                        {Active, Execs, true}
                end,
            {noreply,
                schedule_poll(State#state{
                    active = NewActive,
                    executors = NewExecs,
                    backlog = Backlog,
                    weight_counter = NewCounter
                })}
    end;
handle_info(rescue, #state{pool = Pool} = State) ->
    _ = shigoto_repo:rescue_stale_jobs(Pool, shigoto_config:stale_after()),
    _ = shigoto_repo:release_stuck_dependents(Pool),
    _ = shigoto_batch:settle_finished(Pool),
    schedule_rescue(),
    {noreply, State};
handle_info(
    {'DOWN', _Ref, process, Pid, _Reason}, #state{active = Active, executors = Execs} = State
) ->
    case Execs of
        #{Pid := _} ->
            {noreply,
                refilled(State#state{
                    active = one_fewer(Active), executors = maps:remove(Pid, Execs)
                })};
        #{} ->
            {noreply, State}
    end;
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

-spec claim(atom(), binary(), pos_integer(), boolean()) -> {ok, [map()]} | {error, term()}.
claim(Pool, Queue, Limit, true) ->
    shigoto_repo:claim_jobs_fair(Pool, Queue, Limit);
claim(Pool, Queue, Limit, false) ->
    shigoto_repo:claim_jobs(Pool, Queue, Limit).

%% An executor for each claimed job, monitored. A job whose executor does not
%% start stays `executing` in its row until the rescue takes it back.
-spec executing([map()], atom(), #{pid() => reference()}) -> #{pid() => reference()}.
executing([], _Pool, Execs) ->
    Execs;
executing([Job | Jobs], Pool, Execs) ->
    case shigoto_executor_sup:start_executor(Job, Pool, self()) of
        {ok, Pid} -> executing(Jobs, Pool, Execs#{Pid => erlang:monitor(process, Pid)});
        {error, _} -> executing(Jobs, Pool, Execs)
    end.

-spec one_fewer(non_neg_integer()) -> non_neg_integer().
one_fewer(0) -> 0;
one_fewer(Active) -> Active - 1.

%% A slot came free. When the last poll left work behind, or could not look,
%% the queue polls now; `drop_queued_polls/0` makes several slots freed together
%% one poll.
-spec refilled(#state{}) -> #state{}.
refilled(#state{backlog = true, paused = false} = State) ->
    self() ! poll,
    State;
refilled(State) ->
    State.

%% The queue polls on its timer and whenever it is sent `poll` (a notification,
%% the stager). Either way exactly one timer is left pending afterwards: a
%% wake-up restarts the interval, it does not add a timer of its own.
-spec schedule_poll(#state{}) -> #state{}.
schedule_poll(#state{poll_timer = Pending} = State) ->
    _ = cancel_timer(Pending),
    State#state{poll_timer = erlang:send_after(shigoto_config:poll_interval(), self(), poll)}.

cancel_timer(undefined) -> false;
cancel_timer(Timer) -> erlang:cancel_timer(Timer).

%% A burst of notifications is one reason to poll, not one poll each.
-spec drop_queued_polls() -> ok.
drop_queued_polls() ->
    receive
        poll -> drop_queued_polls()
    after 0 -> ok
    end.

schedule_rescue() ->
    erlang:send_after(shigoto_config:rescue_interval(), self(), rescue).

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
