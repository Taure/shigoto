-module(shigoto_migrator).
-moduledoc """
Brings the schema up to date at boot, and holds the queues back until it is.

`boot/1` runs `shigoto_migration:up/1` up to 5 times, 1 to 5 seconds apart
(jittered, so nodes that boot together do not retry in step). An error a retry
cannot fix (SQLSTATE class 42, such as `42501 insufficient_privilege`) skips the
remaining attempts. When the schema is still not current, the application
starts with an empty queue supervisor, logs `shigoto_migration_pending` at error
level, emits `[shigoto, migration, pending]`, and this process retries every 30
seconds. `retry_now/0` asks for a retry at once, for example right after
running `shigoto_migration:up/1` by hand.

While it waits, `shigoto:add_queue/2` answers `{error, migration_pending}` and
`shigoto:health/0` answers `{error, #{reason => migration_pending}}`.

Once the migration succeeds it starts the configured queues in the queue
supervisor and stops normally. A queue that fails to start then is logged as
`shigoto_queue_start_failed` at error level with the queue name and reason, and
emits `[shigoto, queue, start_failed]`; the other queues still start. (On a
normal boot the same bad queue config fails the application start instead.)

After it stops, its child spec stays in `shigoto_sup`, so
`supervisor:which_children(shigoto_sup)` lists `shigoto_migrator` with pid
`undefined`. Being `transient`, it is not restarted.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([boot/1, retry_now/0, pending/0, held_back/0, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(BOOT_ATTEMPTS, 5).
-define(RETRY_INTERVAL, 30000).
-define(PENDING, {?MODULE, pending}).

-doc "Migrate `Pool` at boot. Answers whether the schema is current.".
-spec boot(atom()) -> boolean().
boot(Pool) ->
    Current = boot(Pool, 1),
    persistent_term:put(?PENDING, not Current),
    Current.

boot(Pool, Attempt) ->
    case shigoto_migration:up(Pool) of
        ok ->
            true;
        {error, Reason} ->
            case Attempt < ?BOOT_ATTEMPTS andalso retryable(Reason) of
                true ->
                    ?LOG_WARNING(#{
                        msg => ~"shigoto_migration_failed",
                        pool => Pool,
                        attempt => Attempt,
                        reason => Reason
                    }),
                    timer:sleep(999 + rand:uniform(4001)),
                    boot(Pool, Attempt + 1);
                false ->
                    report_pending(Pool, Reason),
                    false
            end
    end.

retryable({pgsql_error, #{code := <<"42", _/binary>>}}) -> false;
retryable(_Reason) -> true.

-doc """
Retry the migration now instead of at the next 30 second tick.

Retries asked for while one is queued or running are coalesced into one.

Answers `not_running` when no migration is pending.
""".
-spec retry_now() -> ok | not_running.
retry_now() ->
    case whereis(?MODULE) of
        undefined ->
            not_running;
        Pid ->
            Pid ! retry,
            ok
    end.

-doc false.
-spec pending() -> boolean().
pending() ->
    held_back() andalso is_pid(whereis(?MODULE)).

%% Read by shigoto_queue_sup:init/1, which starts before this process.
-doc false.
-spec held_back() -> boolean().
held_back() ->
    persistent_term:get(?PENDING, false) =:= true.

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    ok = shigoto_db:ignore_sandbox(),
    {ok, #{timer => retry_later()}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(retry, #{timer := Timer} = State) ->
    _ = erlang:cancel_timer(Timer),
    flush_retries(),
    Pool = shigoto_config:pool(),
    case shigoto_migration:up(Pool) of
        ok ->
            ?LOG_NOTICE(#{msg => ~"shigoto_migration_completed", pool => Pool}),
            persistent_term:put(?PENDING, false),
            lists:foreach(
                fun start_queue/1, shigoto_queue_sup:child_specs(shigoto_config:queues())
            ),
            {stop, normal, State};
        {error, Reason} ->
            report_pending(Pool, Reason),
            {noreply, State#{timer := retry_later()}}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

start_queue(#{id := {_Kind, Queue}} = Spec) ->
    case supervisor:start_child(shigoto_queue_sup, Spec) of
        {ok, _Pid} ->
            ok;
        {ok, _Pid, _Info} ->
            ok;
        {error, {already_started, _Pid}} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{msg => ~"shigoto_queue_start_failed", queue => Queue, reason => Reason}),
            shigoto_telemetry:queue_start_failed(Queue, Reason)
    end.

%% Retries asked for while one ran are answered by the next one.
flush_retries() ->
    receive
        retry -> flush_retries()
    after 0 -> ok
    end.

retry_later() ->
    erlang:send_after(?RETRY_INTERVAL, self(), retry).

report_pending(Pool, Reason) ->
    ?LOG_ERROR(#{
        msg => ~"shigoto_migration_pending",
        pool => Pool,
        reason => Reason,
        action =>
            ~"queues stay stopped until the schema is current; retrying every 30 s, or run shigoto_migration:up/1 and then shigoto_migrator:retry_now/0"
    }),
    shigoto_telemetry:migration_pending(Reason).
