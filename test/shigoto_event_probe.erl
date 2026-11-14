-module(shigoto_event_probe).
-moduledoc """
Captures everything that leaves the node while a job runs: every logger event
with its metadata, and every shigoto telemetry event. Both are sent whole to
the process that attached.
""".

-export([attach/0, detach/0, log/2, forward/4, captured/0]).

-define(EVENTS, [
    [shigoto, job, inserted],
    [shigoto, job, claimed],
    [shigoto, job, completed],
    [shigoto, job, failed],
    [shigoto, job, snoozed],
    [shigoto, job, discarded],
    [shigoto, job, cancelled],
    [shigoto, job, progress],
    [shigoto, job, lost],
    [shigoto, job, transition_failed],
    [shigoto, job, rescued],
    [shigoto, queue, poll],
    [shigoto, resilience, rate_limited],
    [shigoto, resilience, circuit_open],
    [shigoto, resilience, bulkhead_full],
    [shigoto, resilience, load_shed],
    [shigoto, resilience, gate_failed],
    [shigoto, batch, completed]
]).

attach() ->
    _ = logger:set_application_level(shigoto, all),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{pid => self()}, level => all}),
    ok = telemetry:attach_many(?MODULE, ?EVENTS, fun ?MODULE:forward/4, self()).

detach() ->
    _ = logger:unset_application_level(shigoto),
    _ = logger:remove_handler(?MODULE),
    _ = telemetry:detach(?MODULE),
    ok.

log(Event, #{config := #{pid := Pid}}) ->
    Pid ! {captured, {log, Event}},
    ok.

forward(Event, Measurements, Metadata, Owner) ->
    Owner ! {captured, {telemetry, Event, Measurements, Metadata}},
    ok.

-doc "Everything captured so far, oldest first.".
captured() ->
    receive
        {captured, Captured} -> [Captured | captured()]
    after 0 -> []
    end.
