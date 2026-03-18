-module(shigoto_test_repo).
-behaviour(kura_repo).

-export([otp_app/0, start/0]).

otp_app() -> shigoto.

start() ->
    application:set_env(shigoto, shigoto_test_repo, #{
        pool => shigoto_test_repo,
        database => <<"shigoto_test">>,
        hostname => <<"localhost">>,
        port => 5555,
        username => <<"postgres">>,
        password => <<"root">>,
        pool_size => 5
    }),
    application:set_env(shigoto, repo, shigoto_test_repo),
    kura_repo_worker:start(?MODULE).
