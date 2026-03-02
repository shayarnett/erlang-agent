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
Only use tools when the task requires them.
Available Erlang modules: agent, tools, json, theme, widgets, etui_panel.
Loaded modules can call etui_panel:set(id, text) to show status in the TUI footer.">>).

run(Goal) -> run(Goal, #{}).
run(Goal, Opts) ->
    inets:start(), ssl:start(),
    MaxSteps = maps:get(max_steps, Opts, ?MAX_STEPS),
    LlmUrl = maps:get(llm_url, Opts, ?DEFAULT_LLM),
    Model = maps:get(model, Opts, ?DEFAULT_MODEL),
    Api = maps:get(api, Opts, llm:detect_api(LlmUrl)),
    OnStep = maps:get(on_step, Opts, fun default_on_step/2),
    Verbose = maps:get(verbose, Opts, false),
    LlmOpts = #{
        api => Api,
        max_tokens => ?LLM_MAX_TOKENS,
        temperature => ?LLM_TEMPERATURE
    },
    LlmOpts2 = case maps:get(api_key, Opts, undefined) of
        undefined -> LlmOpts;
        Key -> LlmOpts#{api_key => Key}
    end,
    History = [
        #{role => user, content => tools:to_bin(Goal)}
    ],
    loop(LlmUrl, Model, Api, LlmOpts2, History, 0, MaxSteps, OnStep, Verbose).

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

loop(_, _, _, _, History, Step, MaxSteps, OnStep, _Verbose) when Step >= MaxSteps ->
    OnStep(max_steps, MaxSteps),
    {max_steps, lists:last(History)};

loop(LlmUrl, Model, Api, LlmOpts, History, Step, MaxSteps, OnStep, Verbose) ->
    OnStep(step, Step + 1),
    verbose(Verbose, "POST ~s (model=~s, api=~p, msgs=~p)~n",
            [LlmUrl, Model, Api, length(History) + 1]),
    try llm:call(LlmUrl, Model, ?TOOL_SYSTEM, History, LlmOpts) of
        {ok, Msg} ->
            Reply = llm:extract_content(Api, Msg),
            verbose(Verbose, "LLM reply (~p bytes)~n", [byte_size(Reply)]),
            OnStep(llm, Reply),
            case llm:extract_tool_calls(Api, Msg) of
                [{Id, Name, Args} | _] ->
                    %% Structured tool call
                    ArgsDisplay = format_args_display(Args),
                    OnStep(tool, io_lib:format("~s(~s)", [Name, ArgsDisplay])),
                    verbose(Verbose, "executing tool ~s~n", [Name]),
                    Result = tools:execute(Name, Args),
                    verbose(Verbose, "tool result (~p bytes)~n", [byte_size(Result)]),
                    Truncated = tools:truncate(Result, 4000),
                    OnStep(result, Result),
                    H2 = History ++ [
                        llm:assistant_msg(Api, Msg),
                        llm:tool_result_msg(Api, Id, Truncated)
                    ],
                    loop(LlmUrl, Model, Api, LlmOpts, H2, Step + 1, MaxSteps, OnStep, Verbose);
                [] ->
                    %% Text-based fallback
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
                            loop(LlmUrl, Model, Api, LlmOpts, H2, Step + 1, MaxSteps, OnStep, Verbose);
                        none ->
                            OnStep(done, Step + 1),
                            {ok, Reply}
                    end
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
%% Helpers
%%--------------------------------------------------------------------

verbose(true, Fmt, Args) ->
    Msg = io_lib:format("[tool_agent] " ++ Fmt, Args),
    file:write_file("/tmp/tool_agent.log", Msg, [append]);
verbose(false, _, _) -> ok.
