-module(shigoto_migrator).
-moduledoc """
Brings the schema up to date at boot, and holds the queues back until it is.

`boot/1` runs `shigoto_migration:up/1` up to 5 times, 1 to 5 seconds apart
(jittered, so nodes that boot together do not retry in step). When the schema
is still not current, the application starts without its queues, logs
`shigoto_migration_pending` at error level, emits
`[shigoto, migration, pending]`, and this process retries every 30 seconds.
Once the migration succeeds it starts the queues and stops.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([boot/1, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(BOOT_ATTEMPTS, 5).
-define(RETRY_INTERVAL, 30000).

-doc "Migrate `Pool` at boot. Answers whether the schema is current.".
-spec boot(atom()) -> boolean().
boot(Pool) ->
    boot(Pool, 1).

boot(Pool, Attempt) ->
    case shigoto_migration:up(Pool) of
        ok ->
            true;
        {error, Reason} when Attempt < ?BOOT_ATTEMPTS ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_migration_failed",
                pool => Pool,
                attempt => Attempt,
                reason => Reason
            }),
            timer:sleep(999 + rand:uniform(4001)),
            boot(Pool, Attempt + 1);
        {error, Reason} ->
            pending(Pool, Reason),
            false
    end.

-doc false.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    retry_later(),
    {ok, #{}}.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
handle_cast(_Msg, State) ->
    {noreply, State}.

-doc false.
handle_info(retry, State) ->
    Pool = shigoto_config:pool(),
    case shigoto_migration:up(Pool) of
        ok ->
            ?LOG_NOTICE(#{msg => ~"shigoto_migration_completed", pool => Pool}),
            ok = shigoto_sup:start_queues(),
            {stop, normal, State};
        {error, Reason} ->
            pending(Pool, Reason),
            retry_later(),
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

retry_later() ->
    _ = erlang:send_after(?RETRY_INTERVAL, self(), retry),
    ok.

pending(Pool, Reason) ->
    ?LOG_ERROR(#{
        msg => ~"shigoto_migration_pending",
        pool => Pool,
        reason => Reason,
        action =>
            ~"queues stay stopped until the schema is current; retrying every 30 s, or call shigoto_migration:up/1"
    }),
    shigoto_telemetry:migration_pending(Reason).
