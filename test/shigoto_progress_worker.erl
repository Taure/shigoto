-module(shigoto_progress_worker).
-behaviour(shigoto_worker).
-export([perform/1]).

perform(#{<<"job_id">> := JobId}) ->
    shigoto:report_progress(JobId, 25),
    shigoto:report_progress(JobId, 50),
    shigoto:report_progress(JobId, 75),
    shigoto:report_progress(JobId, 100),
    ok;
perform(_Args) ->
    ok.
