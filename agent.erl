-module(agent).
-export([start/0, start/1, main/0, main/1, stop/0]).
-export([chat/1, chat/2, exec/1, reload/0]).
-export([loop/1]). %% exported for hot code reload via ?MODULE:loop

%% Configuration
-define(DEFAULT_LLM, "http://spark.local:8000/v1/chat/completions").
-define(DEFAULT_MODEL, "glm-4.7-flash").

-define(SYSTEM_PROMPT, <<"You are a concise assistant running on bare metal.

You have these tools:

1. exec(command) - Run a shell command. Returns stdout.
2. read_file(path) - Read a file's contents.
3. write_file(path, content) - Write content to a file.
4. http_get(url) - HTTP GET request. Returns body.
5. http_post(url, body) - HTTP POST request. Returns status + body.
6. load_module(module_name, erlang_source) - Compile and hot-load an Erlang module.
   Write complete module source with -module and -export declarations.
   If the module exports test/0, it auto-runs. Returns compile result + test output.

To use a tool, include this exact line in your response:
tool: tool_name({\"param\": \"value\"})

Arguments are JSON. For multi-line strings use literal newlines in the JSON string value.
After receiving a tool_result(...), continue your task. When done, respond normally without tool:.
Be methodical. Check results before proceeding.">>).

-record(state, {
    llm_url  = ?DEFAULT_LLM,
    model    = ?DEFAULT_MODEL,
    system   = ?SYSTEM_PROMPT,
    history  = [],
    max_steps = 10,
    on_tool  = undefined  %% optional callback: fun(Event, Data) for tool visibility
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

start() -> start(#{}).
start(Opts) ->
    register(agent, spawn(fun() -> init(Opts) end)),
    ok.

main() -> main([]).
main(_Args) ->
    Opts = parse_cli_args(init:get_plain_arguments(), #{}),
    start(Opts).

parse_cli_args([], Acc) -> Acc;
parse_cli_args(["--url", Url | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{llm_url => Url});
parse_cli_args(["--model", Model | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{model => Model});
parse_cli_args(["--system", System | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{system => System});
parse_cli_args(["--verbose" | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{verbose => true});
parse_cli_args([_ | Rest], Acc) ->
    parse_cli_args(Rest, Acc).

stop() ->
    agent ! stop,
    ok.

chat(Prompt) -> chat(Prompt, #{}).
chat(Prompt, Opts) ->
    agent ! {chat, self(), to_bin(Prompt), Opts},
    receive {chat_reply, Reply} -> Reply
    after 120000 -> {error, timeout}
    end.

exec(Cmd) ->
    agent ! {exec, self(), to_bin(Cmd)},
    receive {exec_reply, Reply} -> Reply
    after 30000 -> {error, timeout}
    end.

reload() ->
    code:purge(?MODULE),
    code:load_file(?MODULE),
    agent ! reload,
    ok.

%%--------------------------------------------------------------------
%% Agent loop
%%--------------------------------------------------------------------

init(Opts) ->
    inets:start(),
    ssl:start(),
    State = #state{
        llm_url   = maps:get(llm_url, Opts, ?DEFAULT_LLM),
        model     = maps:get(model, Opts, ?DEFAULT_MODEL),
        system    = to_bin(maps:get(system, Opts, ?SYSTEM_PROMPT)),
        max_steps = maps:get(max_steps, Opts, 10)
    },
    case maps:get(quiet, Opts, false) of
        true -> ok;
        false -> io:format("agent: started (model=~s url=~s)~n",
                           [State#state.model, State#state.llm_url])
    end,
    loop(State).

loop(State) ->
    receive
        {chat, From, Prompt, Opts} ->
            OnTool = maps:get(on_tool, Opts, undefined),
            History = State#state.history ++ [#{role => user, content => Prompt}],
            System = maps:get(system, Opts, State#state.system),
            {Result, FinalHistory} = tool_loop(State, System, History, 0,
                                               State#state.max_steps, OnTool),
            From ! {chat_reply, Result},
            Keep = maps:get(keep_history, Opts, false),
            case Keep of
                true  -> ?MODULE:loop(State#state{history = FinalHistory});
                false -> ?MODULE:loop(State#state{history = []})
            end;

        {exec, From, Cmd} ->
            Result = os:cmd(binary_to_list(Cmd)),
            From ! {exec_reply, {ok, list_to_binary(Result)}},
            ?MODULE:loop(State);

        {set_system, NewSystem} ->
            ?MODULE:loop(State#state{system = to_bin(NewSystem)});

        {set_model, NewModel} ->
            ?MODULE:loop(State#state{model = NewModel});

        clear_history ->
            ?MODULE:loop(State#state{history = []});

        reload ->
            ?MODULE:loop(State);

        stop ->
            ok;

        _Other ->
            ?MODULE:loop(State)
    end.

%%--------------------------------------------------------------------
%% Tool loop: LLM responds, we check for tool calls, execute, repeat
%%--------------------------------------------------------------------

tool_loop(_State, _System, History, Step, MaxSteps, _OnTool) when Step >= MaxSteps ->
    {{error, max_steps}, History};

tool_loop(State, System, History, Step, MaxSteps, OnTool) ->
    case llm_call(State, System, History) of
        {ok, Reply} ->
            case parse_tool_call(Reply) of
                {tool, Name, Args} ->
                    notify(OnTool, tool_call, {Name, Args}),
                    Result = execute_tool(Name, Args),
                    Truncated = truncate(Result, 4000),
                    notify(OnTool, tool_result, {Name, Truncated}),
                    H2 = History ++ [
                        #{role => assistant, content => Reply},
                        #{role => user, content => <<"tool_result(", Truncated/binary, ")">>}
                    ],
                    tool_loop(State, System, H2, Step + 1, MaxSteps, OnTool);
                none ->
                    H2 = History ++ [#{role => assistant, content => Reply}],
                    {{ok, Reply}, H2}
            end;
        {error, Reason} ->
            {{error, Reason}, History}
    end.

notify(undefined, _, _) -> ok;
notify(Fun, Event, Data) -> Fun(Event, Data).

%%--------------------------------------------------------------------
%% Tool parsing (tool: name(args) format)
%%--------------------------------------------------------------------

parse_tool_call(Reply) ->
    Lines = binary:split(Reply, <<"\n">>, [global]),
    parse_tool_lines(Lines).

parse_tool_lines([]) -> none;
parse_tool_lines([Line | Rest]) ->
    Trimmed = string:trim(Line),
    case Trimmed of
        <<"tool:", Call/binary>> ->
            parse_call(string:trim(Call));
        <<"TOOL:", Call/binary>> ->
            parse_call(string:trim(Call));
        _ ->
            parse_tool_lines(Rest)
    end.

parse_call(Call) ->
    case re:run(Call, <<"^([a-z_]+)\\((.*)\\)$">>,
                [{capture, all_but_first, binary}, dotall]) of
        {match, [Name, ArgsStr]} ->
            Args = parse_tool_args(string:trim(ArgsStr)),
            {tool, Name, Args};
        nomatch ->
            none
    end.

%% Parse args: try JSON object first, fall back to CSV-style positional args
parse_tool_args(<<>>) -> #{};
parse_tool_args(<<${, _/binary>> = Json) ->
    try json:decode(Json)
    catch _:_ -> #{<<"raw">> => Json}
    end;
parse_tool_args(ArgsStr) ->
    %% CSV parse respecting quotes — returns list of binaries
    Parsed = csv_parse(ArgsStr),
    %% Convert positional list to map with numeric keys
    maps:from_list(
        lists:zip(
            [integer_to_binary(I) || I <- lists:seq(0, length(Parsed) - 1)],
            Parsed)).

%% Split on commas, respecting quoted strings
csv_parse(Bin) -> csv_parse(Bin, [], [], false).

csv_parse(<<>>, Current, Acc, _) ->
    lists:reverse([strip_quotes(iolist_to_binary(lists:reverse(Current))) | Acc]);
csv_parse(<<$\\, C, Rest/binary>>, Current, Acc, InQuote) ->
    %% Handle escape sequences inside strings
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

execute_tool(<<"exec">>, Args) ->
    Cmd = arg(Args, [<<"command">>, <<"cmd">>, <<"raw">>, {pos, 0}]),
    to_bin(os:cmd(binary_to_list(Cmd)));

execute_tool(<<"read_file">>, Args) ->
    Path = arg(Args, [<<"path">>, <<"filename">>, <<"raw">>, {pos, 0}]),
    case file:read_file(Path) of
        {ok, Data} -> Data;
        {error, R} -> to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"write_file">>, Args) ->
    Path = arg(Args, [<<"path">>, <<"raw">>, {pos, 0}]),
    Content = arg(Args, [<<"content">>, {pos, 1}]),
    case file:write_file(Path, Content) of
        ok -> <<"ok">>;
        {error, R} -> to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"http_get">>, Args) ->
    Url = arg(Args, [<<"url">>, <<"raw">>, {pos, 0}]),
    case httpc:request(get, {binary_to_list(Url), []},
                       [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, Body}} ->
            to_bin(io_lib:format("HTTP ~p~n~s", [Code, truncate(Body, 4000)]));
        {error, R} ->
            to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"http_post">>, Args) ->
    Url = arg(Args, [<<"url">>, <<"raw">>, {pos, 0}]),
    Body = arg(Args, [<<"body">>, <<"content">>, {pos, 1}]),
    Req = {binary_to_list(Url), [], "text/plain", Body},
    case httpc:request(post, Req, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, RBody}} ->
            to_bin(io_lib:format("HTTP ~p~n~s", [Code, truncate(RBody, 4000)]));
        {error, R} ->
            to_bin(io_lib:format("error: ~p", [R]))
    end;

execute_tool(<<"load_module">>, Args) ->
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

execute_tool(Name, Args) ->
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
%% LLM HTTP call (OpenAI-compatible)
%%--------------------------------------------------------------------

llm_call(State, System, Messages) ->
    Body = json:encode(#{
        model => list_to_binary(State#state.model),
        messages => [#{role => system, content => System} | Messages],
        max_tokens => 2048,
        temperature => 0.3,
        chat_template_kwargs => #{enable_thinking => false}
    }),
    Request = {State#state.llm_url, [{"content-type", "application/json"}],
               "application/json", Body},
    case httpc:request(post, Request, [{timeout, 120000}],
                       [{body_format, binary}]) of
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
%% Helpers
%%--------------------------------------------------------------------

%% Extract arg by trying named keys, then positional fallback
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

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

truncate(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) ->
    <<Head:Max/binary, _/binary>> = Bin,
    <<Head/binary, "\n...(truncated)">>.
