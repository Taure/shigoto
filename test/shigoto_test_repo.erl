-module(shigoto_test_repo).

-export([start/0, port/0, listen_port/0]).

start() ->
    case
        shigoto_db:start_pool(shigoto_test_pool, #{
            host => "localhost",
            port => port(),
            database => "shigoto_test",
            user => "postgres",
            password => "root",
            pool_size => 5
        })
    of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    application:set_env(shigoto, pool, shigoto_test_pool),
    ok.

port() ->
    list_to_integer(os:getenv("SHIGOTO_TEST_DB_PORT", "5556")).

%% LISTEN needs a session of its own, so behind a pooler in transaction mode the
%% notifier connects to PostgreSQL itself.
listen_port() ->
    list_to_integer(os:getenv("SHIGOTO_TEST_LISTEN_PORT", integer_to_list(port()))).
