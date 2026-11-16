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

A listener that cannot be started, a subscription it refuses and a listener
that goes away are all tried again (after 5, 5 and 1 seconds). The first
failure logs `shigoto_notifier_not_listening`; the queues poll throughout.

A `notifier` minato would not connect with, such as `ssl_options` without
`ssl => true`, is not retried into working: the application does not start
with one (`shigoto_config:check/0`). Set that way while the node runs, it is
logged like any other failure, with `{invalid_option, ssl_options}` as the
reason, and no listener is started until the setting is one minato takes.

Requires `notifier` config with database connection details, the keys
`shigoto_db:start_pool/2` reads apart from `pool_size`:

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

-include_lib("kernel/include/logger.hrl").

-record(state, {
    listener :: atom() | undefined,
    channel :: binary(),
    queues = {[], undefined} :: {[{binary(), pid()}], integer() | undefined},
    wakes = #{} :: #{binary() => integer() | deferred},
    watching :: reference() | undefined,
    failing = false :: boolean()
}).

-define(LISTENER, shigoto_listener).
-define(SUBSCRIBE_AGAIN_MS, 5000).
-define(START_AGAIN_MS, 1000).
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
handle_info(connect, #state{channel = Channel} = State0) ->
    case watched(State0) of
        {ok, State} ->
            case subscribed(Channel) of
                ok -> {noreply, State#state{listener = ?LISTENER, failing = false}};
                {error, Reason} -> {noreply, trying_again(Reason, State)}
            end;
        {error, Reason} ->
            {noreply, trying_again(Reason, State0)}
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
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, #state{watching = Monitor} = State) ->
    _ = erlang:send_after(?START_AGAIN_MS, self(), connect),
    {noreply, State#state{listener = undefined, watching = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% The listener, started unless this process already watches one.
-spec watched(#state{}) -> {ok, #state{}} | {error, term()}.
watched(#state{watching = Monitor} = State) when is_reference(Monitor) ->
    {ok, State};
watched(State) ->
    case shigoto_config:notifier_config() of
        undefined ->
            {error, notifier_not_configured};
        Config ->
            case shigoto_db:start_listener(?LISTENER, Config) of
                {ok, Pid} -> {ok, State#state{watching = erlang:monitor(process, Pid)}};
                {error, _Reason} = Failed -> Failed
            end
    end.

%% Whatever the listener answers, and a listener that does not answer or is
%% gone, is a subscription to ask for again. This process never dies of it:
%% restarting in a loop would take the queues down with it, and they poll
%% whether or not anyone listens.
-spec subscribed(binary()) -> ok | {error, term()}.
subscribed(Channel) ->
    try minato:listen(?LISTENER, Channel) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    catch
        exit:Reason -> {error, Reason}
    end.

-spec trying_again(term(), #state{}) -> #state{}.
trying_again(Reason, #state{failing = Failing} = State) ->
    _ = [
        ?LOG_WARNING(#{
            msg => ~"shigoto_notifier_not_listening",
            reason => shigoto_error:shape(Reason),
            retry_ms => ?SUBSCRIBE_AGAIN_MS,
            note => ~"queues poll meanwhile; this is logged once until it listens again"
        })
     || not Failing
    ],
    _ = erlang:send_after(?SUBSCRIBE_AGAIN_MS, self(), connect),
    State#state{listener = undefined, failing = true}.

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
