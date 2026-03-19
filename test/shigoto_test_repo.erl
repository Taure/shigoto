-module(shigoto_test_repo).

-export([start/0]).

start() ->
    {ok, _} = pgo:start_pool(shigoto_test_pool, #{
        host => "localhost",
        port => 5555,
        database => "shigoto_test",
        user => "postgres",
        password => "root",
        pool_size => 5
    }),
    application:set_env(shigoto, pool, shigoto_test_pool),
    ok.
