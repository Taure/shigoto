-module(shigoto_cron_tests).
-include_lib("eunit/include/eunit.hrl").

-define(NOW, {{2026, 11, 3}, {12, 30, 0}}).

new_entry_starts_at_now_test() ->
    ?assertEqual([?NOW], shigoto_cron:due_minutes(null, ?NOW)).

same_minute_is_not_due_again_test() ->
    ?assertEqual([], shigoto_cron:due_minutes(?NOW, ?NOW)).

seconds_in_the_last_run_are_ignored_test() ->
    ?assertEqual([], shigoto_cron:due_minutes({{2026, 11, 3}, {12, 30, 42}}, ?NOW)).

minutes_after_the_last_run_are_due_test() ->
    ?assertEqual(
        [{{2026, 11, 3}, {12, 29, 0}}, ?NOW],
        shigoto_cron:due_minutes({{2026, 11, 3}, {12, 28, 0}}, ?NOW)
    ).

catch_up_is_bounded_to_an_hour_test() ->
    Due = shigoto_cron:due_minutes({{2026, 11, 1}, {0, 0, 0}}, ?NOW),
    ?assertEqual(60, length(Due)),
    ?assertEqual({{2026, 11, 3}, {11, 31, 0}}, hd(Due)),
    ?assertEqual(?NOW, lists:last(Due)).

a_last_run_ahead_of_this_clock_is_not_due_test() ->
    ?assertEqual([], shigoto_cron:due_minutes({{2026, 11, 3}, {12, 45, 0}}, ?NOW)).
