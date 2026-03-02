-module(tools_test).
-export([test/0]).

test() ->
    test_parse_args(),
    test_parse_response(),
    test_csv_parse(),
    test_to_bin(),
    test_truncate(),
    ok.

test_parse_args() ->
    %% Empty
    #{} = tools:parse_args(<<>>),
    %% JSON object
    #{<<"key">> := <<"val">>} = tools:parse_args(<<"{\"key\": \"val\"}">>),
    %% CSV positional
    M = tools:parse_args(<<"hello, world">>),
    <<"hello">> = maps:get(<<"0">>, M),
    <<"world">> = maps:get(<<"1">>, M),
    %% Single arg
    M2 = tools:parse_args(<<"single">>),
    <<"single">> = maps:get(<<"0">>, M2),
    %% Quoted CSV
    M3 = tools:parse_args(<<"\"hello world\", foo">>),
    <<"hello world">> = maps:get(<<"0">>, M3),
    <<"foo">> = maps:get(<<"1">>, M3),
    ok.

test_parse_response() ->
    %% Matches "tool: name(args)"
    {tool, <<"exec">>, Args1} = tools:parse_response(<<"Some text\ntool: exec(ls -la)\nMore text">>),
    <<"ls -la">> = maps:get(<<"0">>, Args1),
    %% Matches "TOOL: name(args)"
    {tool, <<"read_file">>, Args2} = tools:parse_response(<<"TOOL: read_file(/etc/hosts)">>),
    <<"/etc/hosts">> = maps:get(<<"0">>, Args2),
    %% No tool call
    none = tools:parse_response(<<"Just a normal response with no tool calls.">>),
    %% Empty response
    none = tools:parse_response(<<>>),
    %% Tool with JSON args
    {tool, <<"exec">>, Args3} = tools:parse_response(<<"tool: exec({\"command\": \"whoami\"})">>),
    <<"whoami">> = maps:get(<<"command">>, Args3),
    ok.

test_csv_parse() ->
    %% Escape sequences
    M1 = tools:parse_args(<<"path, line1\\nline2">>),
    <<"path">> = maps:get(<<"0">>, M1),
    %% The \n should become a real newline
    Val = maps:get(<<"1">>, M1),
    true = binary:match(Val, <<"\n">>) =/= nomatch,
    ok.

test_to_bin() ->
    <<"hello">> = tools:to_bin(<<"hello">>),
    <<"hello">> = tools:to_bin("hello"),
    <<"ok">> = tools:to_bin(ok),
    ok.

test_truncate() ->
    %% Short binary stays unchanged
    <<"hi">> = tools:truncate(<<"hi">>, 10),
    %% Long binary gets truncated
    Long = list_to_binary(lists:duplicate(100, $x)),
    Result = tools:truncate(Long, 10),
    true = byte_size(Result) < 100,
    %% Check truncation marker
    true = binary:match(Result, <<"(truncated)">>) =/= nomatch,
    ok.
