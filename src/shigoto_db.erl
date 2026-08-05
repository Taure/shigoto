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

A `COMMIT` the server answers with `ROLLBACK` raises `transaction_rolled_back`.
PostgreSQL does that when the transaction had already failed, and a job queue
that reads it as success has marked jobs done that were never written - which is
the same job running twice on the next poll.
""".

-export([
    query/3,
    query/4,
    transaction/2,
    in_transaction/1,
    start_pool/2,
    start_listener/2
]).

-define(HOLDER, {?MODULE, holder}).
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
    case in_transaction(Pool) of
        undefined -> answered(minato:query(Pool, SQL, Params, decoding(Opts)));
        Holder -> ran(Holder, SQL, Params, decoding(Opts))
    end.

-doc """
Run `Fun` inside a transaction on `Pool`.

Nested calls join the transaction that is already open rather than starting a
second one, because SQL has no nested `BEGIN` and the caller usually does not
know whether it is nested.
""".
-spec transaction(atom(), fun(() -> Result)) -> Result.
transaction(Pool, Fun) ->
    case in_transaction(Pool) of
        undefined -> opened(Pool, Fun);
        _Holder -> Fun()
    end.

-doc "The connection holding this process's transaction on `Pool`, or `undefined`.".
-spec in_transaction(atom()) -> pid() | undefined.
in_transaction(Pool) ->
    erlang:get({?HOLDER, Pool}).

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

-spec opened(atom(), fun(() -> Result)) -> Result.
opened(Pool, Fun) ->
    Holder = holder(Pool),
    _ = erlang:put({?HOLDER, Pool}, Holder),
    try
        _ = ran(Holder, ~"BEGIN", [], #{}),
        committed(Holder, Fun())
    catch
        Class:Reason:Stacktrace ->
            _ = ran(Holder, ~"ROLLBACK", [], #{}),
            erlang:raise(Class, Reason, Stacktrace)
    after
        _ = erlang:erase({?HOLDER, Pool}),
        release(Holder)
    end.

-spec committed(pid(), Result) -> Result.
committed(Holder, Value) ->
    case ran(Holder, ~"COMMIT", [], #{}) of
        #{command := rollback} -> error(transaction_rolled_back);
        _Committed -> Value
    end.

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
