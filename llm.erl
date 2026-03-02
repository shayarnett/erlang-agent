-module(llm).
-export([call/5, detect_api/1, tool_defs/1]).
-export([extract_content/2, extract_tool_calls/2]).
-export([assistant_msg/2, tool_result_msg/3]).

%% Unified LLM client supporting OpenAI and Anthropic API formats.
%%
%% Usage:
%%   Api = llm:detect_api(Url),
%%   {ok, Msg} = llm:call(Url, Model, System, Messages, #{api => Api}),
%%   Content = llm:extract_content(Api, Msg),
%%   ToolCalls = llm:extract_tool_calls(Api, Msg).

-define(DEFAULT_TIMEOUT, 120000).
-define(DEFAULT_MAX_TOKENS, 2048).
-define(DEFAULT_TEMPERATURE, 0.3).

%%--------------------------------------------------------------------
%% API detection
%%--------------------------------------------------------------------

-spec detect_api(string()) -> openai | anthropic.
detect_api(Url) when is_list(Url) ->
    case lists:suffix("/v1/messages", Url) of
        true -> anthropic;
        false -> openai
    end.

%%--------------------------------------------------------------------
%% Tool definitions in API-specific format
%%--------------------------------------------------------------------

-spec tool_defs(openai | anthropic) -> [map()].
tool_defs(openai) ->
    tools:tool_definitions();
tool_defs(anthropic) ->
    [#{name => Name, description => Desc, input_schema => Params}
     || #{function := #{name := Name, description := Desc, parameters := Params}}
            <- tools:tool_definitions()].

%%--------------------------------------------------------------------
%% LLM HTTP call
%%--------------------------------------------------------------------

-spec call(string(), string(), binary(), [map()], map()) ->
    {ok, map()} | {error, term()}.
call(Url, Model, System, Messages, Opts) ->
    Api = maps:get(api, Opts, openai),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Body = build_request(Api, Model, System, Messages, Opts),
    Headers = request_headers(Api, Opts),
    Req = {Url, Headers, "application/json", Body},
    case httpc:request(post, Req, [{timeout, Timeout}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            parse_response(Api, RespBody);
        {ok, {{_, Code, _}, _, RespBody}} ->
            {error, {http, Code, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Request building
%%--------------------------------------------------------------------

build_request(openai, Model, System, Messages, Opts) ->
    MaxTokens = maps:get(max_tokens, Opts, ?DEFAULT_MAX_TOKENS),
    Temp = maps:get(temperature, Opts, ?DEFAULT_TEMPERATURE),
    json:encode(#{
        model => tools:to_bin(Model),
        messages => [#{role => system, content => System} | Messages],
        tools => tool_defs(openai),
        max_tokens => MaxTokens,
        temperature => Temp,
        chat_template_kwargs => #{enable_thinking => false}
    });
build_request(anthropic, Model, System, Messages, Opts) ->
    MaxTokens = maps:get(max_tokens, Opts, ?DEFAULT_MAX_TOKENS),
    Temp = maps:get(temperature, Opts, ?DEFAULT_TEMPERATURE),
    json:encode(#{
        model => tools:to_bin(Model),
        system => System,
        messages => Messages,
        tools => tool_defs(anthropic),
        max_tokens => MaxTokens,
        temperature => Temp
    }).

request_headers(openai, _Opts) ->
    [{"content-type", "application/json"}];
request_headers(anthropic, Opts) ->
    Base = [{"content-type", "application/json"},
            {"anthropic-version", "2023-06-01"}],
    case maps:get(api_key, Opts, undefined) of
        undefined -> Base;
        Key -> [{"x-api-key", Key} | Base]
    end.

%%--------------------------------------------------------------------
%% Response parsing
%%--------------------------------------------------------------------

parse_response(openai, RespBody) ->
    Decoded = json:decode(RespBody),
    [Choice | _] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    {ok, Msg};
parse_response(anthropic, RespBody) ->
    Decoded = json:decode(RespBody),
    {ok, Decoded}.

%%--------------------------------------------------------------------
%% Content extraction
%%--------------------------------------------------------------------

-spec extract_content(openai | anthropic, map()) -> binary().
extract_content(openai, Msg) ->
    case maps:get(<<"content">>, Msg, null) of
        null -> <<>>;
        C when is_binary(C) -> C;
        _ -> <<>>
    end;
extract_content(anthropic, Msg) ->
    Content = maps:get(<<"content">>, Msg, []),
    TextBlocks = [maps:get(<<"text">>, B, <<>>)
                  || B <- Content,
                     maps:get(<<"type">>, B, <<>>) =:= <<"text">>],
    case TextBlocks of
        [] -> <<>>;
        _ -> iolist_to_binary(lists:join(<<"\n">>, TextBlocks))
    end.

%%--------------------------------------------------------------------
%% Tool call extraction -> [{Id, Name, Args}]
%%--------------------------------------------------------------------

-spec extract_tool_calls(openai | anthropic, map()) -> [{binary(), binary(), map()}].
extract_tool_calls(openai, Msg) ->
    tools:parse_tool_calls(Msg);
extract_tool_calls(anthropic, Msg) ->
    Content = maps:get(<<"content">>, Msg, []),
    ToolUses = [B || B <- Content,
                     maps:get(<<"type">>, B, <<>>) =:= <<"tool_use">>],
    [{maps:get(<<"id">>, B),
      maps:get(<<"name">>, B),
      maps:get(<<"input">>, B, #{})} || B <- ToolUses].

%%--------------------------------------------------------------------
%% History message construction
%%--------------------------------------------------------------------

%% Build assistant message for conversation history
-spec assistant_msg(openai | anthropic, map()) -> map().
assistant_msg(openai, Msg) ->
    Base = #{role => <<"assistant">>},
    B2 = case maps:get(<<"content">>, Msg, null) of
        null -> Base#{content => <<>>};
        C -> Base#{content => C}
    end,
    case maps:get(<<"tool_calls">>, Msg, undefined) of
        undefined -> B2;
        TCs -> B2#{tool_calls => TCs}
    end;
assistant_msg(anthropic, Msg) ->
    #{role => <<"assistant">>, content => maps:get(<<"content">>, Msg, [])}.

%% Build tool result message for conversation history
-spec tool_result_msg(openai | anthropic, binary(), binary()) -> map().
tool_result_msg(openai, Id, Content) ->
    #{role => tool, tool_call_id => Id, content => Content};
tool_result_msg(anthropic, Id, Content) ->
    #{role => <<"user">>, content => [
        #{type => <<"tool_result">>, tool_use_id => Id, content => Content}
    ]}.
