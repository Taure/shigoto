-module(shigoto_log_probe).
-moduledoc "A logger handler that sends each report to the process that attached it.".

-export([attach/0, detach/0, log/2]).

attach() ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{pid => self()}, level => all}).

detach() ->
    _ = logger:remove_handler(?MODULE),
    ok.

log(#{level := Level, msg := {report, Report}}, #{config := #{pid := Pid}}) ->
    Pid ! {log, Level, Report},
    ok;
log(_Event, _Config) ->
    ok.
