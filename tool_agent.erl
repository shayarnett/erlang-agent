-module(tool_agent).
-export([run/1, run/2]).

%% Agentic loop: LLM decides when to call tools, loop until done.
%% Tools: exec (shell commands), read_file, write_file, http_get, http_post
%%
%% Usage:
%%   tool_agent:run("Find what network interfaces are available and get an IP via DHCP").
%%   tool_agent:run("POST 'hello' to http://ctf.local/submit", #{max_steps => 20}).

-define(DEFAULT_LLM, "http://spark.local:8000/v1/chat/completions").
-define(DEFAULT_MODEL, "glm-4.7-flash").
-define(MAX_STEPS, 10).
-define(LLM_MAX_TOKENS, 2048).
-define(LLM_TEMPERATURE, 0.3).

-define(TOOL_SYSTEM, <<"You are a systems agent on a bare-metal Erlang machine.

Tools (use one per response):
- exec(command) — run a shell command
- read_file(path) — read a file
- write_file(path, content) — write a file
- http_get(url) — HTTP GET
- http_post(url, body) — HTTP POST
- load_module(name, source) — compile and hot-load an Erlang module

To call a tool: TOOL: name(arg1, arg2)
You will receive the result. Continue or respond normally when done.">>).

run(Goal) -> run(Goal, #{}).
run(Goal, Opts) ->
    MaxSteps = maps:get(max_steps, Opts, ?MAX_STEPS),
    LlmUrl = maps:get(llm_url, Opts, ?DEFAULT_LLM),
    Model = maps:get(model, Opts, ?DEFAULT_MODEL),
    OnStep = maps:get(on_step, Opts, fun default_on_step/2),
    Verbose = maps:get(verbose, Opts, false),
    History = [
        #{role => user, content => tools:to_bin(Goal)}
    ],
    loop(LlmUrl, Model, History, 0, MaxSteps, OnStep, Verbose).

default_on_step(Type, Data) ->
    case Type of
        step -> io:format("~n--- step ~p ---~n", [Data]);
        llm -> io:format("LLM: ~s~n", [Data]);
        tool -> io:format("TOOL> ~s~n", [Data]);
        result -> io:format("RESULT> ~s~n", [tools:truncate(Data, 500)]);
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
            case tools:parse_response(Reply) of
                {tool, Name, Args} ->
                    ArgsDisplay = format_args_display(Args),
                    OnStep(tool, io_lib:format("~s(~s)", [Name, ArgsDisplay])),
                    verbose(Verbose, "executing tool ~s~n", [Name]),
                    Result = tools:execute(Name, Args),
                    verbose(Verbose, "tool result (~p bytes)~n", [byte_size(Result)]),
                    Truncated = tools:truncate(Result, 4000),
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

%% Format args map for display
format_args_display(Args) when is_map(Args) ->
    Vals = [V || {_, V} <- lists:sort(maps:to_list(Args))],
    lists:join(", ", [tools:to_bin(V) || V <- Vals]);
format_args_display(Args) ->
    io_lib:format("~p", [Args]).

%%--------------------------------------------------------------------
%% LLM call (same as agent.erl but standalone)
%%--------------------------------------------------------------------

llm_call(Url, Model, System, Messages) ->
    inets:start(), ssl:start(),
    Body = json:encode(#{
        model => tools:to_bin(Model),
        messages => [#{role => system, content => System} | Messages],
        max_tokens => ?LLM_MAX_TOKENS,
        temperature => ?LLM_TEMPERATURE,
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
%% Helpers
%%--------------------------------------------------------------------

verbose(true, Fmt, Args) ->
    Msg = io_lib:format("[tool_agent] " ++ Fmt, Args),
    file:write_file("/tmp/tool_agent.log", Msg, [append]);
verbose(false, _, _) -> ok.
