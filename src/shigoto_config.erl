-module(shigoto_config).
-moduledoc ~"""
Configuration access for Shigoto. Reads from application env.
""".

-export([repo/0, queues/0, poll_interval/0, cron_entries/0, prune_after_days/0]).

-doc "The Kura repo module for job storage.".
-spec repo() -> module().
repo() ->
    {ok, Repo} = application:get_env(shigoto, repo),
    Repo.

-doc "Configured queue names and concurrency. Default: `[{<<\"default\">>, 10}]`.".
-spec queues() -> [{binary(), pos_integer()}].
queues() ->
    application:get_env(shigoto, queues, [{<<"default">>, 10}]).

-doc "Poll interval in milliseconds. Default: 5000.".
-spec poll_interval() -> pos_integer().
poll_interval() ->
    application:get_env(shigoto, poll_interval, 5000).

-doc "Cron job entries. Each: `{Name, Schedule, Worker, Args}`.".
-spec cron_entries() -> list().
cron_entries() ->
    application:get_env(shigoto, cron, []).

-doc "Days to keep completed/discarded jobs. Default: 14.".
-spec prune_after_days() -> pos_integer().
prune_after_days() ->
    application:get_env(shigoto, prune_after_days, 14).
