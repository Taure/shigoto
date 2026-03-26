-module(shigoto_notifier).
-moduledoc ~"""
Listens for PostgreSQL NOTIFY events on the `shigoto_jobs_insert` channel
and triggers immediate polling on the relevant queue. Falls back to
regular polling if the notification connection drops.

Requires `notifier` config with database connection details:

```erlang
{shigoto, [
    {pool, my_db},
    {notifier, #{host => "localhost", port => 5432,
                 database => "mydb", user => "postgres", password => "secret"}}
]}
```

Without `notifier` config, this process is not started and shigoto
relies solely on polling.
""".
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    notif_pid :: pid() | undefined,
    ref :: reference() | undefined
}).

-define(CHANNEL, ~"shigoto_jobs_insert").

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    self() ! connect,
    {ok, #state{}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(connect, State) ->
    case start_listener() of
        {ok, Pid, Ref} ->
            {noreply, State#state{notif_pid = Pid, ref = Ref}};
        {error, _} ->
            erlang:send_after(5000, self(), connect),
            {noreply, State#state{notif_pid = undefined, ref = undefined}}
    end;
handle_info({notification, _Pid, _Ref, ?CHANNEL, Payload}, State) ->
    notify_queue(Payload),
    {noreply, State};
handle_info({'DOWN', _Ref, process, _Pid, _Reason}, State) ->
    erlang:send_after(1000, self(), connect),
    {noreply, State#state{notif_pid = undefined, ref = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

start_listener() ->
    Config = shigoto_config:notifier_config(),
    case pgo_notifications:start_link(Config) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            {ok, Ref} = pgo_notifications:listen(Pid, ?CHANNEL),
            {ok, Pid, Ref};
        {error, _} = Err ->
            Err
    end.

notify_queue(Payload) ->
    Queue =
        case Payload of
            <<>> -> ~"default";
            Q -> Q
        end,
    Children = supervisor:which_children(shigoto_queue_sup),
    lists:foreach(
        fun
            ({{shigoto_queue, Q}, Pid, worker, _}) when Q =:= Queue, is_pid(Pid) ->
                Pid ! poll;
            (_) ->
                ok
        end,
        Children
    ).
