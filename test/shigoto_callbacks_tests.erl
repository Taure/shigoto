-module(shigoto_callbacks_tests).
-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

callbacks_test_() ->
    {foreach, fun setup/0, fun(_) -> cleanup() end, [
        fun at_most_max_running_run_at_once/0,
        fun what_does_not_fit_the_backlog_is_dropped/0,
        fun the_backlog_holds_no_more_than_its_bytes/0,
        fun the_server_keeps_no_job_data_of_a_running_callback/0,
        fun a_callback_is_stopped_at_the_timeout/0,
        fun a_callback_that_raises_stops_nothing/0,
        fun only_a_discarded_job_with_the_callback_is_handed_over/0,
        fun without_the_process_the_callback_runs_before_the_call_returns/0,
        fun without_the_process_the_call_returns_at_the_timeout/0,
        fun a_row_that_cannot_be_read_is_not_printed_by_the_emulator/0
    ]}.

setup() ->
    application:set_env(shigoto, on_discard_timeout, 5000),
    ok.

%% The fixture's setup does not run in the process of the test.
listen() ->
    case whereis(shigoto_callbacks_test) of
        undefined -> ok;
        _Earlier -> unregister(shigoto_callbacks_test)
    end,
    true = register(shigoto_callbacks_test, self()),
    flush().

cleanup() ->
    case whereis(shigoto_callbacks) of
        Pid when is_pid(Pid) ->
            unlink(Pid),
            Monitor = monitor(process, Pid),
            exit(Pid, shutdown),
            receive
                {'DOWN', Monitor, process, Pid, _} -> ok
            end;
        _NotRunning ->
            ok
    end,
    application:unset_env(shigoto, on_discard_timeout),
    ok.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

