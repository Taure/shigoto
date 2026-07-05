-module(shigoto_tz_tests).
-include_lib("eunit/include/eunit.hrl").

%% These tests read the operating system's IANA time zone database. Europe/London
%% and Europe/Stockholm are present on any standard Linux/macOS zoneinfo install.

stockholm_winter_test() ->
    ?assertEqual({ok, 3600}, shigoto_tz:offset(~"Europe/Stockholm", {{2026, 1, 15}, {12, 0, 0}})).

stockholm_summer_test() ->
    ?assertEqual({ok, 7200}, shigoto_tz:offset(~"Europe/Stockholm", {{2026, 7, 15}, {12, 0, 0}})).

%% Spring-forward: last Sunday of March 2026 at 01:00 UTC (02:00 CET -> 03:00 CEST).
stockholm_spring_forward_boundary_test() ->
    ?assertEqual(
        {ok, 3600}, shigoto_tz:offset(~"Europe/Stockholm", {{2026, 3, 29}, {0, 59, 0}})
    ),
    ?assertEqual(
        {ok, 7200}, shigoto_tz:offset(~"Europe/Stockholm", {{2026, 3, 29}, {1, 0, 0}})
    ).

%% Fall-back: last Sunday of October 2026 at 01:00 UTC (03:00 CEST -> 02:00 CET).
stockholm_fall_back_boundary_test() ->
    ?assertEqual(
        {ok, 7200}, shigoto_tz:offset(~"Europe/Stockholm", {{2026, 10, 25}, {0, 59, 0}})
    ),
    ?assertEqual(
        {ok, 3600}, shigoto_tz:offset(~"Europe/Stockholm", {{2026, 10, 25}, {1, 0, 0}})
    ).

%% Beyond the explicit transition table (which ends ~2037): the POSIX TZ footer
%% rule must still resolve DST correctly.
stockholm_far_future_summer_test() ->
    ?assertEqual({ok, 7200}, shigoto_tz:offset(~"Europe/Stockholm", {{2050, 7, 1}, {12, 0, 0}})).

stockholm_far_future_winter_test() ->
    ?assertEqual({ok, 3600}, shigoto_tz:offset(~"Europe/Stockholm", {{2050, 1, 1}, {12, 0, 0}})).

london_winter_is_utc_test() ->
    ?assertEqual({ok, 0}, shigoto_tz:offset(~"Europe/London", {{2026, 1, 15}, {12, 0, 0}})).

london_summer_test() ->
    ?assertEqual({ok, 3600}, shigoto_tz:offset(~"Europe/London", {{2026, 7, 15}, {12, 0, 0}})).

utc_zone_test() ->
    ?assertEqual({ok, 0}, shigoto_tz:offset(~"Etc/UTC", {{2026, 7, 1}, {0, 0, 0}})).

unknown_zone_test() ->
    ?assertMatch({error, _}, shigoto_tz:offset(~"Nowhere/Nope", {{2026, 7, 1}, {0, 0, 0}})).

invalid_zone_rejected_test() ->
    ?assertEqual(
        {error, {invalid_zone, ~"../etc/passwd"}},
        shigoto_tz:offset(~"../etc/passwd", {{2026, 7, 1}, {0, 0, 0}})
    ).

%% A file whose magic is "TZif" but whose body is truncated/garbage must return
%% {error, _}, not crash the caller (cron relies on this to fall back to UTC).
malformed_tzfile_returns_error_test() ->
    Dir = filename:join(["/tmp", "shigoto_tz_test", integer_to_list(erlang:phash2(make_ref()))]),
    File = filename:join([Dir, "Broken", "Zone"]),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, <<"TZif2", 0:120, "garbage">>),
    OldTzdir = os:getenv("TZDIR"),
    os:putenv("TZDIR", Dir),
    try
        ?assertMatch({error, _}, shigoto_tz:offset(~"Broken/Zone", {{2026, 7, 1}, {0, 0, 0}}))
    after
        case OldTzdir of
            false -> os:unsetenv("TZDIR");
            _ -> os:putenv("TZDIR", OldTzdir)
        end
    end.
