-module(shigoto_canary_other_worker).
-moduledoc """
A second worker for the security suite: it reports whatever it is run with to
the process named in its args, or to the registered `shigoto_canary_owner`.
""".
-behaviour(shigoto_worker).

-export([perform/1]).

perform(Args) ->
    case whereis(shigoto_canary_owner) of
        undefined -> ok;
        Owner -> Owner ! {performed, ?MODULE, self(), Args}
    end,
    ok.
