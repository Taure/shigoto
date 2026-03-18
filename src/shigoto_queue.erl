-module(shigoto_queue).
-moduledoc ~"""
Per-queue gen_server that polls for available jobs and dispatches
them to the executor supervisor.
""".
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    queue :: binary(),
    concurrency :: pos_integer(),
    active :: non_neg_integer(),
    repo :: module()
}).

-doc false.
start_link(Queue, Concurrency) ->
    gen_server:start_link(?MODULE, {Queue, Concurrency}, []).

-doc false.
init({Queue, Concurrency}) ->
    Repo = shigoto_config:repo(),
    schedule_poll(),
    schedule_rescue(),
    {ok, #state{
        queue = Queue,
        concurrency = Concurrency,
        active = 0,
        repo = Repo
    }}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast({job_finished, _JobId}, #state{active = Active} = State) ->
    {noreply, State#state{active = Active - 1}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(poll, #state{queue = Queue, concurrency = Conc, active = Active, repo = Repo} = State) ->
    Available = Conc - Active,
    NewActive =
        case Available > 0 of
            true ->
                case shigoto_repo:claim_jobs(Repo, Queue, Available) of
                    {ok, Jobs} ->
                        lists:foreach(
                            fun(Job) ->
                                shigoto_executor_sup:start_executor(Job, Repo, self())
                            end,
                            Jobs
                        ),
                        Active + length(Jobs);
                    {error, _} ->
                        Active
                end;
            false ->
                Active
        end,
    schedule_poll(),
    {noreply, State#state{active = NewActive}};
handle_info(rescue, #state{repo = Repo} = State) ->
    _ = shigoto_repo:rescue_stale_jobs(Repo, 300),
    schedule_rescue(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

schedule_poll() ->
    erlang:send_after(shigoto_config:poll_interval(), self(), poll).

schedule_rescue() ->
    erlang:send_after(60000, self(), rescue).
