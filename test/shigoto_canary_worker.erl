-module(shigoto_canary_worker).
-moduledoc """
A worker for the security suite. Each run reports to the test process, then
fails in the way its args ask for, with the canary from its args in the
failure wherever the failure can carry a value.
""".
-behaviour(shigoto_worker).

-export([perform/1, backoff/2, on_discard/2, middleware/0, modes/0]).

-doc "Every way `perform/1` can fail with the canary in the failure.".
modes() ->
    [
        ~"badmatch",
        ~"case_clause",
        ~"function_clause",
        ~"badkey",
        ~"badmap",
        ~"badarg",
        ~"undef",
        ~"error_term",
        ~"error_binary",
        ~"throw",
        ~"exit",
        ~"return_error",
        ~"return_error_tuple",
        ~"nonsense",
        ~"linked_exit",
        ~"middleware_crash"
    ].

perform(#{~"test" := Test, ~"mode" := Mode} = Args) ->
    owner(Test) ! {performed, ?MODULE, self(), Args},
    acted(Mode, Args).

acted(~"ok", _Args) ->
    ok;
acted(~"result", #{~"canary" := Canary}) ->
    {ok, #{~"secret" => Canary}};
acted(~"wait", _Args) ->
    receive
        {instruct, Value} -> Value
    after 30000 -> {error, no_instruction}
    end;
acted(~"badmatch", #{~"canary" := Canary}) ->
    ok = identity(Canary);
acted(~"case_clause", #{~"canary" := Canary}) ->
    case identity(Canary) of
        never -> ok
    end;
acted(~"function_clause", Args) ->
    only_absent(Args);
acted(~"badkey", #{~"canary" := Canary}) ->
    maps:get(Canary, #{});
acted(~"badmap", #{~"canary" := Canary}) ->
    maps:get(key, identity(Canary));
acted(~"badarg", #{~"canary" := Canary}) ->
    binary_to_integer(Canary);
acted(~"undef", Args) ->
    Module = shigoto_no_such_module,
    Module:call(Args);
acted(~"error_term", #{~"canary" := Canary}) ->
    error({failed_for, Canary, #{value => Canary}});
acted(~"error_binary", #{~"canary" := Canary}) ->
    error(Canary);
acted(~"throw", #{~"canary" := Canary}) ->
    throw(Canary);
acted(~"exit", #{~"canary" := Canary}) ->
    exit({stopped_with, Canary});
acted(~"return_error", #{~"canary" := Canary}) ->
    {error, Canary};
acted(~"return_error_tuple", #{~"canary" := Canary}) ->
    {error, {rejected, Canary, [Canary]}};
acted(~"nonsense", #{~"canary" := Canary}) ->
    {done, Canary};
acted(~"linked_exit", #{~"canary" := Canary}) ->
    _ = spawn_link(fun() -> exit({linked, Canary}) end),
    receive
    after 5000 -> ok
    end.

identity(Value) -> Value.

only_absent(#{~"absent" := _}) -> ok.

middleware() ->
    [
        fun
            (#{args := #{~"mode" := ~"middleware_crash"} = Args}, _Next) ->
                error({middleware_failed, Args});
            (_Job, Next) ->
                Next()
        end
    ].

backoff(_Attempt, _Error) -> 1.

on_discard(#{~"test" := Test} = Args, Errors) ->
    owner(Test) ! {discarded, ?MODULE, Args, Errors},
    ok.

owner(Test) -> list_to_pid(binary_to_list(Test)).
