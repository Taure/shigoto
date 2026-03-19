-module(shigoto_configured_worker).
-behaviour(shigoto_worker).

-export([perform/1, max_attempts/0, queue/0, priority/0]).

max_attempts() -> 7.
queue() -> ~"priority_queue".
priority() -> 5.

perform(_Args) ->
    ok.
