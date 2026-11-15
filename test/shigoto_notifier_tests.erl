-module(shigoto_notifier_tests).

-include_lib("eunit/include/eunit.hrl").

%% The notifier subscribes through the listener registered as
%% `shigoto_listener`. Here that name belongs to a process that answers
%% `minato:listen/2` as it is told to, so no database is needed and the
%% answers a later minato gives can be given now.
notifier_test_() ->
    {foreach,
        fun() ->
            application:set_env(shigoto, notifier, #{host => "localhost"}),
            ok
        end,
        fun(_) ->
            _ = [gen_server:stop(shigoto_notifier) || whereis(shigoto_notifier) =/= undefined],
            _ = [exit(Pid, kill) || Pid <- [whereis(shigoto_listener)], is_pid(Pid)],
            application:unset_env(shigoto, notifier)
        end,
        [
            {timeout, 30, fun a_refused_subscription_is_tried_again/0},
            fun a_listener_that_dies_while_asked_does_not_take_the_notifier_down/0
        ]}.

a_refused_subscription_is_tried_again() ->
    Listener = listener([{error, {minato_protocol, {unexpected_message, ~"N"}}}, ok]),
    {ok, Notifier} = shigoto_notifier:start_link(),
    ?assertEqual(~"shigoto_jobs_insert", asked(Listener, 2000)),
    ?assertEqual(undefined, listening()),
    ?assert(is_process_alive(Notifier)),
    %% Five seconds later, as after a listener that could not be started.
    ?assertEqual(~"shigoto_jobs_insert", asked(Listener, 8000)),
    ?assertEqual(shigoto_listener, listening()),
    ?assertEqual(Notifier, whereis(shigoto_notifier)),
    %% However often it asks, it watches the listener once.
    ?assertEqual({monitored_by, [Notifier]}, process_info(Listener, monitored_by)).

a_listener_that_dies_while_asked_does_not_take_the_notifier_down() ->
    Listener = listener([stop]),
    {ok, Notifier} = shigoto_notifier:start_link(),
    unlink(Notifier),
    ?assertEqual(~"shigoto_jobs_insert", asked(Listener, 2000)),
    ?assertEqual(undefined, listening()),
    ?assert(is_process_alive(Notifier)),
    ?assertNot(is_process_alive(Listener)).

listening() ->
    case sys:get_state(shigoto_notifier) of
        State when is_tuple(State) -> element(2, State)
    end.

%% A listener that answers each `minato:listen/2` with the next of `Answers`,
%% or stops instead of answering, and says which channel it was asked for.
listener(Answers) ->
    Test = self(),
    Listener = spawn(fun() ->
        true = register(shigoto_listener, self()),
        Test ! {registered, self()},
        answer(Answers, Test)
    end),
    receive
        {registered, Listener} -> Listener
    after 2000 -> error(listener_not_registered)
    end.

answer([], _Test) ->
    receive
        stop -> ok
    end;
answer([Answer | Answers], Test) ->
    receive
        {'$gen_call', From, {listen, Channel, _Subscriber}} ->
            Test ! {asked, self(), Channel},
            case Answer of
                stop ->
                    ok;
                _ ->
                    gen_server:reply(From, Answer),
                    answer(Answers, Test)
            end
    end.

asked(Listener, Within) ->
    receive
        {asked, Listener, Channel} -> Channel
    after Within -> not_asked
    end.
