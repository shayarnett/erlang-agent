-module(json_test).
-export([test/0]).

test() ->
    test_encode_decode_roundtrips(),
    test_decode_edge_cases(),
    test_encode_edge_cases(),
    test_malformed_number(),
    ok.

test_encode_decode_roundtrips() ->
    %% Empty object
    #{} = json:decode(json:encode(#{})),
    %% Simple object
    M1 = #{<<"a">> => 1, <<"b">> => <<"hello">>},
    M1 = json:decode(json:encode(M1)),
    %% Nested object
    M2 = #{<<"x">> => #{<<"y">> => 42}},
    M2 = json:decode(json:encode(M2)),
    %% Array
    [1, 2, 3] = json:decode(json:encode([1, 2, 3])),
    %% Empty array
    [] = json:decode(json:encode([])),
    %% Mixed array
    L = [1, <<"two">>, true, null],
    L = json:decode(json:encode(L)),
    %% Booleans and null
    true = json:decode(json:encode(true)),
    false = json:decode(json:encode(false)),
    null = json:decode(json:encode(null)),
    ok.

test_decode_edge_cases() ->
    %% Unicode escape
    <<16#00E9>> = json:decode(<<"\"\\u00e9\"">>),
    %% Escaped characters
    <<"\n">> = json:decode(<<"\"\\n\"">>),
    <<"\t">> = json:decode(<<"\"\\t\"">>),
    <<"\r">> = json:decode(<<"\"\\r\"">>),
    <<"a\\b">> = json:decode(<<"\"a\\\\b\"">>),
    <<"a\"b">> = json:decode(<<"\"a\\\"b\"">>),
    %% Negative number
    -42 = json:decode(<<"-42">>),
    %% Float
    F = json:decode(<<"3.14">>),
    true = is_float(F),
    %% Scientific notation
    E = json:decode(<<"1e2">>),
    true = (E == 100.0 orelse E == 1.0e2),
    %% Whitespace
    42 = json:decode(<<"  42  ">>),
    ok.

test_encode_edge_cases() ->
    %% Atom keys
    Bin = json:encode(#{hello => world}),
    Decoded = json:decode(Bin),
    <<"world">> = maps:get(<<"hello">>, Decoded),
    %% String with special chars
    Encoded = json:encode(<<"line1\nline2">>),
    <<"line1\nline2">> = json:decode(Encoded),
    ok.

test_malformed_number() ->
    %% Malformed number should raise json_number error, not crash with badarg
    try
        json:decode(<<"1.2.3">>),
        error(should_have_crashed)
    catch
        error:{json_number, _} -> ok
    end,
    ok.
