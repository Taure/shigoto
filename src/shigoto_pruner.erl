-module(shigoto_pruner).
-moduledoc ~"""
Periodically deletes old completed and discarded jobs.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(PRUNE_INTERVAL, 3600000).

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    erlang:send_after(?PRUNE_INTERVAL, self(), prune),
    {ok, #{}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(prune, State) ->
    RepoMod = shigoto_config:repo(),
    Days = shigoto_config:prune_after_days(),
    shigoto_repo:prune_jobs(RepoMod, Days),
    erlang:send_after(?PRUNE_INTERVAL, self(), prune),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.
