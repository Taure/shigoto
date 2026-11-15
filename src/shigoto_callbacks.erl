-module(shigoto_callbacks).
-moduledoc false.
-behaviour(gen_server).

%% Runs `on_discard/2` away from whoever discarded the job. A job is discarded
%% by an executor, by the rescue and the sweeps, and by whatever process called
%% `shigoto:cancel/1` or `shigoto:discard/1` on a job others wait on: none of
%% them may wait for a callback, or die with it.
%%
%% Each callback runs in a process of its own, linked to this one, at most
%% `max_running` at a time and for at most `on_discard_timeout`. What cannot
%% start yet waits in a backlog of at most `max_pending`; past that a callback
%% is dropped and counted. `on_discard/2` was never guaranteed (a node that
%% dies between the discard and the callback does not run it), so dropping is
%% within the contract, and the alternative is an unbounded mailbox.
%%
%% Without this process (a repo call or a drain while the application is not
%% running) the callback runs before `discarded/1` returns, in a process of
%% its own under the same timeout.

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, start_link/1, discarded/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-define(MAX_RUNNING, 10).
-define(MAX_PENDING, 10000).
-define(DROPPED_REPORT_MS, 5000).

-record(state, {
    max_running :: pos_integer(),
    max_pending :: non_neg_integer(),
    running = #{} :: #{pid() => {reference(), map()}},
    pending = queue:new() :: queue:queue({module(), map()}),
    pending_count = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    report_timer :: reference() | undefined
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(#{max_running => pos_integer(), max_pending => non_neg_integer()}) ->
    gen_server:start_ret().
start_link(Limits) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Limits, []).

%% `Job` is the discarded row, as stored. Its worker is checked here; its
%% args are only decrypted in the process that runs the callback.
-spec discarded(map()) -> ok.
discarded(#{state := ~"discarded"} = Job) ->
    case callback_of(Job) of
        {ok, Worker} -> handed_over(Worker, Job);
        none -> ok
    end;
discarded(_NotDiscarded) ->
    ok.

-spec callback_of(map()) -> {ok, module()} | none.
callback_of(Job) ->
    case shigoto_job:worker(Job) of
        {ok, Worker} ->
            case erlang:function_exported(Worker, on_discard, 2) of
                true -> {ok, Worker};
                false -> none
            end;
        {error, _} ->
            none
    end.

handed_over(Worker, Job) ->
    case whereis(?MODULE) of
        Server when is_pid(Server) ->
            gen_server:cast(Server, {on_discard, Worker, Job});
        _NotRunning ->
            {Pid, Monitor} = spawn_monitor(fun() -> run(Worker, Job) end),
            receive
                {'DOWN', Monitor, process, Pid, Reason} -> ended(Reason, Job)
            after shigoto_config:on_discard_timeout() ->
                exit(Pid, kill),
                erlang:demonitor(Monitor, [flush]),
                ended(timeout, Job)
            end
    end.

init(Limits) ->
    process_flag(trap_exit, true),
    ok = shigoto_db:ignore_sandbox(),
    {ok, #state{
        max_running = maps:get(max_running, Limits, ?MAX_RUNNING),
        max_pending = maps:get(max_pending, Limits, ?MAX_PENDING)
    }}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({on_discard, Worker, Job}, State) when is_atom(Worker), is_map(Job) ->
    {noreply, accepted(Worker, Job, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #state{running = Running} = State) ->
    case Running of
        #{Pid := {Timer, Job}} ->
            _ = erlang:cancel_timer(Timer),
            ok = ended(Reason, Job),
            {noreply, next(State#state{running = maps:remove(Pid, Running)})};
        #{} ->
            {noreply, State}
    end;
handle_info({timeout, Timer, {on_discard, Pid}}, #state{running = Running} = State) ->
    case Running of
        #{Pid := {Timer, Job}} ->
            exit(Pid, kill),
            ok = ended(timeout, Job),
            {noreply, next(State#state{running = maps:remove(Pid, Running)})};
        #{} ->
            {noreply, State}
    end;
handle_info(report_dropped, State) ->
    {noreply, reported(State#state{report_timer = undefined})};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{running = Running, pending_count = Pending} = State) ->
    _ = reported(State),
    case map_size(Running) + Pending of
        0 ->
            ok;
        Left ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_on_discard_abandoned",
                callbacks => Left,
                note => ~"the node is stopping; these on_discard/2 callbacks do not run"
            })
    end.

format_status(#{state := #state{running = Running, pending_count = Pending} = State} = Status) ->
    Status#{
        state := State#state{
            running = #{Pid => {Timer, shigoto_job:redact(Job)} || Pid := {Timer, Job} <- Running},
            pending = queue:new(),
            pending_count = Pending
        }
    };
format_status(Status) ->
    Status.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec accepted(module(), map(), #state{}) -> #state{}.
accepted(Worker, Job, #state{running = Running, max_running = Max} = State) when
    map_size(Running) < Max
->
    started(Worker, Job, State);
accepted(
    Worker, Job, #state{pending_count = Count, max_pending = Max, pending = Pending} = State
) when
    Count < Max
->
    State#state{pending = queue:in({Worker, Job}, Pending), pending_count = Count + 1};
accepted(_Worker, _Job, #state{dropped = Dropped, report_timer = Timer} = State) ->
    State#state{dropped = Dropped + 1, report_timer = report_timer(Timer)}.

report_timer(undefined) -> erlang:send_after(?DROPPED_REPORT_MS, self(), report_dropped);
report_timer(Timer) -> Timer.

-spec started(module(), map(), #state{}) -> #state{}.
started(Worker, Job, #state{running = Running} = State) ->
    Pid = spawn_link(fun() -> run(Worker, Job) end),
    Timer = erlang:start_timer(shigoto_config:on_discard_timeout(), self(), {on_discard, Pid}),
    State#state{running = Running#{Pid => {Timer, Job}}}.

-spec next(#state{}) -> #state{}.
next(#state{pending = Pending, pending_count = Count} = State) ->
    case queue:out(Pending) of
        {{value, {Worker, Job}}, Rest} ->
            started(Worker, Job, State#state{pending = Rest, pending_count = Count - 1});
        {empty, _} ->
            State
    end.

-spec reported(#state{}) -> #state{}.
reported(#state{dropped = 0} = State) ->
    State;
reported(#state{dropped = Dropped} = State) ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_on_discard_dropped",
        callbacks => Dropped,
        note =>
            ~"more on_discard/2 callbacks were waiting than shigoto holds; these were not run"
    }),
    State#state{dropped = 0}.

%% The callback's own process. A raise leaves as an exit reason without the
%% values it failed on, so nothing of the job reaches a crash report.
-spec run(module(), map()) -> ok.
run(Worker, Job) ->
    ok = shigoto_db:ignore_sandbox(),
    case called(Worker, Job) of
        normal -> ok;
        Failed -> exit(Failed)
    end.

called(Worker, #{errors := Errors} = Job) ->
    case shigoto_job:opened(Job) of
        {ok, _Worker, #{args := Args} = Opened} ->
            %% As in the executor, where the callback used to run. Neither is
            %% undone: both go when this process does.
            logger:update_process_metadata(#{
                shigoto_job_id => maps:get(id, Job, undefined),
                shigoto_worker => Worker,
                shigoto_queue => maps:get(queue, Job, undefined),
                shigoto_attempt => maps:get(attempt, Job, 0)
            }),
            _ = shigoto_propagator:attached(shigoto_propagator:carrier(Opened)),
            try Worker:on_discard(Args, decoded_errors(Errors)) of
                _ -> normal
            catch
                Class:Reason -> {raised, shigoto_error:shape({Class, Reason})}
            end;
        {error, Reason} ->
            {unreadable, shigoto_error:shape(Reason)}
    end.

decoded_errors(Errors) when is_binary(Errors) -> json:decode(Errors);
decoded_errors(Errors) -> Errors.

-spec ended(term(), map()) -> ok.
ended(normal, _Job) ->
    ok;
ended(timeout, Job) ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_on_discard_timeout",
        job_id => maps:get(id, Job, undefined),
        worker => maps:get(worker, Job, undefined),
        timeout => shigoto_config:on_discard_timeout(),
        note => ~"the callback was stopped; raise on_discard_timeout if it needs longer"
    }),
    ok;
ended(Reason, Job) ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_on_discard_failed",
        job_id => maps:get(id, Job, undefined),
        worker => maps:get(worker, Job, undefined),
        reason => reason(Reason)
    }),
    ok.

reason({raised, Shape}) -> Shape;
reason({unreadable, Shape}) -> Shape;
reason(Other) -> shigoto_error:shape(Other).
