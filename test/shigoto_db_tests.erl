-module(shigoto_db_tests).

-include_lib("eunit/include/eunit.hrl").

-define(POOL, shigoto_db_tests_pool).

%% minato answers `command` as an atom for the command tags it knows and as
%% the tag itself, a binary, for one it does not. No statement shigoto runs
%% has such a tag today, and no released server can be made to send one, so
%% the connection here is a process that answers what it is told to. It
%% stands where shigoto_db keeps the connection of an open transaction, which
%% is the one place a statement is sent to a process this test can be.
db_test_() ->
    {foreach, fun() -> ok end, fun(_) -> erlang:erase({{shigoto_db, holder}, ?POOL}) end, [
        fun a_command_minato_does_not_know_is_answered_as_it_came/0,
        fun a_statement_that_ran_is_ok_whatever_its_command/0,
        fun a_statement_that_failed_is_still_an_error/0,
        fun a_column_under_its_name_as_a_binary_is_passed_on/0,
        fun the_columns_are_named_once/0
    ]}.

a_command_minato_does_not_know_is_answered_as_it_came() ->
    Result = #{command => ~"MERGE", num_rows => 3, rows => []},
    answering(Result),
    ?assertEqual(Result, shigoto_db:query(?POOL, ~"MERGE INTO t USING s ON true", [])),
    ?assertEqual(
        Result, shigoto_db:transaction(?POOL, fun() -> shigoto_db:query(?POOL, ~"x", []) end)
    ).

a_statement_that_ran_is_ok_whatever_its_command() ->
    [
        begin
            answering(#{command => Command, num_rows => 1, rows => []}),
            ?assertEqual({Command, ok}, {Command, shigoto_repo:update_progress(?POOL, 1, 50)}),
            ?assertEqual({Command, ok}, {Command, shigoto_batch:increment_total(?POOL, 1)}),
            ?assertEqual(
                {Command, ok},
                {Command,
                    shigoto_repo:upsert_cron_entry(?POOL, #{
                        name => ~"nightly", worker => shigoto_test_worker, schedule => ~"@daily"
                    })}
            )
        end
     || Command <- [update, insert, ~"UPDATE", ~"SOMETHING NEW"]
    ].

a_statement_that_failed_is_still_an_error() ->
    Refused = {error, {pgsql_error, #{code => ~"42P01"}}},
    answering(Refused),
    ?assertEqual(Refused, shigoto_repo:update_progress(?POOL, 1, 50)),
    ?assertEqual(Refused, shigoto_batch:increment_total(?POOL, 1)),
    ?assertEqual(Refused, shigoto_db:query(?POOL, ~"SELECT 1", [])).

%% What a client that makes no atoms answers for a column no module names.
a_column_under_its_name_as_a_binary_is_passed_on() ->
    Row = #{
        id => 7,
        worker => ~"shigoto_test_worker",
        queue => ~"default",
        state => ~"discarded",
        args => ~"{}",
        meta => ~"{}",
        errors => ~"[]",
        ~"added_by_the_operator" => ~"kept"
    },
    answering(#{command => select, num_rows => 1, rows => [Row]}),
    ?assertEqual({ok, Row}, shigoto_repo:get_job(?POOL, 7)),
    ?assertMatch(#{~"added_by_the_operator" := ~"kept"}, shigoto_job:redact(Row)),
    {ok, shigoto_test_worker, Opened} = shigoto_job:opened(Row),
    ?assertMatch(#{~"added_by_the_operator" := ~"kept", args := #{}}, Opened),
    ?assertMatch(#{~"worker" := ~"shigoto_test_worker"}, shigoto_error:entry(Row, timeout)).

the_columns_are_named_once() ->
    Columns = shigoto_db:columns(),
    ?assertEqual(lists:usort(Columns), Columns),
    ?assert(lists:all(fun is_atom/1, Columns)).

answering(Answer) ->
    Connection = spawn_link(fun() -> answer(Answer) end),
    erlang:put({{shigoto_db, holder}, ?POOL}, Connection).

answer(Answer) ->
    receive
        {run, From, Tag, _SQL, _Params, _Opts} ->
            From ! {Tag, Answer},
            answer(Answer)
    end.
