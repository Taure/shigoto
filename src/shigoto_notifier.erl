-module(shigoto_notifier).
-moduledoc ~"""
Listens for PostgreSQL NOTIFY events on the `shigoto_jobs_insert` channel
and triggers immediate polling on the relevant queue. Falls back to
regular polling if the notification connection drops.

A notification is an optimisation, never the only path: `NOTIFY` has no replay,
so anything published while the listener was away is gone. minato says when that
happened, and this process answers it by polling every queue once, which is the
catch up the missed notifications would have caused.

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
    listener :: atom() | undefined
}).

-define(LISTENER, shigoto_listener).

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
        {ok, Listener} ->
            {noreply, State#state{listener = Listener}};
        {error, _Reason} ->
            erlang:send_after(5000, self(), connect),
            {noreply, State#state{listener = undefined}}
    end;
handle_info({minato_notification, ?CHANNEL, Payload, _From}, State) ->
    notify_queue(Payload),
    {noreply, State};
handle_info({minato_listener, _Name, resubscribed}, State) ->
    %% The listener was away, and NOTIFY has no replay: poll everything once
    %% rather than wait for a notification that already happened.
    notify_every_queue(),
    {noreply, State};
handle_info({'DOWN', _Ref, process, _Pid, _Reason}, State) ->
    erlang:send_after(1000, self(), connect),
    {noreply, State#state{listener = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

start_listener() ->
    Config = shigoto_config:notifier_config(),
    case shigoto_db:start_listener(?LISTENER, Config) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            listening(?LISTENER);
        {error, _Reason} = Failed ->
            Failed
    end.

listening(Listener) ->
    case minato:listen(Listener, ?CHANNEL) of
        ok -> {ok, Listener};
        {error, _Reason} = Failed -> Failed
    end.

notify_every_queue() ->
    lists:foreach(
        fun
            ({{shigoto_queue, _Queue}, Pid, worker, _}) when is_pid(Pid) -> Pid ! poll;
            (_Other) -> ok
        end,
        supervisor:which_children(shigoto_queue_sup)
    ).

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
