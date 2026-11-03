-module(shigoto_cron).
-moduledoc """
Cron scheduler. Once a minute it inserts a job for every configured entry that
is due.

One node schedules at a time: each pass runs in a transaction that first takes
`pg_try_advisory_xact_lock`, and a node that does not get it skips the pass.
The minute an entry was last scheduled for is stored in `shigoto_cron`, in the
same transaction as the jobs it inserted, so a pass only schedules minutes after
it. The current minute is PostgreSQL's, not the node's, and the stored minute
only moves forward, so a node whose clock is off cannot make a minute due
again. Two nodes, or a restart within the minute, never schedule the same minute
twice, and a tick that runs late still schedules the minute it missed.

After downtime, an entry with a minute due in the last 60 is scheduled once on
the first pass. An entry seen for the first time is scheduled from the current
minute on.

Jobs go to the worker's `queue/0` when it defines one, and to `default`
otherwise. Each pass runs inside `shigoto:transaction/2`, so `job_inserted`
telemetry for cron jobs fires after the pass commits.

Entries may carry a `timezone` in their `Opts` map (`utc`, an integer hour
offset, a `"+/-N"`/`"UTC"` binary, or a named IANA zone such as
`<<"Europe/Stockholm">>`). Named zones are resolved with DST via `m:shigoto_tz`.
See `shigoto_config:cron_entries/0`.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, schedule_once/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-ifdef(TEST).
-export([to_timezone/2, normalize_entry/1, entry_timezone/1, due_minutes/2]).
-endif.

-define(RETRY_INTERVAL, 1000).
-define(TICK_OFFSET_MS, 1000).
-define(CRON_LOCK_ID, 839274628).
-define(CATCH_UP_MINUTES, 60).
%% Passes in a row that found the lock taken while no node scheduled.
-define(STUCK_PASSES, 5).

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Run one scheduling pass now, in the calling process.

Answers `ok` when the pass ran or another node held the lock, and `retry` when
the pool was not ready. Inside an open shigoto or kura transaction it answers
`{error, in_transaction}` without running, since the pass would join the
caller's transaction and hold the cron lock until it ends. Mainly for tests; the
scheduler runs passes on its own.
""".
-spec schedule_once() -> ok | retry | {error, in_transaction}.
schedule_once() ->
    case shigoto_db:transaction_open(shigoto_config:pool()) of
        true ->
            {error, in_transaction};
        false ->
            case safe_with_leader_lock(fun schedule_due/0) of
                retry -> retry;
                _Ran -> ok
            end
    end.

-doc false.
init([]) ->
    self() ! tick,
    {ok, #{misses => 0}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(tick, State) ->
    case safe_with_leader_lock(fun schedule_due/0) of
        retry ->
            _ = erlang:send_after(?RETRY_INTERVAL, self(), tick),
            {noreply, State};
        Outcome ->
            _ = erlang:send_after(until_next_minute(), self(), tick),
            {noreply, counted(Outcome, State)}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% A pass holds the lock for milliseconds and a dead holder's lock goes with its
%% connection, so a lock taken minute after minute while nothing is scheduled is
%% held by something that is not a shigoto pass.
counted({missed, false}, #{misses := Misses0} = State) ->
    Misses = Misses0 + 1,
    case Misses >= ?STUCK_PASSES andalso (Misses - ?STUCK_PASSES) rem 60 =:= 0 of
        true ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_cron_lock_held_elsewhere",
                lock => ?CRON_LOCK_ID,
                consecutive_misses => Misses,
                action =>
                    ~"no node has scheduled cron while this lock was taken; find the session holding it in pg_locks"
            }),
            shigoto_telemetry:leader_lock_unavailable(cron, Misses);
        false ->
            ok
    end,
    State#{misses := Misses};
counted(failed, State) ->
    State;
counted(_HeldOrProgressing, State) ->
    State#{misses := 0}.

until_next_minute() ->
    NowMs = erlang:system_time(millisecond),
    60000 - (NowMs rem 60000) + ?TICK_OFFSET_MS.

