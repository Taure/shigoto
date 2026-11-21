-module(shigoto_overflow_worker).
-behaviour(shigoto_worker).

-export([perform/1, max_attempts/0]).

perform(_Args) -> ok.

max_attempts() -> 3000000000.
