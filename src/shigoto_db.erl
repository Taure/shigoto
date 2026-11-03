-module(shigoto_db).
-moduledoc """
Every statement shigoto runs goes through here.

The client was called from ten modules directly, which meant changing it was
twenty five edits and a hope. It is one module now, and the rest of shigoto asks
for a query rather than for a driver.

## What a caller gets

`#{command := atom(), num_rows := integer(), rows := [row()]}` for a statement
that ran, and `{error, Reason}` for one that did not, with `{pgsql_error,
Fields}` as the reason a server refused it. That is the shape shigoto already
reads everywhere.

## Transactions

`transaction/2` borrows one connection, runs `BEGIN`, calls the function, and
commits or rolls back. Statements the function runs find that connection here
rather than being handed it, because a job queue's transaction functions are
ordinary code that calls `shigoto_repo` and cannot thread a connection through.

## Sharing a transaction with kura

An app on [kura](https://hex.pm/packages/kura) configures shigoto with
`{repo, Repo}`, and shigoto then runs on the minato pool that `kura_postgres`
started for the repo. That pool is named after the repo unless the repo's kura
config sets `pool`; `repo` must name the pool, so with a `pool` override set
shigoto's `repo` to that name. The two share transactions on that pool, in both
directions, without shigoto depending on kura:

- A statement shigoto runs while the process is inside a kura transaction on a
  pool of the same name (`Repo:transaction/1`, or
  `kura_repo_worker:transaction/2`) runs on that transaction's connection, so a
  job inserted there commits or rolls back with the caller's writes. This
  holds whether shigoto is configured with `repo` or `pool`.
- When the pool is the configured `repo` and `kura_postgres` is loaded,
  `transaction/2` opens the transaction through `kura_driver_minato`, so kura
  writes made inside `shigoto:transaction/1` join it too. With `pool`, it opens
  one of its own, which kura does not see.

Either way a nested call joins the transaction already open. The one opened
through kura behaves as kura's does: a statement in it that commits or rolls it
back raises, and nothing meant for it runs outside it. Whether kura_postgres is
there is decided once (`kura_available/0`).

## When a transaction does not commit

A `COMMIT` the server answers with `ROLLBACK` raises `transaction_rolled_back`.
PostgreSQL does that when the transaction had already failed, and a job queue
that reads it as success has marked jobs done that were never written - which is
the same job running twice on the next poll.

A `COMMIT` the server refuses raises `{shigoto_db, {commit_failed, Reason}}`, and
one that gets no answer (a timeout, a lost connection) raises
`{shigoto_db, {commit_unknown, Reason}}`: whether it committed is not known. A
`BEGIN` that fails raises `{shigoto_db, {begin_failed, Reason}}` before the
function runs. These are the shapes kura_driver_minato uses, and a transaction
opened through kura raises them the same way. A server error keeps only its
`code`, `constraint` and severity, since its message can carry row values.
""".

-include_lib("kernel/include/logger.hrl").

-export([
    query/3,
    query/4,
    transaction/2,
    in_transaction/1,
    transaction_open/1,
    reduced/1,
    kura_available/0,
    start_pool/2,
    start_listener/2
]).