safe_with_leader_lock(Fun) ->
    %% A pool that is not up yet, or is up and cannot reach the database, is a
    %% reason to come back in a second. Anything else is logged and the next
    %% minute tries again, rather than crashing the scheduler every minute.
    try
        with_leader_lock(Fun)
    catch
        exit:{noproc, _} ->
            not_ready();
        error:{shigoto_db, {no_connection, _Reason}} ->
            not_ready();
        error:{shigoto_db, checkout_timeout} ->
            not_ready();
        Class:Reason ->
            ?LOG_WARNING(#{msg => ~"shigoto_cron_pass_failed", class => Class, reason => Reason}),
            failed
    end.

not_ready() ->
    ?LOG_DEBUG(#{msg => ~"shigoto_cron_pool_not_ready"}, #{domain => [shigoto]}),
    retry.

with_leader_lock(Fun) ->
    Pool = shigoto_config:pool(),
    shigoto:transaction(
        fun() ->
            case shigoto_repo:try_advisory_xact_lock(Pool, ?CRON_LOCK_ID) of
                true ->
                    Fun(),
                    held;
                false ->
                    {missed, progressing(Pool)};
                {error, Reason} ->
                    error({shigoto_cron, {lock_failed, shigoto_db:reduced(Reason)}})
            end
        end,
        #{pool => Pool}
    ).

%% Whether a node scheduled the previous minute, so that a missed lock is a peer's
%% pass rather than a lock nobody is using for cron.
progressing(Pool) ->
    case shigoto_config:cron_entries() of
        [] ->
            true;
        _Entries ->
            case shigoto_repo:cron_progressing(Pool) of
                {ok, Progressing} -> Progressing;
                {error, Reason} -> error({shigoto_cron, {read_failed, shigoto_db:reduced(Reason)}})
            end
    end.

schedule_due() ->
    Pool = shigoto_config:pool(),
    case {shigoto_repo:current_minute(Pool), shigoto_repo:get_due_cron_entries(Pool)} of
        {{ok, Now}, {ok, Stored}} ->
            LastRuns = #{N => L || #{name := N, last_scheduled_at := L} <- Stored},
            lists:foreach(
                fun(Entry) -> schedule_entry(Pool, Entry, LastRuns, Now) end,
                shigoto_config:cron_entries()
            );
        {{error, Reason}, _} ->
            error({shigoto_cron, {read_failed, shigoto_db:reduced(Reason)}});
        {_, {error, Reason}} ->
            error({shigoto_cron, {read_failed, shigoto_db:reduced(Reason)}})
    end.

schedule_entry(Pool, Entry, LastRuns, Now) ->
    {Name0, Schedule, Worker, Args} = normalize_entry(Entry),
    Name = entry_name(Name0),
    case shigoto_cron_parser:parse(Schedule) of
        {ok, Expr} ->
            Tz = entry_timezone(Entry),
            LastRun = maps:get(Name, LastRuns, null),
            warn_if_ahead(Name, LastRun, Now),
            Minutes = due_minutes(LastRun, Now),
            case
                lists:any(
                    fun(M) -> shigoto_cron_parser:matches(Expr, to_timezone(M, Tz)) end, Minutes
                )
            of
                true -> insert(Name, Schedule, Worker, Args);
                false -> ok
            end,
            stored(
                shigoto_repo:upsert_cron_entry(Pool, (worker_defaults(Worker))#{
                    name => Name,
                    worker => Worker,
                    args => Args,
                    schedule => Schedule,
                    last_scheduled_at => Now
                })
            );
        {error, Reason} ->
            ?LOG_WARNING(#{msg => ~"shigoto_cron_invalid_schedule", name => Name, reason => Reason})
    end.

%% Stored by a node whose clock ran ahead. Up to an hour ahead the entry waits
%% for that minute; further ahead the upsert puts it back to now.
warn_if_ahead(Name, {_, _} = LastRun, Now) when LastRun > Now ->
    ?LOG_WARNING(#{
        msg => ~"shigoto_cron_last_run_in_future",
        name => Name,
        last_scheduled_at => LastRun,
        now => Now
    });
warn_if_ahead(_Name, _LastRun, _Now) ->
    ok.

insert(Name, Schedule, Worker, Args) ->
    shigoto_telemetry:cron_scheduled(Name, Worker, Schedule),
    case
        shigoto:insert(
            #{worker => Worker, args => Args},
            #{unique => #{keys => [worker, args], period => 60, states => [available, executing]}}
        )
    of
        {ok, _Inserted} -> ok;
        {error, Reason} -> error({shigoto_cron, {insert_failed, Name, shigoto_db:reduced(Reason)}})
    end.

stored(ok) -> ok;
stored({error, Reason}) -> error({shigoto_cron, {store_failed, shigoto_db:reduced(Reason)}}).

worker_defaults(Worker) ->
    _ = code:ensure_loaded(Worker),
    #{
        Key => Worker:Key()
     || Key <- [queue, priority, max_attempts], erlang:function_exported(Worker, Key, 0)
    }.

