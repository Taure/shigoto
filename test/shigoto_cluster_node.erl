-module(shigoto_cluster_node).
-moduledoc """
Starts shigoto on a node of the two-node suite, the suite's own node or its
peer, with the settings it is given.
""".

-export([start/1]).

-spec start(#{atom() => term()}) -> ok.
start(Env) ->
    {ok, _} = application:ensure_all_started(minato),
    ok = shigoto_test_repo:start(),
    _ = application:load(shigoto),
    _ = [application:set_env(shigoto, Key, Value) || Key := Value <- Env],
    {ok, _} = application:ensure_all_started(shigoto),
    ok.