-define(HOLDER, {?MODULE, holder}).
-define(KURA_DRIVER, kura_driver_minato).
-define(KURA_POOL, kura_pool_minato).
-define(KURA_CALLS, [
    {?KURA_DRIVER, query, 5},
    {?KURA_DRIVER, transaction, 4},
    {?KURA_POOL, transaction_conn, 1}
]).
-define(KURA_AVAILABLE, {?MODULE, kura_available}).
-define(DEFAULT_DECODE, #{return_rows_as_maps => true, column_name_as_atom => true}).
-define(CALL_TIMEOUT, 30000).

-doc "The shape a statement answers with.".
-type result() :: #{command := atom(), num_rows := term(), rows := [term()]}.

-doc "What went wrong. `pgsql_error` is the server refusing the statement.".
-type error() :: {pgsql_error, map()} | {socket, term()} | term().

-export_type([result/0, error/0]).

-doc "`query/4` with the default decoding: rows as maps, column names as atoms.".
-spec query(atom(), iodata(), [term()]) -> result() | {error, error()}.
query(Pool, SQL, Params) ->
    query(Pool, SQL, Params, #{}).

-doc """
Run one statement, on this process's transaction if it is inside one.

`Opts` are minato's query options: `timeout` is a deadline after which the
statement is cancelled on the server rather than abandoned, and the decoding
options are the ones `m:minato_protocol` documents.
""".
-spec query(atom(), iodata(), [term()], map()) -> result() | {error, error()}.
query(Pool, SQL, Params, Opts) ->
    case {in_transaction(Pool), kura_transaction(Pool)} of
        {undefined, undefined} ->
            answered(minato:query(Pool, SQL, Params, decoding(Opts)));
        {undefined, _Kura} ->
            kura(?KURA_DRIVER, query, [?KURA_POOL, Pool, SQL, Params, decoding(Opts)]);
        {Holder, _} ->
            ran(Holder, SQL, Params, decoding(Opts))
    end.

-doc """
Run `Fun` inside a transaction on `Pool`.

Nested calls join the transaction that is already open rather than starting a
second one, because SQL has no nested `BEGIN` and the caller usually does not
know whether it is nested.
""".
-spec transaction(atom(), fun(() -> Result)) -> Result.
transaction(Pool, Fun) ->
    case {in_transaction(Pool), kura_transaction(Pool)} of
        {undefined, undefined} -> begun(Pool, Fun);
        _Open -> Fun()
    end.

-doc """
The connection holding this process's transaction on `Pool`, or `undefined`.

Only a transaction `transaction/2` opened on its own; see the moduledoc for one
kura holds.
""".
-spec in_transaction(atom()) -> pid() | undefined.
in_transaction(Pool) ->
    erlang:get({?HOLDER, Pool}).

-doc false.
-spec transaction_open(atom()) -> boolean().
transaction_open(Pool) ->
    in_transaction(Pool) =/= undefined orelse kura_transaction(Pool) =/= undefined.

-doc """
`Reason` with a server error cut down to the fields that cannot carry row values.

A PostgreSQL error's `message` and `detail` can quote the failing row ("Failing
row contains ..."), so a `{pgsql_error, Fields}` keeps only `code`,
`constraint`, `severity` and `severity_non_localised`. Use it on any reason that
is logged or raised. Other reasons are answered as they are.
""".
-spec reduced(term()) -> term().
reduced({pgsql_error, Fields}) when is_map(Fields) ->
    {pgsql_error, maps:with([code, constraint, severity, severity_non_localised], Fields)};
reduced(Reason) ->
    Reason.

-doc """
Start a pool from shigoto's configuration.

Takes what shigoto and its users already write - `host`, `port`, `database`,
`user`, `password`, `pool_size` - and gives minato what it takes.
""".
-spec start_pool(atom(), map()) -> {ok, pid()} | {error, term()}.
start_pool(Name, Config) ->
    {ok, _Started} = application:ensure_all_started(minato),
    Connection = maps:fold(fun connection/3, #{}, Config),
    Opts = #{size => maps:get(pool_size, Config, 10), connection => Connection},
    case minato:start_pool(Name, Opts) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Start a listener for `LISTEN`, on a connection of its own.

`LISTEN` is session state, so it cannot share the pool: a notification is
delivered to the session that registered for it, and a pooled connection would
deliver it to whichever caller happened to hold it next.
""".
-spec start_listener(atom(), map()) -> {ok, pid()} | {error, term()}.
start_listener(Name, Config) ->
    {ok, _Started} = application:ensure_all_started(minato),
    Connection = maps:fold(fun connection/3, #{}, Config),
    case minato:start_listener(Name, #{connection => Connection}) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

%%----------------------------------------------------------------------
%% Transactions
%%----------------------------------------------------------------------

-spec begun(atom(), fun(() -> Result)) -> Result.
begun(Pool, Fun) ->
    case kura_repo(Pool) of
        true -> kura_opened(Pool, Fun);
        false -> opened(Pool, Fun)
    end.

-spec kura_opened(atom(), fun(() -> Result)) -> Result.
kura_opened(Pool, Fun) ->
    try
        kura(?KURA_DRIVER, transaction, [?KURA_POOL, Pool, Fun, #{}])
    catch
        error:{kura_driver_minato, {no_connection, checkout_timeout}} ->
            error({?MODULE, checkout_timeout});
        error:{kura_driver_minato, {Failure, Reason}} when
            Failure =:= no_connection;
            Failure =:= begin_failed;
            Failure =:= commit_failed;
            Failure =:= commit_unknown
        ->
            error({?MODULE, {Failure, Reason}})
    end.

-spec opened(atom(), fun(() -> Result)) -> Result.
opened(Pool, Fun) ->
    Holder = holder(Pool),
    _ = erlang:put({?HOLDER, Pool}, Holder),
    try
        ok = begun_on(Holder),
        committed(Holder, Fun())
    catch
        Class:Reason:Stacktrace ->
            _ = ran(Holder, ~"ROLLBACK", [], #{}),
            erlang:raise(Class, Reason, Stacktrace)
    after
        _ = erlang:erase({?HOLDER, Pool}),
        release(Holder)
    end.

-spec begun_on(pid()) -> ok.
begun_on(Holder) ->
    case ran(Holder, ~"BEGIN", [], #{}) of
        #{command := 'begin'} -> ok;
        Answer -> failed(begin_failed, Answer)
    end.

-spec committed(pid(), Result) -> Result.
committed(Holder, Value) ->
    case ran(Holder, ~"COMMIT", [], #{}) of
        #{command := commit} -> Value;
        #{command := rollback} -> error(transaction_rolled_back);
        {error, {pgsql_error, _}} = Refused -> failed(commit_failed, Refused);
        Unknown -> failed(commit_unknown, Unknown)
    end.

%% The same shapes kura_driver_minato raises, so a transaction fails the same
%% way whichever of the two opened it. A server error keeps only fields that
%% cannot carry row values.
-spec failed(atom(), term()) -> no_return().
failed(Failure, {error, Reason}) ->
    error({?MODULE, {Failure, reduced(Reason)}});
failed(Failure, #{command := Command}) ->
    error({?MODULE, {Failure, {unexpected, Command}}}).

%%----------------------------------------------------------------------
%% Holding one connection for the length of a transaction
%%----------------------------------------------------------------------

-spec holder(atom()) -> pid().
holder(Pool) ->
    Owner = self(),
    Holder = spawn(fun() -> hold(Pool, Owner) end),
    receive
        {holding, Holder} -> Holder;
        {failed, Holder, Reason} -> error({shigoto_db, {no_connection, Reason}})
    after ?CALL_TIMEOUT -> error({shigoto_db, checkout_timeout})
    end.

-spec hold(atom(), pid()) -> ok.
hold(Pool, Owner) ->
    case minato_pool:checkout(Pool, ?CALL_TIMEOUT) of
        {ok, Conn} ->
            Owner ! {holding, self()},
            held(Pool, Conn, erlang:monitor(process, Owner));
        {error, Reason} ->
            Owner ! {failed, self(), Reason},
            ok
    end.

-spec held(atom(), minato_conn:conn(), reference()) -> ok.
held(Pool, Conn, Monitor) ->
    receive
        {run, From, Tag, SQL, Params, Opts} ->
            {Answer, Next} = executed(Conn, SQL, Params, Opts),
            From ! {Tag, Answer},
            held(Pool, Next, Monitor);
        {release, From, Tag} ->
            ok = minato_pool:checkin(Pool, Conn),
            true = erlang:demonitor(Monitor, [flush]),
            From ! {Tag, ok},
            ok;
        {'DOWN', Monitor, process, _Owner, _Reason} ->
            minato_pool:checkin(Pool, Conn)
    end.

-spec executed(minato_conn:conn(), iodata(), [term()], map()) ->
    {result() | {error, error()}, minato_conn:conn()}.
executed(Conn, SQL, Params, Opts) ->
    case minato_query:query(Conn, SQL, Params, Opts) of
        {ok, Result, Next} -> {Result, Next};
        {error, Reason, Next} -> {{error, Reason}, Next};
        {error, Reason} -> {{error, Reason}, Conn}
    end.

-spec ran(pid(), iodata(), [term()], map()) -> result() | {error, error()}.
ran(Holder, SQL, Params, Opts) ->
    Tag = make_ref(),
    Monitor = erlang:monitor(process, Holder),
    Holder ! {run, self(), Tag, SQL, Params, Opts},
    receive
        {Tag, Answer} ->
            true = erlang:demonitor(Monitor, [flush]),
            Answer;
        {'DOWN', Monitor, process, Holder, Reason} ->
            {error, {holder_died, Reason}}
    after ?CALL_TIMEOUT -> {error, timeout}
    end.

-spec release(pid()) -> ok.
release(Holder) ->
    Tag = make_ref(),
    Monitor = erlang:monitor(process, Holder),
    Holder ! {release, self(), Tag},
    receive
        {Tag, ok} ->
            true = erlang:demonitor(Monitor, [flush]),
            ok;
        {'DOWN', Monitor, process, Holder, _Reason} ->
            ok
    after ?CALL_TIMEOUT -> ok
    end.

%%----------------------------------------------------------------------
%% kura, when it is there
%%----------------------------------------------------------------------

-spec kura_transaction(atom()) -> pid() | undefined.
kura_transaction(Pool) ->
    case kura_available() of
        true -> kura(?KURA_POOL, transaction_conn, [Pool]);
        false -> undefined
    end.

-doc """
Whether kura_postgres is there to share transactions with, decided once.

Checks that `kura_driver_minato` and `kura_pool_minato` load and export what
shigoto calls, and keeps the answer. A kura_postgres that loads but lacks one of
them is logged as a warning rather than quietly not shared with. The shigoto
application calls this at start; anything else gets the kept answer.
""".
-spec kura_available() -> boolean().
kura_available() ->
    case persistent_term:get(?KURA_AVAILABLE, undefined) of
        undefined ->
            Available = kura_checked(),
            persistent_term:put(?KURA_AVAILABLE, Available),
            Available;
        Available when is_boolean(Available) ->
            Available
    end.

-spec kura_checked() -> boolean().
kura_checked() ->
    Loaded = [M || M <- [?KURA_DRIVER, ?KURA_POOL], code:ensure_loaded(M) =:= {module, M}],
    Missing = [MFA || {M, F, A} = MFA <- ?KURA_CALLS, not erlang:function_exported(M, F, A)],
    case {Loaded, Missing} of
        {[], _} ->
            false;
        {_, []} ->
            true;
        {_, _} ->
            ?LOG_WARNING(#{
                msg => ~"shigoto_kura_transactions_unavailable",
                missing => Missing,
                action =>
                    ~"shigoto will not share transactions with kura; upgrade kura_postgres"
            }),
            false
    end.

%% Called by name so that kura_postgres stays an optional runtime dependency.
-spec kura(module(), atom(), [term()]) -> dynamic().
kura(Module, Function, Args) ->
    erlang:apply(Module, Function, Args).

-spec kura_repo(atom()) -> boolean().
kura_repo(Pool) ->
    application:get_env(shigoto, repo) =:= {ok, Pool} andalso kura_available().

%%----------------------------------------------------------------------
%% Shapes
%%----------------------------------------------------------------------

-spec answered({ok, result()} | {error, error()}) -> result() | {error, error()}.
answered({ok, Result}) -> Result;
answered({error, Reason}) -> {error, Reason}.

-spec decoding(map()) -> map().
decoding(Opts) ->
    maps:merge(?DEFAULT_DECODE, maps:without([pool, decode_opts], Opts)).

-spec connection(term(), term(), map()) -> map().
connection(host, Value, Connection) -> Connection#{host => text(Value)};
connection(hostname, Value, Connection) -> Connection#{host => text(Value)};
connection(port, Value, Connection) -> Connection#{port => Value};
connection(database, Value, Connection) -> Connection#{database => binary(Value)};
connection(user, Value, Connection) -> Connection#{user => binary(Value)};
connection(username, Value, Connection) -> Connection#{user => binary(Value)};
connection(password, Value, Connection) -> Connection#{password => binary(Value)};
connection(ssl, Value, Connection) -> Connection#{ssl => Value};
connection(ssl_options, Value, Connection) -> Connection#{ssl_options => Value};
connection(socket_options, Value, Connection) -> Connection#{socket_options => Value};
connection(_Key, _Value, Connection) -> Connection.

-spec text(term()) -> string().
text(Value) when is_binary(Value) -> binary_to_list(Value);
text(Value) when is_atom(Value) -> atom_to_list(Value);
text(Value) -> Value.

-spec binary(term()) -> binary().
binary(Value) when is_list(Value) -> list_to_binary(Value);
binary(Value) when is_atom(Value) -> atom_to_binary(Value);
binary(Value) -> Value.
