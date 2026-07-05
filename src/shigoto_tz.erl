-module(shigoto_tz).
-moduledoc """
Resolves IANA named time zones (e.g. `<<"Europe/Stockholm">>`) to their UTC
offset at a specific instant, accounting for daylight saving time.

Reads the operating system's IANA time zone database directly (TZif files,
RFC 8536) from `$TZDIR` or `/usr/share/zoneinfo`. There is no external
dependency and no build step: the database is kept current by the OS.

Offsets are resolved from the file's explicit transition table. For instants
beyond the last recorded transition, the trailing POSIX TZ rule is evaluated so
future dates stay correct.
""".

-export([offset/2]).

-define(SECONDS_1970, 62167219200).
-define(DEFAULT_ZONEINFO, "/usr/share/zoneinfo").

-doc """
UTC offset in seconds for `Zone` at the given UTC datetime, e.g.
`{ok, 7200}` for `<<"Europe/Stockholm">>` during summer time.
""".
-spec offset(binary(), calendar:datetime()) -> {ok, integer()} | {error, term()}.
offset(Zone, UtcDatetime) ->
    case zone_path(Zone) of
        {ok, Path} ->
            case read_zone(Path) of
                {ok, Data} ->
                    Unix = calendar:datetime_to_gregorian_seconds(UtcDatetime) - ?SECONDS_1970,
                    {ok, lookup(Unix, Data)};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%%----------------------------------------------------------------------
%% Zone file location
%%----------------------------------------------------------------------

zone_path(Zone) ->
    case valid_zone(Zone) of
        true ->
            Dir =
                case os:getenv("TZDIR") of
                    false -> ?DEFAULT_ZONEINFO;
                    D -> D
                end,
            {ok, filename:join(Dir, binary_to_list(Zone))};
        false ->
            {error, {invalid_zone, Zone}}
    end.

valid_zone(Zone) when is_binary(Zone), byte_size(Zone) > 0 ->
    binary:match(Zone, ~"..") =:= nomatch andalso
        binary:first(Zone) =/= $/ andalso
        lists:all(fun valid_char/1, binary_to_list(Zone));
valid_zone(_) ->
    false.

valid_char(C) ->
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $/ orelse C =:= $_ orelse C =:= $- orelse C =:= $+.

