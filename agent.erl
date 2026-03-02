-module(agent).
-export([start/0, start/1, main/0, main/1, stop/0]).
-export([chat/1, chat/2, exec/1, reload/0]).
-export([loop/1]). %% exported for hot code reload via ?MODULE:loop

%% Configuration
-define(DEFAULT_LLM, "http://spark.local:8000/v1/chat/completions").
-define(DEFAULT_MODEL, "glm-4.7-flash").
-define(CHAT_TIMEOUT, 120000).
-define(TOOL_TIMEOUT, 30000).
-define(MAX_STEPS, 10).
-define(LLM_MAX_TOKENS, 2048).
-define(LLM_TEMPERATURE, 0.3).

-define(SYSTEM_PROMPT, <<"You are a concise coding assistant on a bare-metal Erlang system.
Only use tools when the task requires them.
Available Erlang modules: agent, tools, json, theme, widgets, etui_panel.
Loaded modules can call etui_panel:set(id, text) to show status in the TUI footer.">>).

-record(state, {
    llm_url  = ?DEFAULT_LLM,
    model    = ?DEFAULT_MODEL,
    api      = openai,      %% openai | anthropic (auto-detected from URL)
    system   = ?SYSTEM_PROMPT,
    history  = [],
    max_steps = ?MAX_STEPS,
    llm_opts = #{},         %% extra opts passed to llm:call (api_key, etc.)
    on_tool  = undefined    %% optional callback: fun(Event, Data) for tool visibility
}).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start() -> ok.
start() -> start(#{}).

-spec start(map()) -> ok.
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
parse_cli_args(["--api", "anthropic" | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{api => anthropic});
parse_cli_args(["--api", "openai" | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{api => openai});
parse_cli_args(["--api-key", Key | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{api_key => Key});
parse_cli_args(["--verbose" | Rest], Acc) ->
    parse_cli_args(Rest, Acc#{verbose => true});
parse_cli_args([_ | Rest], Acc) ->
    parse_cli_args(Rest, Acc).

-spec stop() -> ok.
stop() ->
    agent ! stop,
    ok.

-spec chat(binary() | string()) -> {ok, binary()} | {error, term()}.
chat(Prompt) -> chat(Prompt, #{}).

-spec chat(binary() | string(), map()) -> {ok, binary()} | {error, term()}.
chat(Prompt, Opts) ->
    agent ! {chat, self(), tools:to_bin(Prompt), Opts},
    receive {chat_reply, Reply} -> Reply
    after ?CHAT_TIMEOUT -> {error, timeout}
    end.

-spec exec(binary() | string()) -> {ok, binary()} | {error, timeout}.
exec(Cmd) ->
    agent ! {exec, self(), tools:to_bin(Cmd)},
    receive {exec_reply, Reply} -> Reply
    after ?TOOL_TIMEOUT -> {error, timeout}
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
    Url = maps:get(llm_url, Opts, ?DEFAULT_LLM),
    Api = maps:get(api, Opts, llm:detect_api(Url)),
    LlmOpts = case maps:get(api_key, Opts, undefined) of
        undefined -> #{};
        Key -> #{api_key => Key}
    end,
    State = #state{
        llm_url   = Url,
        model     = maps:get(model, Opts, ?DEFAULT_MODEL),
        api       = Api,
        system    = tools:to_bin(maps:get(system, Opts, ?SYSTEM_PROMPT)),
        max_steps = maps:get(max_steps, Opts, ?MAX_STEPS),
        llm_opts  = LlmOpts
    },
    case maps:get(quiet, Opts, false) of
        true -> ok;
        false -> io:format("agent: started (model=~s url=~s api=~p)~n",
                           [State#state.model, State#state.llm_url, Api])
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
            ?MODULE:loop(State#state{system = tools:to_bin(NewSystem)});

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
    Api = State#state.api,
    Opts = (State#state.llm_opts)#{
        api => Api,
        max_tokens => ?LLM_MAX_TOKENS,
        temperature => ?LLM_TEMPERATURE,
        timeout => ?CHAT_TIMEOUT
    },
    case llm:call(State#state.llm_url, State#state.model, System, History, Opts) of
        {ok, Msg} ->
            Reply = llm:extract_content(Api, Msg),
            case llm:extract_tool_calls(Api, Msg) of
                [{Id, Name, Args} | _] ->
                    %% Structured tool call from API
                    notify(OnTool, tool_call, {Name, Args}),
                    Result = tools:execute(Name, Args),
                    Truncated = tools:truncate(Result, 4000),
                    notify(OnTool, tool_result, {Name, Truncated}),
                    H2 = History ++ [
                        llm:assistant_msg(Api, Msg),
                        llm:tool_result_msg(Api, Id, Truncated)
                    ],
                    tool_loop(State, System, H2, Step + 1, MaxSteps, OnTool);
                [] ->
                    %% No structured tool calls — try text-based fallback
                    case tools:parse_response(Reply) of
                        {tool, Name, Args} ->
                            notify(OnTool, tool_call, {Name, Args}),
                            Result = tools:execute(Name, Args),
                            Truncated = tools:truncate(Result, 4000),
                            notify(OnTool, tool_result, {Name, Truncated}),
                            H2 = History ++ [
                                #{role => assistant, content => Reply},
                                #{role => user, content => <<"tool_result(", Truncated/binary, ")">>}
                            ],
                            tool_loop(State, System, H2, Step + 1, MaxSteps, OnTool);
                        none ->
                            H2 = History ++ [#{role => assistant, content => Reply}],
                            {{ok, Reply}, H2}
                    end
            end;
        {error, Reason} ->
            {{error, Reason}, History}
    end.

notify(undefined, _, _) -> ok;
notify(Fun, Event, Data) -> Fun(Event, Data).

