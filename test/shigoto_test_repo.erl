-module(shigoto_test_repo).

-export([start/0]).

start() ->
    case
        pgo:start_pool(shigoto_test_pool, #{
            host => "localhost",
            port => 5556,
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
