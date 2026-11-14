-module(shigoto_rescuer).
-moduledoc false.
-behaviour(gen_server).

%% One process per node runs what used to run once per queue: the stale-job
%% rescue, the release of jobs waiting on a job that has ended, and the
%% settling of batches a stopped node left behind. All three statements read
%% the whole installation, so a pass per queue was the same work N times, and
%% every queue of a node fired in the same millisecond.
%%
%% A pass runs under a transaction-scoped advisory try-lock, as the stager's
%% does, so the nodes of a cluster never pass at the same time: a node that
%% finds the lock taken skips its pass. The lock is held by a process of its
%% own while this one runs the statements, each in its own transaction as
%% before. Inside the lock's transaction a batch could not roll its move back
%% on its own (`shigoto_batch:settle/2`), and one failed statement would undo
%% jobs whose callbacks and events had already gone out.
%%
%% A node that runs no queue passes nothing, as before.

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, lock_id/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(LOCK_ID, 839274631).
-define(STUCK_AFTER_MS, 60000).
-define(MIN_STUCK_PASSES, 10).
-define(REPEAT_AFTER_MS, 3600000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec lock_id() -> integer().
lock_id() ->
    ?LOCK_ID.

init([]) ->
    ok = shigoto_db:ignore_sandbox(),
    _ = scheduled(),
    {ok, #{misses => 0}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(pass, State) ->
    Outcome =
        case runs_a_queue() of
            true -> passed();
            false -> idle
        end,
    _ = scheduled(),
    {noreply, counted(Outcome, State)};
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% The nodes of a cluster boot together after a deploy. The jitter spreads
%% their passes so most find the lock free.
scheduled() ->
    Interval = shigoto_config:rescue_interval(),
    erlang:send_after(Interval + rand:uniform(max(1, Interval div 10)), self(), pass).

-spec runs_a_queue() -> boolean().
runs_a_queue() ->
    try supervisor:which_children(shigoto_queue_sup) of
        Children ->
            [Queue || {{shigoto_queue, Queue}, Pid, _Type, _Modules} <- Children, is_pid(Pid)] =/=
                []
    catch
        exit:_ -> false
    end.

-spec passed() -> held | missed | retry.
passed() ->
    Pool = shigoto_config:pool(),
    Rescuer = self(),
    {Holder, Monitor} = spawn_monitor(fun() -> locked(Pool, Rescuer) end),
    receive
        {Holder, held} ->
            try
                swept(Pool)
            after
                Holder ! {Rescuer, pass_over},
                erlang:demonitor(Monitor, [flush])
            end;
        {Holder, Missed} when Missed =:= missed; Missed =:= retry ->
            erlang:demonitor(Monitor, [flush]),
            Missed;
        {'DOWN', Monitor, process, Holder, _Reason} ->
            retry
    end.

%% Holds the lock, in its own process and transaction, until the pass is over
%% or the rescuer is gone.
-spec locked(atom(), pid()) -> ok.
locked(Pool, Rescuer) ->
    ok = shigoto_db:ignore_sandbox(),
    Monitor = erlang:monitor(process, Rescuer),
    shigoto_db:transaction(Pool, fun() ->
        case shigoto_repo:try_advisory_xact_lock(Pool, ?LOCK_ID) of
            true ->
                Rescuer ! {self(), held},
                receive
                    {Rescuer, pass_over} -> ok;
                    {'DOWN', Monitor, process, Rescuer, _Reason} -> ok
                end;
            false ->
                Rescuer ! {self(), missed},
                ok;
            {error, Reason} ->
                ?LOG_WARNING(#{
                    msg => ~"shigoto_rescuer_lock_failed", reason => shigoto_db:reduced(Reason)
                }),
                Rescuer ! {self(), retry},
                ok
        end
    end).

-spec swept(atom()) -> held | retry.
swept(Pool) ->
    try
        _ = shigoto_repo:rescue_stale_jobs(Pool, shigoto_config:stale_after()),
        _ = shigoto_repo:release_stuck_dependents(Pool),
        _ = shigoto_batch:settle_finished(Pool),
        held
    catch
        Class:Reason ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_rescuer_pass_failed",
                reason => shigoto_error:shape({Class, Reason})
            }),
            retry
    end.

counted(missed, #{misses := Misses0} = State) ->
    Misses = Misses0 + 1,
    Threshold = passes_in(?STUCK_AFTER_MS, ?MIN_STUCK_PASSES),
    Repeat = passes_in(?REPEAT_AFTER_MS, 1),
    case Misses >= Threshold andalso (Misses - Threshold) rem Repeat =:= 0 of
        true ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_rescuer_lock_held_elsewhere",
                lock => ?LOCK_ID,
                consecutive_misses => Misses,
                action =>
                    ~"stale jobs are not rescued by this node while the lock is taken; if no node logs rescues, find the session holding it in pg_locks"
            }),
            shigoto_telemetry:leader_lock_unavailable(rescuer, Misses);
        false ->
            ok
    end,
    State#{misses := Misses};
counted(held, State) ->
    State#{misses := 0};
counted(_RetryOrIdle, State) ->
    State.

-spec passes_in(pos_integer(), pos_integer()) -> pos_integer().
passes_in(Ms, Min) ->
    case Ms div shigoto_config:rescue_interval() of
        Passes when Passes > Min -> Passes;
        _Fewer -> Min
    end.
