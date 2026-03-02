-module(tools).
-export([execute/2, parse_response/1, parse_args/1]).
-export([format_exports/1, format_diagnostics/1, run_tests/1]).
-export([to_bin/1, truncate/2]).

%%--------------------------------------------------------------------
%% Tool call parsing (tool: name(args) or TOOL: name(args))
%%--------------------------------------------------------------------

-spec parse_response(binary()) -> {tool, binary(), map()} | none.
parse_response(Reply) ->
    Lines = binary:split(Reply, <<"\n">>, [global]),
    parse_lines(Lines).

parse_lines([]) -> none;
parse_lines([Line | Rest]) ->
    Trimmed = string:trim(Line),
    case Trimmed of
        <<"tool:", Call/binary>> ->
            parse_call(string:trim(Call));
        <<"TOOL:", Call/binary>> ->
            parse_call(string:trim(Call));
        _ ->
            parse_lines(Rest)
    end.

parse_call(Call) ->
    case re:run(Call, <<"^([a-z_]+)\\((.*)\\)$">>,
                [{capture, all_but_first, binary}, dotall]) of
        {match, [Name, ArgsStr]} ->
            Args = parse_args(string:trim(ArgsStr)),
            {tool, Name, Args};
        nomatch ->
            none
    end.

%%--------------------------------------------------------------------
%% Arg parsing: JSON object -> map, or CSV positional -> map
%%--------------------------------------------------------------------