at_most_max_running_run_at_once() ->
    ok = listen(),
    {ok, _} = shigoto_callbacks:start_link(#{max_running => 2, max_pending => 10}),
    [ok = shigoto_callbacks:discarded(job(N, ~"wait")) || N <- lists:seq(1, 5)],
    First = started(),
    Second = started(),
    ?assertEqual(none, started(100)),
    First ! go,
    Third = started(),
    ?assertEqual(none, started(100)),
    [Pid ! go || Pid <- [Second, Third]],
    Fourth = started(),
    Fifth = started(),
    [Pid ! go || Pid <- [Fourth, Fifth]],
    ?assertEqual(none, started(100)).

what_does_not_fit_the_backlog_is_dropped() ->
    ok = listen(),
    {ok, _} = shigoto_callbacks:start_link(#{max_running => 1, max_pending => 1}),
    [ok = shigoto_callbacks:discarded(job(N, ~"wait")) || N <- lists:seq(1, 4)],
    {1, First} = started_tagged(),
    First ! go,
    {2, Second} = started_tagged(),
    Second ! go,
    ?assertEqual(none, started(100)).

the_backlog_holds_no_more_than_its_bytes() ->
    ok = listen(),
    {ok, _} = shigoto_callbacks:start_link(#{
        max_running => 1, max_pending => 10, max_pending_bytes => 3000
    }),
    Heavy = fun(N) -> (job(N, ~"wait"))#{errors := json_list(2000)} end,
    [ok = shigoto_callbacks:discarded(Heavy(N)) || N <- lists:seq(1, 4)],
    ok = shigoto_callbacks:discarded(job(5, ~"wait")),
    %% 1 runs, 2 waits, 3 and 4 do not fit beside it, 5 is small and does.
    {1, First} = started_tagged(),
    First ! go,
    {2, Second} = started_tagged(),
    Second ! go,
    {5, Fifth} = started_tagged(),
    %% What left the backlog made room again.
    ok = shigoto_callbacks:discarded(Heavy(6)),
    Fifth ! go,
    {6, Sixth} = started_tagged(),
    Sixth ! go,
    ?assertEqual(none, started(100)).

the_server_keeps_no_job_data_of_a_running_callback() ->
    ok = listen(),
    {ok, Server} = shigoto_callbacks:start_link(#{max_running => 1, max_pending => 10}),
    Canary = ~"CANARY-in-the-args",
    Job = job(1, ~"wait"),
    ok = shigoto_callbacks:discarded(Job#{meta := json_text(#{~"note" => Canary})}),
    {1, Running} = started_tagged(),
    State = iolist_to_binary(io_lib:format("~0tp", [sys:get_state(Server)])),
    ?assertEqual(nomatch, binary:match(State, Canary)),
    ?assertEqual(nomatch, binary:match(State, ~"\"then\"")),
    Running ! go.

json_list(Bytes) ->
    json_text([binary:copy(~"e", Bytes)]).

json_text(Term) ->
    iolist_to_binary(json:encode(Term)).

a_callback_is_stopped_at_the_timeout() ->
    ok = listen(),
    application:set_env(shigoto, on_discard_timeout, 50),
    {ok, Server} = shigoto_callbacks:start_link(#{max_running => 1, max_pending => 10}),
    ok = shigoto_callbacks:discarded(job(1, ~"wait")),
    ok = shigoto_callbacks:discarded(job(2, ~"return")),
    {1, Stuck} = started_tagged(),
    Monitor = monitor(process, Stuck),
    receive
        {'DOWN', Monitor, process, Stuck, Reason} -> ?assertEqual(killed, Reason)
    after 1000 -> error(callback_not_stopped)
    end,
    ?assertMatch({2, _}, started_tagged()),
    ?assert(is_process_alive(Server)).

a_callback_that_raises_stops_nothing() ->
    ok = listen(),
    {ok, Server} = shigoto_callbacks:start_link(#{max_running => 1, max_pending => 10}),
    ok = shigoto_callbacks:discarded(job(1, ~"crash")),
    ok = shigoto_callbacks:discarded(job(2, ~"return")),
    ?assertMatch({1, _}, started_tagged()),
    ?assertMatch({2, _}, started_tagged()),
    ?assert(is_process_alive(Server)).

only_a_discarded_job_with_the_callback_is_handed_over() ->
    ok = listen(),
    {ok, _} = shigoto_callbacks:start_link(#{max_running => 1, max_pending => 10}),
    Job = job(1, ~"return"),
    ok = shigoto_callbacks:discarded(Job#{state := ~"cancelled"}),
    ok = shigoto_callbacks:discarded(Job#{worker := ~"shigoto_test_worker"}),
    ok = shigoto_callbacks:discarded(Job#{worker := ~"shigoto_no_such_module_anywhere"}),
    ?assertEqual(none, started(100)).

without_the_process_the_callback_runs_before_the_call_returns() ->
    ok = listen(),
    ?assertEqual(undefined, whereis(shigoto_callbacks)),
    ok = shigoto_callbacks:discarded(job(1, ~"return")),
    receive
        {on_discard, 1, Pid} -> ?assertNotEqual(self(), Pid)
    after 0 -> error(callback_not_run_yet)
    end,
    ok = shigoto_callbacks:discarded(job(2, ~"crash")).

without_the_process_the_call_returns_at_the_timeout() ->
    ok = listen(),
    application:set_env(shigoto, on_discard_timeout, 50),
    ok = shigoto_callbacks:discarded(job(1, ~"wait")),
    {1, Stuck} = started_tagged(),
    ?assertNot(is_process_alive(Stuck)).

a_row_that_cannot_be_read_is_not_printed_by_the_emulator() ->
    ok = listen(),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{pid => self()}, level => all}),
    Huge = binary:copy(~"9", 4000000),
    Unreadable = (job(1, ~"return"))#{
        deps_results => iolist_to_binary(json:encode(#{Huge => 1}))
    },
    try
        ok = shigoto_callbacks:discarded(Unreadable),
        ok = shigoto_callbacks:discarded(maps:remove(errors, job(2, ~"return"))),
        ?assertMatch({2, _}, started_tagged()),
        ok = shigoto_callbacks:discarded(job(3, ~"crash")),
        ?assertMatch({3, _}, started_tagged()),
        Logged = logged(),
        ?assertEqual([], [Event || #{meta := #{error_logger := _}} = Event <- Logged]),
        ?assertMatch(
            [
                #{msg := ~"shigoto_on_discard_failed", job_id := 1, reason := decrypt_failed},
                #{msg := ~"shigoto_on_discard_failed", job_id := 3}
            ],
            [Report || #{msg := {report, Report}} <- Logged]
        )
    after
        logger:remove_handler(?MODULE)
    end.

log(Event, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Event},
    ok.

logged() ->
    receive
        {logged, Event} -> [Event | logged()]
    after 100 -> []
    end.

job(Tag, Then) ->
    #{
        id => Tag,
        state => ~"discarded",
        worker => ~"shigoto_callback_probe_worker",
        queue => ~"default",
        attempt => 1,
        args => iolist_to_binary(json:encode(#{~"tag" => Tag, ~"then" => Then})),
        meta => ~"{}",
        errors => ~"[]"
    }.

started() ->
    case started(1000) of
        none -> error(callback_not_started);
        Pid -> Pid
    end.

started(Ms) ->
    receive
        {on_discard, _Tag, Pid} -> Pid
    after Ms -> none
    end.

started_tagged() ->
    receive
        {on_discard, Tag, Pid} -> {Tag, Pid}
    after 1000 -> error(callback_not_started)
    end.
