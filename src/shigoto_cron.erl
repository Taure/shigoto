-module(shigoto_cron).
-moduledoc ~"""
Cron scheduler. Checks configured cron expressions every minute and
inserts jobs for entries that are due.
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
    erlang:send_after(?CHECK_INTERVAL, self(), check),
    {ok, #{}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
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
                    shigoto:insert(
                        #{
                            worker => Worker,
                            args => Args,
                            queue => ~"default"
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

should_run(Schedule, Now) ->
    case shigoto_cron_parser:parse(Schedule) of
        {ok, Expr} ->
            shigoto_cron_parser:matches(Expr, Now);
        {error, _Reason} ->
            false
    end.
