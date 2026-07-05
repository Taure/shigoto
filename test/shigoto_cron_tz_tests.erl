-module(shigoto_cron_tz_tests).
-include_lib("eunit/include/eunit.hrl").

utc_atom_test() ->
    Dt = {{2026, 3, 18}, {14, 30, 0}},
    ?assertEqual(Dt, shigoto_cron:to_timezone(Dt, utc)).

integer_offset_positive_test() ->
    ?assertEqual(
        {{2026, 3, 18}, {16, 30, 0}},
        shigoto_cron:to_timezone({{2026, 3, 18}, {14, 30, 0}}, 2)
    ).

integer_offset_negative_test() ->
    ?assertEqual(
        {{2026, 3, 18}, {9, 30, 0}},
        shigoto_cron:to_timezone({{2026, 3, 18}, {14, 30, 0}}, -5)
    ).

integer_offset_day_rollover_test() ->
    ?assertEqual(
        {{2026, 3, 19}, {1, 0, 0}},
        shigoto_cron:to_timezone({{2026, 3, 18}, {23, 0, 0}}, 2)
    ).

binary_offset_test() ->
    ?assertEqual(
        {{2026, 3, 18}, {16, 30, 0}},
        shigoto_cron:to_timezone({{2026, 3, 18}, {14, 30, 0}}, ~"+2")
    ).

binary_utc_test() ->
    Dt = {{2026, 3, 18}, {14, 30, 0}},
    ?assertEqual(Dt, shigoto_cron:to_timezone(Dt, ~"UTC")).

%% Named zone, winter: Stockholm is UTC+1, so 02:00 UTC -> 03:00 local.
named_zone_winter_test() ->
    ?assertEqual(
        {{2026, 1, 1}, {3, 0, 0}},
        shigoto_cron:to_timezone({{2026, 1, 1}, {2, 0, 0}}, ~"Europe/Stockholm")
    ).

%% Named zone, summer: Stockholm is UTC+2, so 01:00 UTC -> 03:00 local.
named_zone_summer_test() ->
    ?assertEqual(
        {{2026, 7, 1}, {3, 0, 0}},
        shigoto_cron:to_timezone({{2026, 7, 1}, {1, 0, 0}}, ~"Europe/Stockholm")
    ).

%% DST spring-forward: at 01:00 UTC on 2026-03-29 the clock has already jumped
%% to CEST (+2), so a "0 3 * * *" cron fires at 01:00 UTC, not 02:00 UTC.
named_zone_spring_forward_test() ->
    Before = shigoto_cron:to_timezone({{2026, 3, 29}, {0, 59, 0}}, ~"Europe/Stockholm"),
    After = shigoto_cron:to_timezone({{2026, 3, 29}, {1, 0, 0}}, ~"Europe/Stockholm"),
    ?assertEqual({{2026, 3, 29}, {1, 59, 0}}, Before),
    ?assertEqual({{2026, 3, 29}, {3, 0, 0}}, After).

unknown_zone_falls_back_to_utc_test() ->
    Dt = {{2026, 3, 18}, {14, 30, 0}},
    ?assertEqual(Dt, shigoto_cron:to_timezone(Dt, ~"Nowhere/Nope")).

normalize_entry_5tuple_test() ->
    ?assertEqual(
        {daily, ~"0 3 * * *", w, #{}},
        shigoto_cron:normalize_entry(
            {daily, ~"0 3 * * *", w, #{}, #{timezone => ~"Europe/Stockholm"}}
        )
    ),
    ?assertEqual(
        {daily, ~"0 3 * * *", w, #{}},
        shigoto_cron:normalize_entry({daily, ~"0 3 * * *", w, #{}})
    ).

entry_timezone_test() ->
    ?assertEqual(
        ~"Europe/Stockholm",
        shigoto_cron:entry_timezone(
            {daily, ~"0 3 * * *", w, #{}, #{timezone => ~"Europe/Stockholm"}}
        )
    ),
    ?assertEqual(utc, shigoto_cron:entry_timezone({daily, ~"0 3 * * *", w, #{}})).
