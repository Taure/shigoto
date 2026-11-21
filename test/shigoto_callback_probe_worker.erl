-module(shigoto_callback_probe_worker).
-behaviour(shigoto_worker).
-export([perform/1, on_discard/2]).

perform(_Args) -> ok.

on_discard(#{~"tag" := Tag} = Args, _Errors) ->
    shigoto_callbacks_test ! {on_discard, Tag, self()},
    case Args of
        #{~"then" := ~"crash"} ->
            error({deliberate, Args});
        #{~"then" := ~"wait"} ->
            receive
                go -> ok
            end;
        #{} ->
            ok
    end.