-spec parse_args(binary()) -> map().
parse_args(<<>>) -> #{};
parse_args(<<${, _/binary>> = Json) ->
    try json:decode(Json)
    catch _:_ -> #{<<"raw">> => Json}
    end;
parse_args(ArgsStr) ->
    Parsed = csv_parse(ArgsStr),
    maps:from_list(
        lists:zip(
            [integer_to_binary(I) || I <- lists:seq(0, length(Parsed) - 1)],
            Parsed)).

%% Split on commas, respecting quoted strings and escape sequences
csv_parse(Bin) -> csv_parse(Bin, [], [], false).

csv_parse(<<>>, Current, Acc, _) ->
    lists:reverse([strip_quotes(iolist_to_binary(lists:reverse(Current))) | Acc]);
csv_parse(<<$\\, C, Rest/binary>>, Current, Acc, InQuote) ->
    Char = case C of
        $n -> $\n;
        $t -> $\t;
        $\\ -> $\\;
        $" -> $";
        _ -> C
    end,
    csv_parse(Rest, [Char | Current], Acc, InQuote);
csv_parse(<<$", Rest/binary>>, Current, Acc, InQuote) ->
    csv_parse(Rest, Current, Acc, not InQuote);
csv_parse(<<$,, Rest/binary>>, Current, Acc, false) ->
    csv_parse(string:trim(Rest), [],
              [strip_quotes(iolist_to_binary(lists:reverse(Current))) | Acc], false);
csv_parse(<<C, Rest/binary>>, Current, Acc, InQuote) ->
    csv_parse(Rest, [C | Current], Acc, InQuote).

strip_quotes(S) ->
    T = string:trim(S),
    case T of
        <<$", Inner:(byte_size(T)-2)/binary, $">> -> Inner;
        <<$', Inner:(byte_size(T)-2)/binary, $'>> -> Inner;
        _ -> T
    end.

%%--------------------------------------------------------------------
%% Tool execution
%%--------------------------------------------------------------------

-spec execute(binary(), map()) -> binary().
execute(<<"exec">>, Args) ->
    Cmd = arg(Args, [<<"command">>, <<"cmd">>, <<"raw">>, {pos, 0}]),
    to_bin(os:cmd(binary_to_list(Cmd)));

execute(<<"read_file">>, Args) ->
    Path = arg(Args, [<<"path">>, <<"filename">>, <<"raw">>, {pos, 0}]),
    case file:read_file(Path) of
        {ok, Data} -> Data;
        {error, R} -> to_bin(io_lib:format("error: ~p", [R]))
    end;

execute(<<"write_file">>, Args) ->
    Path = arg(Args, [<<"path">>, <<"raw">>, {pos, 0}]),
    Content = arg(Args, [<<"content">>, {pos, 1}]),
    case file:write_file(Path, Content) of
        ok -> <<"ok">>;
        {error, R} -> to_bin(io_lib:format("error: ~p", [R]))
    end;

execute(<<"http_get">>, Args) ->
    Url = arg(Args, [<<"url">>, <<"raw">>, {pos, 0}]),
    case httpc:request(get, {binary_to_list(Url), []},
                       [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, Body}} ->
            to_bin(io_lib:format("HTTP ~p~n~s", [Code, truncate(Body, 4000)]));
        {error, R} ->
            to_bin(io_lib:format("error: ~p", [R]))
    end;

execute(<<"http_post">>, Args) ->
    Url = arg(Args, [<<"url">>, <<"raw">>, {pos, 0}]),
    Body = arg(Args, [<<"body">>, <<"content">>, {pos, 1}]),
    Req = {binary_to_list(Url), [], "text/plain", Body},
    case httpc:request(post, Req, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, RBody}} ->
            to_bin(io_lib:format("HTTP ~p~n~s", [Code, truncate(RBody, 4000)]));
        {error, R} ->
            to_bin(io_lib:format("error: ~p", [R]))
    end;

execute(<<"load_module">>, Args) ->
    Name = arg(Args, [<<"module_name">>, <<"name">>, {pos, 0}]),
    Source = arg(Args, [<<"source">>, <<"erlang_source">>, <<"code">>, {pos, 1}]),
    ModAtom = binary_to_atom(Name, utf8),
    SrcFile = "ebin/" ++ binary_to_list(Name) ++ ".erl",
    ok = file:write_file(SrcFile, Source),
    case compile:file(SrcFile, [binary, return_errors, return_warnings]) of
        {ok, ModAtom, Binary, Warnings} ->
            code:purge(ModAtom),
            {module, ModAtom} = code:load_binary(ModAtom, SrcFile, Binary),
            Exports = ModAtom:module_info(exports),
            ExportStr = format_exports(Exports),
            WarnStr = format_diagnostics(Warnings),
            TestResult = run_tests(ModAtom),
            to_bin(io_lib:format("ok: ~s loaded~n~s~s~s",
                                 [Name, ExportStr, WarnStr, TestResult]));
        {error, Errors, Warnings} ->
            ErrStr = format_diagnostics(Errors ++ Warnings),
            to_bin(io_lib:format("compile error:~n~s", [ErrStr]))
    end;

execute(Name, Args) ->
    to_bin(io_lib:format("unknown tool: ~s(~p)", [Name, Args])).

%%--------------------------------------------------------------------
%% Module loading helpers
%%--------------------------------------------------------------------

format_exports(Exports) ->
    Funs = [io_lib:format("~s/~p", [F, A]) || {F, A} <- Exports, F =/= module_info],
    io_lib:format("exports: ~s~n", [lists:join(", ", Funs)]).

format_diagnostics([]) -> "";
format_diagnostics(DiagList) ->
    lists:flatten([format_file_diags(F, Diags) || {F, Diags} <- DiagList]).

format_file_diags(File, Diags) ->
    [io_lib:format("~s:~p: ~s~n", [File, Line, Mod:format_error(Desc)])
     || {Line, Mod, Desc} <- Diags].

run_tests(Mod) ->
    case erlang:function_exported(Mod, test, 0) of
        true ->
            {Pid, Ref} = spawn_monitor(fun() -> exit({test_result, Mod:test()}) end),
            receive
                {'DOWN', Ref, process, Pid, {test_result, Result}} ->
                    io_lib:format("~ntest/0 passed: ~p", [Result]);
                {'DOWN', Ref, process, Pid, Reason} ->
                    io_lib:format("~ntest/0 CRASHED: ~p", [Reason])
            after 5000 ->
                exit(Pid, kill),
                "\ntest/0 TIMEOUT (5s)"
            end;
        false -> ""
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

arg(Map, Keys) -> arg(Map, Keys, undefined).

arg(_Map, [], Default) when Default =/= undefined -> Default;
arg(Map, [], _) -> to_bin(io_lib:format("~p", [Map]));
arg(Map, [{pos, N} | Rest], Default) ->
    case maps:get(integer_to_binary(N), Map, undefined) of
        undefined -> arg(Map, Rest, Default);
        Val -> to_bin(Val)
    end;
arg(Map, [Key | Rest], Default) ->
    case maps:get(Key, Map, undefined) of
        undefined -> arg(Map, Rest, Default);
        Val -> to_bin(Val)
    end.

-spec to_bin(binary() | string() | atom()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

-spec truncate(binary(), non_neg_integer()) -> binary().
truncate(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) ->
    <<Head:Max/binary, _/binary>> = Bin,
    <<Head/binary, "\n...(truncated)">>.