entry_name(Name) when is_binary(Name) -> Name;
entry_name(Name) when is_atom(Name) -> atom_to_binary(Name);
entry_name(Name) when is_list(Name) -> unicode:characters_to_binary(Name).

minute({Date, {H, M, _S}}) -> {Date, {H, M, 0}}.

%% The minutes after `LastRun` up to and including `Now`, at most the last
%% ?CATCH_UP_MINUTES of them. An entry never scheduled starts at `Now`.
due_minutes(null, Now) ->
    [Now];
due_minutes(LastRun, Now) ->
    NowSecs = calendar:datetime_to_gregorian_seconds(Now),
    LastSecs = calendar:datetime_to_gregorian_seconds(minute(LastRun)),
    FirstSecs = max(LastSecs + 60, NowSecs - (?CATCH_UP_MINUTES - 1) * 60),
    [calendar:gregorian_seconds_to_datetime(S) || S <- seconds(FirstSecs, NowSecs)].

seconds(First, Last) when First > Last -> [];
seconds(First, Last) -> lists:seq(First, Last, 60).

%% Cron entries can be 4-tuple {Name, Schedule, Worker, Args} or
%% 5-tuple {Name, Schedule, Worker, Args, Opts} where Opts is a map
%% with optional timezone key.
normalize_entry({Name, Schedule, Worker, Args}) ->
    {Name, Schedule, Worker, Args};
normalize_entry({Name, Schedule, Worker, Args, _Opts}) ->
    {Name, Schedule, Worker, Args}.

entry_timezone({_Name, _Schedule, _Worker, _Args, #{timezone := Tz}}) ->
    Tz;
entry_timezone(_) ->
    utc.

to_timezone(UtcDatetime, utc) ->
    UtcDatetime;
to_timezone(UtcDatetime, Offset) when is_integer(Offset) ->
    shift(UtcDatetime, Offset * 3600);
to_timezone(UtcDatetime, Bin) when is_binary(Bin) ->
    case parse_offset(Bin) of
        {ok, Hours} ->
            shift(UtcDatetime, Hours * 3600);
        error ->
            case shigoto_tz:offset(Bin, UtcDatetime) of
                {ok, Seconds} ->
                    shift(UtcDatetime, Seconds);
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        msg => ~"shigoto_cron_unknown_timezone",
                        timezone => Bin,
                        reason => Reason
                    }),
                    UtcDatetime
            end
    end;
to_timezone(UtcDatetime, _) ->
    UtcDatetime.

shift(UtcDatetime, Seconds) ->
    Secs = calendar:datetime_to_gregorian_seconds(UtcDatetime),
    calendar:gregorian_seconds_to_datetime(Secs + Seconds).

parse_offset(<<"+", Rest/binary>>) ->
    try
        {ok, binary_to_integer(Rest)}
    catch
        _:_ -> error
    end;
parse_offset(<<"-", Rest/binary>>) ->
    try
        {ok, -binary_to_integer(Rest)}
    catch
        _:_ -> error
    end;
parse_offset(~"UTC") ->
    {ok, 0};
parse_offset(_) ->
    error.
