-module(shigoto_test_repo).

-export([start/0, port/0]).

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
