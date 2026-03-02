-module(tool_agent).
-export([run/1, run/2]).

%% Agentic loop: LLM decides when to call tools, loop until done.
%% Tools: exec (shell commands), read_file, write_file, http_get, http_post
%%
%% Usage:
%%   tool_agent:run("Find what network interfaces are available and get an IP via DHCP").
%%   tool_agent:run("POST 'hello' to http://ctf.local/submit", #{max_steps => 20}).

-define(TOOL_SYSTEM, <<"You are a bare-metal systems agent. You have these tools:

1. exec(command) - Run a shell command. Returns stdout.
2. read_file(path) - Read a file's contents.
3. write_file(path, content) - Write content to a file.
4. http_get(url) - HTTP GET request. Returns body.
5. http_post(url, body) - HTTP POST request. Returns status + body.
6. load_module(module_name, erlang_source) - Compile and hot-load an Erlang module.
   Write complete module source with -module and -export declarations.
   If the module exports test/0, it auto-runs. Returns compile result + test output.
   The module is immediately available to call from other tools.

To use a tool, respond with EXACTLY this format (one per message):
TOOL: tool_name(arg1, arg2)

After the tool result, continue reasoning. When done, respond normally without TOOL:.
Be methodical. Check results before proceeding. If something fails, try alternatives.">>).

run(Goal) -> run(Goal, #{}).
run(Goal, Opts) ->
    MaxSteps = maps:get(max_steps, Opts, 10),
    LlmUrl = maps:get(llm_url, Opts, "http://spark.local:8000/v1/chat/completions"),
    Model = maps:get(model, Opts, "glm-4.7-flash"),
    OnStep = maps:get(on_step, Opts, fun default_on_step/2),
    Verbose = maps:get(verbose, Opts, false),
    History = [
        #{role => user, content => to_bin(Goal)}
    ],
    loop(LlmUrl, Model, History, 0, MaxSteps, OnStep, Verbose).

default_on_step(Type, Data) ->
    case Type of
        step -> io:format("~n--- step ~p ---~n", [Data]);
        llm -> io:format("LLM: ~s~n", [Data]);
        tool -> io:format("TOOL> ~s~n", [Data]);
        result -> io:format("RESULT> ~s~n", [truncate(Data, 500)]);
        done -> io:format("~n--- done (step ~p) ---~n", [Data]);
        max_steps -> io:format("~n--- max steps (~p) reached ---~n", [Data]);
        error -> io:format("LLM error: ~p~n", [Data])
    end.

loop(_, _, History, Step, MaxSteps, OnStep, _Verbose) when Step >= MaxSteps ->
    OnStep(max_steps, MaxSteps),
    {max_steps, lists:last(History)};

loop(LlmUrl, Model, History, Step, MaxSteps, OnStep, Verbose) ->
    OnStep(step, Step + 1),
    verbose(Verbose, "POST ~s (model=~s, msgs=~p)~n", [LlmUrl, Model, length(History) + 1]),
    try llm_call(LlmUrl, Model, ?TOOL_SYSTEM, History) of
        {ok, Reply} ->
            verbose(Verbose, "LLM reply (~p bytes)~n", [byte_size(Reply)]),
            OnStep(llm, Reply),
            case parse_tool_call(Reply) of
                {tool, Name, Args} ->
                    OnStep(tool, io_lib:format("~s(~s)", [Name, lists:join(", ", Args)])),
                    verbose(Verbose, "executing tool ~s~n", [Name]),
                    Result = execute_tool(Name, Args),
                    verbose(Verbose, "tool result (~p bytes)~n", [byte_size(Result)]),
                    Truncated = truncate(Result, 4000),
                    OnStep(result, Result),
                    H2 = History ++ [
                        #{role => assistant, content => Reply},
                        #{role => user, content => <<"Tool result:\n", Truncated/binary>>}
                    ],
                    loop(LlmUrl, Model, H2, Step + 1, MaxSteps, OnStep, Verbose);
                none ->
                    OnStep(done, Step + 1),
                    {ok, Reply}
            end;
        {error, Reason} ->
            verbose(Verbose, "LLM error: ~p~n", [Reason]),
            OnStep(error, Reason),
            {error, Reason}
    catch
        Class:Error:Stack ->
            verbose(Verbose, "CRASH ~p:~p~n~p~n", [Class, Error, Stack]),
            OnStep(error, {Class, Error}),
            {error, {Class, Error}}
    end.

%%--------------------------------------------------------------------
%% Tool parsing & execution
%%--------------------------------------------------------------------

parse_tool_call(Reply) ->
    Lines = binary:split(Reply, <<"\n">>, [global]),
    parse_tool_lines(Lines).

parse_tool_lines([]) -> none;
parse_tool_lines([Line | Rest]) ->
    case binary:match(Line, <<"TOOL:">>) of
        {Start, 5} ->
            Call = string:trim(binary:part(Line, Start + 5, byte_size(Line) - Start - 5)),
            parse_call(to_bin(Call));
        nomatch ->
            parse_tool_lines(Rest)
    end.

parse_call(Call) ->
    %% Parse "name(arg1, arg2)"
    case re:run(Call, <<"^([a-z_]+)\\((.*)\\)$">>, [{capture, all_but_first, binary}, dotall]) of
        {match, [Name, ArgsStr]} ->
            Args = parse_args(ArgsStr),
            {tool, Name, Args};
        nomatch ->
            none
    end.

parse_args(<<>>) -> [];
parse_args(ArgsStr) ->
    %% Simple CSV parse respecting quotes
    parse_args(ArgsStr, [], [], false).

parse_args(<<>>, Current, Acc, _) ->
    lists:reverse([strip_quotes(lists:reverse(Current)) | Acc]);
parse_args(<<$", Rest/binary>>, Current, Acc, InQuote) ->
    parse_args(Rest, Current, Acc, not InQuote);
parse_args(<<$', Rest/binary>>, Current, Acc, InQuote) ->
    parse_args(Rest, Current, Acc, not InQuote);
parse_args(<<$,, Rest/binary>>, Current, Acc, false) ->
    parse_args(string:trim(Rest), [], [strip_quotes(lists:reverse(Current)) | Acc], false);
parse_args(<<C, Rest/binary>>, Current, Acc, InQuote) ->
    parse_args(Rest, [C | Current], Acc, InQuote).

strip_quotes(Chars) ->
    S = string:trim(list_to_binary(Chars)),
    case S of
        <<$", Inner:(byte_size(S)-2)/binary, $">> -> Inner;
        <<$', Inner:(byte_size(S)-2)/binary, $'>> -> Inner;
        _ -> S
    end.

execute_tool(<<"exec">>, [Cmd]) ->
    to_bin(os:cmd(binary_to_list(Cmd)));

execute_tool(<<"read_file">>, [Path]) ->
    case file:read_file(Path) of
        {ok, Data} -> Data;
        {error, R} -> to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"write_file">>, [Path, Content]) ->
    case file:write_file(Path, Content) of
        ok -> <<"ok">>;
        {error, R} -> to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"http_get">>, [Url]) ->
    inets:start(), ssl:start(),
    case httpc:request(get, {binary_to_list(Url), []}, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, Body}} ->
            to_bin(io_lib:format("HTTP ~p~n~s", [Code, truncate(Body, 4000)]));
        {error, R} ->
            to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"http_post">>, [Url, Body]) ->
    inets:start(), ssl:start(),
    Req = {binary_to_list(Url), [], "text/plain", Body},
    case httpc:request(post, Req, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, RBody}} ->
            to_bin(io_lib:format("HTTP ~p~n~s", [Code, truncate(RBody, 4000)]));
        {error, R} ->
            to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"load_module">>, [Name, Source]) ->
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
            to_bin(io_lib:format("ok: ~s loaded~n~s~s~s", [Name, ExportStr, WarnStr, TestResult]));
        {error, Errors, Warnings} ->
            ErrStr = format_diagnostics(Errors ++ Warnings),
            to_bin(io_lib:format("compile error:~n~s", [ErrStr]))
    end;