read_zone(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> parse(Bin);
        {error, Reason} -> {error, {tzfile, Reason}}
    end.

%%----------------------------------------------------------------------
%% TZif parsing (RFC 8536)
%%----------------------------------------------------------------------

parse(<<"TZif", Version, _Reserved:15/binary, Rest/binary>>) when
    Version =:= $2; Version =:= $3
->
    After1 = skip_block(Rest, 4),
    <<"TZif", _:16/binary, Body/binary>> = After1,
    parse_data(Body, 8, footer);
parse(<<"TZif", _Version, _Reserved:15/binary, Rest/binary>>) ->
    parse_data(Rest, 4, no_footer);
parse(_) ->
    {error, not_tzif}.

skip_block(<<Isut:32, Isstd:32, Leap:32, Tc:32, Typ:32, Ch:32, Rest/binary>>, TimeSize) ->
    Size = block_size(Isut, Isstd, Leap, Tc, Typ, Ch, TimeSize),
    <<_:Size/binary, After/binary>> = Rest,
    After.

block_size(Isut, Isstd, Leap, Tc, Typ, Ch, TimeSize) ->
    LeapSize = TimeSize + 4,
    Tc * TimeSize + Tc + Typ * 6 + Ch + Leap * LeapSize + Isstd + Isut.

parse_data(<<Isut:32, Isstd:32, Leap:32, Tc:32, Typ:32, Ch:32, Rest/binary>>, TimeSize, Footer) ->
    LeapSize = TimeSize + 4,
    TransBytes = Tc * TimeSize,
    TypeBytes = Typ * 6,
    <<TransBin:TransBytes/binary, IdxBin:Tc/binary, TypesBin:TypeBytes/binary, _Desig:Ch/binary,
        _Leap:(Leap * LeapSize)/binary, _Std:Isstd/binary, _Ut:Isut/binary, Tail/binary>> = Rest,
    Transitions = lists:zip(decode_times(TransBin, TimeSize), binary_to_list(IdxBin)),
    Types = decode_types(TypesBin),
    Tz =
        case Footer of
            footer -> parse_footer(Tail);
            no_footer -> undefined
        end,
    {ok, #{transitions => Transitions, types => Types, tz => Tz}}.

decode_times(Bin, 4) ->
    [T || <<T:32/signed>> <= Bin];
decode_times(Bin, 8) ->
    [T || <<T:64/signed>> <= Bin].

decode_types(Bin) ->
    [{Off, Dst} || <<Off:32/signed, Dst:8, _Idx:8>> <= Bin].

parse_footer(<<$\n, Rest/binary>>) ->
    case binary:split(Rest, ~"\n") of
        [Tz | _] -> Tz;
        [] -> undefined
    end;
parse_footer(_) ->
    undefined.

%%----------------------------------------------------------------------
%% Offset lookup
%%----------------------------------------------------------------------

lookup(Unix, #{transitions := Transitions, types := Types, tz := Tz}) ->
    TableOffset = table_offset(Unix, Transitions, Types),
    case beyond_table(Unix, Transitions) andalso Tz =/= undefined of
        true ->
            case tz_string_offset(Tz, Unix) of
                {ok, Offset} -> Offset;
                error -> TableOffset
            end;
        false ->
            TableOffset
    end.

beyond_table(_Unix, []) ->
    true;
beyond_table(Unix, Transitions) ->
    {LastTime, _} = lists:last(Transitions),
    Unix >= LastTime.

table_offset(Unix, Transitions, Types) ->
    case applicable_index(Unix, Transitions, undefined) of
        undefined -> default_offset(Types);
        Index -> offset_of(Index, Types)
    end.

applicable_index(Unix, [{Time, Index} | Rest], _Acc) when Time =< Unix ->
    applicable_index(Unix, Rest, Index);
applicable_index(_Unix, _, Acc) ->
    Acc.

offset_of(Index, Types) ->
    {Offset, _Dst} = lists:nth(Index + 1, Types),
    Offset.

default_offset(Types) ->
    case [Offset || {Offset, 0} <- Types] of
        [Offset | _] -> Offset;
        [] -> first_offset(Types)
    end.

first_offset([{Offset, _} | _]) -> Offset;
first_offset([]) -> 0.

%%----------------------------------------------------------------------
%% POSIX TZ footer rule (for instants beyond the transition table)
%%----------------------------------------------------------------------

tz_string_offset(Tz, Unix) ->
    try
        {_StdName, R1} = parse_name(Tz),
        {StdPosix, R2} = parse_tz_offset(R1),
        case R2 of
            <<>> ->
                {ok, -StdPosix};
            _ ->
                {_DstName, R3} = parse_name(R2),
                {DstPosix, R4} = parse_dst_offset(R3, StdPosix),
                <<",", Rules/binary>> = R4,
                [StartRule, EndRule] = binary:split(Rules, ~","),
                {StartDate, StartTime} = parse_rule(StartRule),
                {EndDate, EndTime} = parse_rule(EndRule),
                {{Year, _, _}, _} = calendar:gregorian_seconds_to_datetime(Unix + ?SECONDS_1970),
                StartUtc = rule_to_utc(StartDate, StartTime, Year, StdPosix),
                EndUtc = rule_to_utc(EndDate, EndTime, Year, DstPosix),
                InDst =
                    case StartUtc =< EndUtc of
                        true -> Unix >= StartUtc andalso Unix < EndUtc;
                        false -> Unix >= StartUtc orelse Unix < EndUtc
                    end,
                case InDst of
                    true -> {ok, -DstPosix};
                    false -> {ok, -StdPosix}
                end
        end
    catch
        _:_ -> error
    end.

parse_name(<<"<", Rest/binary>>) ->
    [Name, R] = binary:split(Rest, ~">"),
    {Name, R};
parse_name(Bin) ->
    parse_alpha(Bin, <<>>).

parse_alpha(<<C, R/binary>>, Acc) when (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) ->
    parse_alpha(R, <<Acc/binary, C>>);
parse_alpha(Bin, Acc) ->
    {Acc, Bin}.

parse_dst_offset(<<",", _/binary>> = Bin, StdPosix) ->
    {StdPosix - 3600, Bin};
parse_dst_offset(<<>>, StdPosix) ->
    {StdPosix - 3600, <<>>};
parse_dst_offset(Bin, _StdPosix) ->
    parse_tz_offset(Bin).

parse_tz_offset(Bin) ->
    {Sign, R0} =
        case Bin of
            <<"-", R/binary>> -> {-1, R};
            <<"+", R/binary>> -> {1, R};
            _ -> {1, Bin}
        end,
    {H, R1} = parse_int(R0),
    {M, R2} = parse_colon_int(R1),
    {S, R3} = parse_colon_int(R2),
    {Sign * (H * 3600 + M * 60 + S), R3}.

parse_rule(Bin) ->
    case binary:split(Bin, ~"/") of
        [Date, Time] ->
            {Secs, _} = parse_tz_offset(Time),
            {parse_mrule(Date), Secs};
        [Date] ->
            {parse_mrule(Date), 7200}
    end.

parse_mrule(<<"M", Rest/binary>>) ->
    [Mo, Wk, Da] = binary:split(Rest, ~".", [global]),
    {binary_to_integer(Mo), binary_to_integer(Wk), binary_to_integer(Da)}.

rule_to_utc({Month, Week, Dow}, TimeSecs, Year, PosixOffset) ->
    Day = nth_weekday(Year, Month, Week, Dow),
    LocalMidnight =
        calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {0, 0, 0}}) - ?SECONDS_1970,
    LocalMidnight + TimeSecs + PosixOffset.

nth_weekday(Year, Month, 5, Dow) ->
    Last = calendar:last_day_of_the_month(Year, Month),
    LastDow = calendar:day_of_the_week(Year, Month, Last) rem 7,
    Last - ((LastDow - Dow + 7) rem 7);
nth_weekday(Year, Month, Week, Dow) ->
    FirstDow = calendar:day_of_the_week(Year, Month, 1) rem 7,
    First = 1 + ((Dow - FirstDow + 7) rem 7),
    First + (Week - 1) * 7.

parse_int(Bin) ->
    parse_int(Bin, 0, false).

parse_int(<<C, R/binary>>, Acc, _Seen) when C >= $0, C =< $9 ->
    parse_int(R, Acc * 10 + (C - $0), true);
parse_int(Bin, Acc, _Seen) ->
    {Acc, Bin}.

parse_colon_int(<<":", R/binary>>) ->
    parse_int(R);
parse_colon_int(Bin) ->
    {0, Bin}.
