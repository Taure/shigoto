-module(shigoto_cluster_worker).
-moduledoc """
A worker for the two-node suite. Nodes there share nothing but the database, so
it says where it ran in its result, and what it does is decided by the role its
node was started with: a `blocking` node never returns from `perform/1`.
""".
-behaviour(shigoto_worker).

-export([perform/1]).

perform(_Args) ->
    case application:get_env(shigoto, cluster_role, main) of
        blocking -> timer:sleep(infinity);
        Role when is_atom(Role) -> {ok, #{~"ran_on" => atom_to_binary(Role)}}
    end.
