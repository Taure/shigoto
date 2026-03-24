-module(shigoto_cron_parser_tests).
-include_lib("eunit/include/eunit.hrl").

%% A fixed datetime for most tests: 2026-03-18 14:30:00 (Wednesday)
%% calendar:day_of_the_week(2026,3,18) = 3 (Wednesday), rem 7 = 3
-define(DT, {{2026, 3, 18}, {14, 30, 0}}).

%%----------------------------------------------------------------------
%% Parse tests
%%----------------------------------------------------------------------

parse_valid_test() ->
    ?assertMatch({ok, _}, shigoto_cron_parser:parse(<<"* * * * *">>)).

parse_bad_field_count_test() ->
    ?assertMatch({error, _}, shigoto_cron_parser:parse(<<"* * *">>)).

parse_bad_integer_test() ->
    ?assertMatch({error, _}, shigoto_cron_parser:parse(<<"abc * * * *">>)).

%%----------------------------------------------------------------------
%% Wildcard matching
%%----------------------------------------------------------------------

wildcard_all_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"* * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

wildcard_any_minute_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"* 14 * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

%%----------------------------------------------------------------------
%% Specific values
%%----------------------------------------------------------------------

specific_minute_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

specific_minute_no_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"15 * * * *">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

specific_hour_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 14 * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

specific_hour_no_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 10 * * *">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

specific_dom_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 14 18 * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

specific_month_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 14 18 3 *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

specific_dow_test() ->
    %% 2026-03-18 is Wednesday = 3
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 14 * * 3">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

specific_dow_no_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 14 * * 1">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

%%----------------------------------------------------------------------
%% Ranges
%%----------------------------------------------------------------------

range_minute_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"25-35 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

range_minute_no_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"0-10 * * * *">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

range_dow_match_test() ->
    %% Wednesday = 3, range 1-5 (Mon-Fri)
    {ok, Expr} = shigoto_cron_parser:parse(<<"* * * * 1-5">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

range_dow_no_match_test() ->
    %% Wednesday = 3, range 5-6 (Fri-Sat)
    {ok, Expr} = shigoto_cron_parser:parse(<<"* * * * 5-6">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

%%----------------------------------------------------------------------
%% Steps
%%----------------------------------------------------------------------

step_every_5_minutes_test() ->
    %% */5 generates 0,5,10,15,20,25,30,35,40,45,50,55 — 30 is in there
    {ok, Expr} = shigoto_cron_parser:parse(<<"*/5 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

step_every_15_minutes_match_test() ->
    %% */15 generates 0,15,30,45 — 30 matches
    {ok, Expr} = shigoto_cron_parser:parse(<<"*/15 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

step_every_7_minutes_no_match_test() ->
    %% */7 generates 0,7,14,21,28,35,42,49,56 — 30 not in there
    {ok, Expr} = shigoto_cron_parser:parse(<<"*/7 * * * *">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

step_range_test() ->
    %% 10-40/10 generates 10,20,30,40 — 30 matches
    {ok, Expr} = shigoto_cron_parser:parse(<<"10-40/10 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

step_range_no_match_test() ->
    %% 10-40/7 generates 10,17,24,31,38 — 30 not in there
    {ok, Expr} = shigoto_cron_parser:parse(<<"10-40/7 * * * *">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

%%----------------------------------------------------------------------
%% Comma-separated lists
%%----------------------------------------------------------------------

list_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"15,30,45 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

list_no_match_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"0,15,45 * * * *">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

list_with_ranges_test() ->
    %% 0-10,28-32 — 30 is in 28-32
    {ok, Expr} = shigoto_cron_parser:parse(<<"0-10,28-32 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

list_hour_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"30 8,14,20 * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

%%----------------------------------------------------------------------
%% Full expressions
%%----------------------------------------------------------------------

every_5_min_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(<<"*/5 * * * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, ?DT)).

daily_3am_monday_test() ->
    %% "0 3 * * 1" — Mon at 03:00, should not match Wed 14:30
    {ok, Expr} = shigoto_cron_parser:parse(<<"0 3 * * 1">>),
    ?assertNot(shigoto_cron_parser:matches(Expr, ?DT)).

daily_3am_monday_match_test() ->
    %% Monday 2026-03-16
    Dt = {{2026, 3, 16}, {3, 0, 0}},
    {ok, Expr} = shigoto_cron_parser:parse(<<"0 3 * * 1">>),
    ?assert(shigoto_cron_parser:matches(Expr, Dt)).

weekday_business_hours_test() ->
    %% "0 9-17 * * 1-5" at Wed 14:00
    Dt = {{2026, 3, 18}, {14, 0, 0}},
    {ok, Expr} = shigoto_cron_parser:parse(<<"0 9-17 * * 1-5">>),
    ?assert(shigoto_cron_parser:matches(Expr, Dt)).

midnight_first_of_month_test() ->
    Dt = {{2026, 1, 1}, {0, 0, 0}},
    {ok, Expr} = shigoto_cron_parser:parse(<<"0 0 1 * *">>),
    ?assert(shigoto_cron_parser:matches(Expr, Dt)).

sunday_test() ->
    %% 2026-03-22 is a Sunday (day_of_the_week returns 7, rem 7 = 0)
    Dt = {{2026, 3, 22}, {0, 0, 0}},
    {ok, Expr} = shigoto_cron_parser:parse(<<"0 0 * * 0">>),
    ?assert(shigoto_cron_parser:matches(Expr, Dt)).

%%----------------------------------------------------------------------
%% Aliases
%%----------------------------------------------------------------------

alias_yearly_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(~"@yearly"),
    ?assert(shigoto_cron_parser:matches(Expr, {{2026, 1, 1}, {0, 0, 0}})),
    ?assertNot(shigoto_cron_parser:matches(Expr, {{2026, 3, 18}, {14, 30, 0}})).

alias_monthly_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(~"@monthly"),
    ?assert(shigoto_cron_parser:matches(Expr, {{2026, 3, 1}, {0, 0, 0}})),
    ?assertNot(shigoto_cron_parser:matches(Expr, {{2026, 3, 2}, {0, 0, 0}})).

alias_weekly_test() ->
    %% 2026-03-22 is Sunday
    {ok, Expr} = shigoto_cron_parser:parse(~"@weekly"),
    ?assert(shigoto_cron_parser:matches(Expr, {{2026, 3, 22}, {0, 0, 0}})),
    ?assertNot(shigoto_cron_parser:matches(Expr, {{2026, 3, 18}, {0, 0, 0}})).

alias_daily_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(~"@daily"),
    ?assert(shigoto_cron_parser:matches(Expr, {{2026, 3, 18}, {0, 0, 0}})),
    ?assertNot(shigoto_cron_parser:matches(Expr, {{2026, 3, 18}, {14, 30, 0}})).

alias_hourly_test() ->
    {ok, Expr} = shigoto_cron_parser:parse(~"@hourly"),
    ?assert(shigoto_cron_parser:matches(Expr, {{2026, 3, 18}, {14, 0, 0}})),
    ?assertNot(shigoto_cron_parser:matches(Expr, {{2026, 3, 18}, {14, 30, 0}})).
