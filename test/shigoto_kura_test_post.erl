-module(shigoto_kura_test_post).
-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0, changeset/1]).

table() -> ~"shigoto_kura_posts".

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true, nullable = false},
        #kura_field{name = title, type = string, nullable = false}
    ].

changeset(Params) ->
    kura_changeset:cast(?MODULE, #{}, Params, [title]).