execute_tool(Name, Args) ->
    to_bin(io_lib:format("unknown tool: ~s(~p)", [Name, Args])).

%%--------------------------------------------------------------------
%% LLM call (same as agent.erl but standalone)
%%--------------------------------------------------------------------

llm_call(Url, Model, System, Messages) ->
    inets:start(), ssl:start(),
    Body = json:encode(#{
        model => to_bin(Model),
        messages => [#{role => system, content => System} | Messages],
        max_tokens => 2048,
        temperature => 0.3,
        chat_template_kwargs => #{enable_thinking => false}
    }),
    Req = {Url, [{"content-type", "application/json"}], "application/json", Body},
    case httpc:request(post, Req, [{timeout, 120000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            Decoded = json:decode(RespBody),
            [Choice | _] = maps:get(<<"choices">>, Decoded),
            Msg = maps:get(<<"message">>, Choice),
            {ok, maps:get(<<"content">>, Msg)};
        {ok, {{_, Code, _}, _, RespBody}} ->
            {error, {http, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

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

verbose(true, Fmt, Args) ->
    Msg = io_lib:format("[tool_agent] " ++ Fmt, Args),
    file:write_file("/tmp/tool_agent.log", Msg, [append]);
verbose(false, _, _) -> ok.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

truncate(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) ->
    <<Head:Max/binary, _/binary>> = Bin,
    <<Head/binary, "\n...(truncated)">>.
