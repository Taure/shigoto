-module(shigoto_tagged_worker).
-behaviour(shigoto_worker).
-export([perform/1, tags/0]).

perform(_Args) -> ok.

tags() -> [<<"email">>, <<"notifications">>].
