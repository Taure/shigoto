-module(shigoto_fake_propagator).
-moduledoc """
A propagator for tests. The context of a process is one binary in its process
dictionary; `raise` and `oversized` in its place make `inject/0` misbehave.
""".
-behaviour(shigoto_propagator).

-export([inject/0, attach/1, detach/1, trace/0, trace/1, clear/0]).

inject() ->
    case get(?MODULE) of
        undefined -> #{};
        raise -> error(deliberate_inject_crash);
        oversized -> #{~"baggage" => binary:copy(~"x", 5000)};
        Trace -> #{~"traceparent" => Trace}
    end.

attach(#{~"traceparent" := ~"unattachable"}) ->
    error(deliberate_attach_crash);
attach(#{~"traceparent" := Trace}) ->
    put(?MODULE, Trace).

detach(undefined) -> erase(?MODULE);
detach(Previous) -> put(?MODULE, Previous).

trace() -> get(?MODULE).

trace(Trace) -> put(?MODULE, Trace).

clear() -> erase(?MODULE).
