-module(shigoto_lifecycle_worker).
-moduledoc """
A worker the lifecycle suite drives: each run reports to the test process and
does what it is told.
""".
-behaviour(shigoto_worker).

-export([perform/1, backoff/2, on_discard/2]).

perform(#{~"test" := Test, ~"tag" := Tag} = Args) ->
    owner(Test) ! {performing, Tag, self(), Args},
    instructed(Args).

instructed(Args) ->
    receive
        {instruct, Instruction} -> follow(Instruction, Args)
    after 30000 -> {error, no_instruction}
    end.

follow({return, Value}, _Args) ->
    Value;
follow(report_trace, #{~"test" := Test, ~"tag" := Tag} = Args) ->
    owner(Test) ! {trace, Tag, shigoto_fake_propagator:trace()},
    instructed(Args);
follow({insert, Params}, #{~"test" := Test, ~"tag" := Tag} = Args) ->
    {ok, #{id := Id}} = shigoto:insert(Params),
    owner(Test) ! {inserted, Tag, Id},
    instructed(Args);
follow(crash, _Args) ->
    error(deliberate_crash);
follow(no_clause, Args) ->
    only_absent(Args);
follow(die, _Args) ->
    exit(self(), kill).

only_absent(#{~"absent" := _}) -> ok.

backoff(_Attempt, _Error) -> 1.

on_discard(#{~"test" := Test, ~"tag" := Tag} = Args, Errors) ->
    owner(Test) ! {discarded, Tag, Errors},
    discarded(Args).

discarded(#{~"on_discard" := ~"hang", ~"test" := Test, ~"tag" := Tag}) ->
    owner(Test) ! {on_discard_by, Tag, self()},
    receive
        never -> ok
    end;
discarded(#{~"on_discard" := ~"crash"}) ->
    error(deliberate_on_discard_crash);
discarded(_Args) ->
    ok.

owner(Test) -> list_to_pid(binary_to_list(Test)).
