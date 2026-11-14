-module(shigoto_notifier).
-moduledoc ~"""
Listens for PostgreSQL NOTIFY events on the `shigoto_jobs_insert` channel
(`shigoto_config:notify_channel/0`) and triggers immediate polling on the
relevant queue. Falls back to regular polling if the notification connection
drops.

Any role that can connect to the database can `NOTIFY` on that channel, so a
notification is trusted with nothing. Its payload names a queue; a name that is
no queue on this node is ignored, and a queue is woken at most once per
`notify_min_interval` (10 ms by default), with one poll at the end of the
interval for whatever arrived during it. Nothing else in the payload is read.

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
    listener :: atom() | undefined,
    channel :: binary(),
    queues = {[], undefined} :: {[{binary(), pid()}], integer() | undefined},
    wakes = #{} :: #{binary() => integer() | deferred}
}).

-define(LISTENER, shigoto_listener).
%% How long the list of queue processes is trusted before it is read again.
-define(QUEUES_FOR_MS, 1000).

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    ok = shigoto_db:ignore_sandbox(),
    self() ! connect,
    {ok, #state{channel = shigoto_config:notify_channel()}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(connect, #state{channel = Channel} = State) ->
    case start_listener(Channel) of
        {ok, Listener} ->
            {noreply, State#state{listener = Listener}};
        {error, _Reason} ->
            erlang:send_after(5000, self(), connect),
            {noreply, State#state{listener = undefined}}
    end;
handle_info({minato_notification, Channel, Payload, _From}, #state{channel = Channel} = State) ->
    {noreply, notified(queue_named(Payload), State)};
handle_info({wake, Queue}, State) ->
    {noreply, woken(Queue, State)};
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

start_listener(Channel) ->
    case shigoto_config:notifier_config() of
        undefined ->
            {error, notifier_not_configured};
        Config ->
            case shigoto_db:start_listener(?LISTENER, Config) of
                {ok, Pid} ->
                    erlang:monitor(process, Pid),
                    listening(?LISTENER, Channel);
                {error, _Reason} = Failed ->
                    Failed
            end
    end.

listening(Listener, Channel) ->
    case minato:listen(Listener, Channel) of
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

queue_named(<<>>) -> ~"default";
queue_named(Payload) -> Payload.

%% A notification is a hint from anyone who can connect to the database. All it
%% can do is name a queue this node runs, and all that does is make the queue
%% poll, at most once per `notify_min_interval`: a notification that comes
%% sooner is answered by one poll at the end of the interval, however many of
%% them there are. A name that is no queue here is dropped and not remembered.
-spec notified(binary(), #state{}) -> #state{}.
notified(Queue, #state{wakes = Wakes} = State) ->
    Now = erlang:monotonic_time(millisecond),
    case Wakes of
        #{Queue := deferred} ->
            State;
        #{Queue := Last} when is_integer(Last) ->
            case Now - Last < shigoto_config:notify_min_interval() of
                true ->
                    Wait = shigoto_config:notify_min_interval() - (Now - Last),
                    _ = erlang:send_after(Wait, self(), {wake, Queue}),
                    State#state{wakes = Wakes#{Queue := deferred}};
                false ->
                    woken(Queue, State)
            end;
        #{} ->
            woken(Queue, State)
    end.

-spec woken(binary(), #state{}) -> #state{}.
woken(Queue, State0) ->
    {Queues, State} = queues(State0),
    Wakes = State#state.wakes,
    case lists:keyfind(Queue, 1, Queues) of
        {Queue, Pid} when is_pid(Pid) ->
            Pid ! poll,
            State#state{wakes = Wakes#{Queue => erlang:monotonic_time(millisecond)}};
        _NoSuchQueue ->
            State#state{wakes = maps:remove(Queue, Wakes)}
    end.

%% The supervisor is asked for its queues at most once a second, so a flood of
%% notifications for names that are no queue costs it nothing.
-spec queues(#state{}) -> {[{binary(), pid()}], #state{}}.
queues(#state{queues = {Queues, ReadAt}} = State) ->
    Now = erlang:monotonic_time(millisecond),
    case is_integer(ReadAt) andalso Now - ReadAt < ?QUEUES_FOR_MS of
        true ->
            {Queues, State};
        false ->
            Read = [
                {Queue, Pid}
             || {{shigoto_queue, Queue}, Pid, worker, _} <-
                    supervisor:which_children(shigoto_queue_sup),
                is_binary(Queue),
                is_pid(Pid)
            ],
            {Read, State#state{queues = {Read, Now}}}
    end.
