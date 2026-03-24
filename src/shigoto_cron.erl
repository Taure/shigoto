-module(shigoto_cron).
-moduledoc """
Cron scheduler. Checks configured cron expressions every minute and
inserts jobs for entries that are due. On startup, catches up on any
missed intervals since the last run.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHECK_INTERVAL, 60000).

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    self() ! catch_up,
    erlang:send_after(?CHECK_INTERVAL, self(), check),
    {ok, #{}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(catch_up, State) ->
    catch_up_missed(),
    {noreply, State};
handle_info(check, State) ->
    check_cron_entries(),
    erlang:send_after(?CHECK_INTERVAL, self(), check),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

check_cron_entries() ->
    Entries = shigoto_config:cron_entries(),
    Now = calendar:universal_time(),
    lists:foreach(
        fun({_Name, Schedule, Worker, Args}) ->
            case should_run(Schedule, Now) of
                true ->
                    _ = shigoto:insert(
                        #{
                            worker => Worker,
                            args => Args,
                            queue => <<"default">>
                        },
                        #{
                            unique => #{
                                keys => [worker, args],
                                period => 60,
                                states => [available, executing]
                            }
                        }
                    );
                false ->
                    ok
            end
        end,
        Entries
    ).

catch_up_missed() ->
    Pool = shigoto_config:pool(),
    case shigoto_repo:get_due_cron_entries(Pool) of
        {ok, DbEntries} ->
            ConfigEntries = shigoto_config:cron_entries(),
            Now = calendar:universal_time(),
            lists:foreach(
                fun({Name, Schedule, Worker, Args}) ->
                    catch_up_entry(Name, Schedule, Worker, Args, DbEntries, Now)
                end,
                ConfigEntries
            );
        {error, _} ->
            ok
    end.

catch_up_entry(_Name, Schedule, Worker, Args, DbEntries, Now) ->
    case shigoto_cron_parser:parse(Schedule) of
        {ok, Expr} ->
            LastRun = find_last_run(Worker, DbEntries),
            MinutesToCheck = missed_minutes(LastRun, Now),
            lists:foreach(
                fun(Minute) ->
                    case shigoto_cron_parser:matches(Expr, Minute) of
                        true ->
                            _ = shigoto:insert(
                                #{worker => Worker, args => Args, queue => <<"default">>},
                                #{
                                    unique => #{
                                        keys => [worker, args],
                                        period => 60,
                                        states => [available, executing]
                                    }
                                }
                            );
                        false ->
                            ok
                    end
                end,
                MinutesToCheck
            );
        {error, _} ->
            ok
    end.

find_last_run(Worker, DbEntries) ->
    WorkerBin = atom_to_binary(Worker, utf8),
    case [E || E <- DbEntries, maps:get(worker, E) =:= WorkerBin] of
        [#{last_scheduled_at := LastAt}] when LastAt =/= null -> LastAt;
        _ -> undefined
    end.

missed_minutes(undefined, _Now) ->
    [];
missed_minutes(LastRun, Now) ->
    %% Generate minute-aligned datetimes between LastRun and Now, max 60 to avoid flooding
    LastSecs = calendar:datetime_to_gregorian_seconds(LastRun),
    NowSecs = calendar:datetime_to_gregorian_seconds(Now),
    StartSecs = LastSecs + 60,
    MaxMinutes = 60,
    generate_minutes(StartSecs, NowSecs, MaxMinutes, []).

generate_minutes(_Current, _End, 0, Acc) ->
    lists:reverse(Acc);
generate_minutes(Current, End, _Remaining, Acc) when Current > End ->
    lists:reverse(Acc);
generate_minutes(Current, End, Remaining, Acc) ->
    %% Align to minute boundary
    AlignedSecs = (Current div 60) * 60,
    DateTime = calendar:gregorian_seconds_to_datetime(AlignedSecs),
    generate_minutes(AlignedSecs + 60, End, Remaining - 1, [DateTime | Acc]).

should_run(Schedule, Now) ->
    case shigoto_cron_parser:parse(Schedule) of
        {ok, Expr} ->
            shigoto_cron_parser:matches(Expr, Now);
        {error, _Reason} ->
            false
    end.
