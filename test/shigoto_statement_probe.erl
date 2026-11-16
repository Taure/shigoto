-module(shigoto_statement_probe).
-moduledoc """
What a call hands to `shigoto_db:query/3,4`: every statement with its
parameters, which is what PostgreSQL is sent and its statement log can record.
""".

-export([sent/3]).

-doc """
The answer of `Module:Function` called with `Args`, and the statements it
sent. A process cannot trace itself, so the call runs in one of its own.
""".
-spec sent(module(), atom(), [term()]) -> {term(), [{binary(), [term()]}]}.
sent(Module, Function, Args) ->
    Patterns = [{shigoto_db, query, 3}, {shigoto_db, query, 4}],
    _ = [erlang:trace_pattern(Pattern, true, [global]) || Pattern <- Patterns],
    Owner = self(),
    {Caller, Monitor} = spawn_monitor(fun() ->
        receive
            go -> Owner ! {answered, self(), apply(Module, Function, Args)}
        end
    end),
    _ = erlang:trace(Caller, true, [call]),
    Caller ! go,
    try
        receive
            {answered, Caller, Answer} -> {Answer, traced_calls()};
            {'DOWN', Monitor, process, Caller, Reason} -> ct:fail({call_died, Reason})
        after 10000 -> ct:fail(call_never_answered)
        end
    after
        erlang:demonitor(Monitor, [flush]),
        _ = [erlang:trace_pattern(Pattern, false, [global]) || Pattern <- Patterns]
    end.

-spec traced_calls() -> [{binary(), [term()]}].
traced_calls() ->
    receive
        {trace, _Pid, call, {shigoto_db, query, [_Pool, SQL, Params | _Opts]}} when
            is_list(Params)
        ->
            [{iolist_to_binary(SQL), Params} | traced_calls()]
    after 100 -> []
    end.
