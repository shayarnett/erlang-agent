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

Tools (use one per response):
- exec(command) — run a shell command
- read_file(path) — read a file
- write_file(path, content) — write a file
- http_get(url) — HTTP GET
- http_post(url, body) — HTTP POST
- load_module(name, source) — compile and hot-load an Erlang module

To call a tool: tool: name({\"key\": \"value\"})
You will receive the result as tool_result(...). Continue or respond normally when done.
Only use tools when the task requires them.">>).

-record(state, {
    llm_url  = ?DEFAULT_LLM,
    model    = ?DEFAULT_MODEL,
    system   = ?SYSTEM_PROMPT,
    history  = [],
    max_steps = ?MAX_STEPS,
    on_tool  = undefined  %% optional callback: fun(Event, Data) for tool visibility
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
    State = #state{
        llm_url   = maps:get(llm_url, Opts, ?DEFAULT_LLM),
        model     = maps:get(model, Opts, ?DEFAULT_MODEL),
        system    = tools:to_bin(maps:get(system, Opts, ?SYSTEM_PROMPT)),
        max_steps = maps:get(max_steps, Opts, ?MAX_STEPS)
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
    case llm_call(State, System, History) of
        {ok, Reply} ->
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
            end;
        {error, Reason} ->
            {{error, Reason}, History}
    end.

notify(undefined, _, _) -> ok;
notify(Fun, Event, Data) -> Fun(Event, Data).

%%--------------------------------------------------------------------
%% LLM HTTP call (OpenAI-compatible)
%%--------------------------------------------------------------------

llm_call(State, System, Messages) ->
    Body = json:encode(#{
        model => list_to_binary(State#state.model),
        messages => [#{role => system, content => System} | Messages],
        max_tokens => ?LLM_MAX_TOKENS,
        temperature => ?LLM_TEMPERATURE,
        chat_template_kwargs => #{enable_thinking => false}
    }),
    Request = {State#state.llm_url, [{"content-type", "application/json"}],
               "application/json", Body},
    case httpc:request(post, Request, [{timeout, ?CHAT_TIMEOUT}],
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
