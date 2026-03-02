-module(json).
-export([encode/1, decode/1]).

%% Minimal JSON encoder/decoder — zero dependencies.
%% Supports: maps, lists, binaries, atoms (true/false/null), integers, floats.

%%--------------------------------------------------------------------
%% Encode
%%--------------------------------------------------------------------

-spec encode(term()) -> binary().
encode(Map) when is_map(Map) ->
    Pairs = maps:to_list(Map),
    Inner = lists:join(",", [encode_pair(K, V) || {K, V} <- Pairs]),
    iolist_to_binary(["{", Inner, "}"]);

encode(List) when is_list(List) ->
    Inner = lists:join(",", [encode(V) || V <- List]),
    iolist_to_binary(["[", Inner, "]"]);

encode(Bin) when is_binary(Bin) ->
    iolist_to_binary([$", escape_string(Bin), $"]);

encode(true) -> <<"true">>;
encode(false) -> <<"false">>;
encode(null) -> <<"null">>;

encode(Int) when is_integer(Int) ->
    integer_to_binary(Int);

encode(Float) when is_float(Float) ->
    float_to_binary(Float, [{decimals, 10}, compact]);

encode(Atom) when is_atom(Atom) ->
    encode(atom_to_binary(Atom, utf8)).

encode_pair(K, V) ->
    [encode(to_bin(K)), ":", encode(V)].

%%--------------------------------------------------------------------
%% Decode
%%--------------------------------------------------------------------

-spec decode(binary()) -> term().
decode(Bin) when is_binary(Bin) ->
    {Value, _Rest} = decode_value(skip_ws(Bin)),
    Value.

decode_value(<<${, Rest/binary>>) -> decode_object(skip_ws(Rest), #{});
decode_value(<<$[, Rest/binary>>) -> decode_array(skip_ws(Rest), []);
decode_value(<<$", Rest/binary>>) -> decode_string(Rest, []);
decode_value(<<"true", Rest/binary>>) -> {true, Rest};
decode_value(<<"false", Rest/binary>>) -> {false, Rest};
decode_value(<<"null", Rest/binary>>) -> {null, Rest};
decode_value(<<C, _/binary>> = Bin) when C =:= $- orelse (C >= $0 andalso C =< $9) ->
    decode_number(Bin, []);
decode_value(Bin) -> error({json_decode, Bin}).

%% Object
decode_object(<<$}, Rest/binary>>, Acc) -> {Acc, Rest};
decode_object(<<$", Rest/binary>>, Acc) ->
    {Key, R1} = decode_string(Rest, []),
    <<$:, R2/binary>> = skip_ws(R1),
    {Val, R3} = decode_value(skip_ws(R2)),
    R4 = skip_ws(R3),
    case R4 of
        <<$,, R5/binary>> -> decode_object(skip_ws(R5), maps:put(Key, Val, Acc));
        <<$}, R5/binary>> -> {maps:put(Key, Val, Acc), R5};
        _ -> error({json_object, R4})
    end.

%% Array
decode_array(<<$], Rest/binary>>, Acc) -> {lists:reverse(Acc), Rest};
decode_array(Bin, Acc) ->
    {Val, R1} = decode_value(Bin),
    R2 = skip_ws(R1),
    case R2 of
        <<$,, R3/binary>> -> decode_array(skip_ws(R3), [Val | Acc]);
        <<$], R3/binary>> -> {lists:reverse([Val | Acc]), R3};
        _ -> error({json_array, R2})
    end.

%% String
decode_string(<<$", Rest/binary>>, Acc) ->
    {list_to_binary(lists:reverse(Acc)), Rest};
decode_string(<<$\\, $", Rest/binary>>, Acc) ->
    decode_string(Rest, [$" | Acc]);
decode_string(<<$\\, $\\, Rest/binary>>, Acc) ->
    decode_string(Rest, [$\\ | Acc]);
decode_string(<<$\\, $/, Rest/binary>>, Acc) ->
    decode_string(Rest, [$/ | Acc]);
decode_string(<<$\\, $n, Rest/binary>>, Acc) ->
    decode_string(Rest, [$\n | Acc]);
decode_string(<<$\\, $r, Rest/binary>>, Acc) ->
    decode_string(Rest, [$\r | Acc]);
decode_string(<<$\\, $t, Rest/binary>>, Acc) ->
    decode_string(Rest, [$\t | Acc]);
decode_string(<<$\\, $b, Rest/binary>>, Acc) ->
    decode_string(Rest, [$\b | Acc]);
decode_string(<<$\\, $f, Rest/binary>>, Acc) ->
    decode_string(Rest, [$\f | Acc]);
decode_string(<<$\\, $u, A, B, C, D, Rest/binary>>, Acc) ->
    Hex = list_to_integer([A, B, C, D], 16),
    decode_string(Rest, [Hex | Acc]);
decode_string(<<C, Rest/binary>>, Acc) ->
    decode_string(Rest, [C | Acc]).

%% Number
decode_number(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9; C =:= $-; C =:= $+; C =:= $.; C =:= $e; C =:= $E ->
    decode_number(Rest, [C | Acc]);
decode_number(Rest, Acc) ->
    Str = lists:reverse(Acc),
    HasDot = lists:member($., Str),
    HasExp = lists:member($e, Str) orelse lists:member($E, Str),
    Num = try
        case HasDot orelse HasExp of
            true ->
                %% Erlang requires a decimal point for list_to_float;
                %% JSON allows "1e2" without one — normalize by inserting ".0"
                FloatStr = case HasDot of
                    true -> Str;
                    false -> insert_dot(Str)
                end,
                list_to_float(FloatStr);
            false ->
                list_to_integer(Str)
        end
    catch
        error:badarg -> error({json_number, Str})
    end,
    {Num, Rest}.

%% Insert ".0" before 'e'/'E' for Erlang's list_to_float (e.g. "1e2" -> "1.0e2")
insert_dot([]) -> [];
insert_dot([$e | Rest]) -> ".0e" ++ Rest;
insert_dot([$E | Rest]) -> ".0E" ++ Rest;
insert_dot([C | Rest]) -> [C | insert_dot(Rest)].

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

skip_ws(<<$ , R/binary>>) -> skip_ws(R);
skip_ws(<<$\t, R/binary>>) -> skip_ws(R);
skip_ws(<<$\n, R/binary>>) -> skip_ws(R);
skip_ws(<<$\r, R/binary>>) -> skip_ws(R);
skip_ws(Bin) -> Bin.

escape_string(Bin) -> escape_string(Bin, []).
escape_string(<<>>, Acc) -> lists:reverse(Acc);
escape_string(<<$", R/binary>>, Acc) -> escape_string(R, [$", $\\ | Acc]);
escape_string(<<$\\, R/binary>>, Acc) -> escape_string(R, [$\\, $\\ | Acc]);
escape_string(<<$\n, R/binary>>, Acc) -> escape_string(R, [$n, $\\ | Acc]);
escape_string(<<$\r, R/binary>>, Acc) -> escape_string(R, [$r, $\\ | Acc]);
escape_string(<<$\t, R/binary>>, Acc) -> escape_string(R, [$t, $\\ | Acc]);
escape_string(<<C, R/binary>>, Acc) when C < 32 ->
    Hex = io_lib:format("\\u~4.16.0b", [C]),
    escape_string(R, lists:reverse(lists:flatten(Hex)) ++ Acc);
escape_string(<<C, R/binary>>, Acc) -> escape_string(R, [C | Acc]).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
