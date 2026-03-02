-module(etui_text_test).
-export([test/0]).

test() ->
    test_visible_width(),
    test_strip_ansi(),
    test_wrap(),
    ok.

test_visible_width() ->
    %% Plain ASCII
    5 = etui_text:visible_width("hello"),
    0 = etui_text:visible_width(""),
    %% Binary input
    5 = etui_text:visible_width(<<"hello">>),
    %% ANSI color codes should not count
    5 = etui_text:visible_width("\e[31mhello\e[0m"),
    5 = etui_text:visible_width("\e[38;5;51mhello\e[39m"),
    %% Multiple ANSI sequences
    2 = etui_text:visible_width("\e[1m\e[31mhi\e[0m"),
    %% Just ANSI, no visible text
    0 = etui_text:visible_width("\e[31m\e[0m"),
    ok.

test_strip_ansi() ->
    %% Basic stripping
    "hello" = etui_text:strip_ansi("\e[31mhello\e[0m"),
    %% Binary input
    <<"hello">> = etui_text:strip_ansi(<<"\e[31mhello\e[0m">>),
    %% No ANSI
    "plain" = etui_text:strip_ansi("plain"),
    %% Empty
    "" = etui_text:strip_ansi(""),
    %% Complex sequences
    "ab" = etui_text:strip_ansi("\e[1m\e[38;5;51ma\e[0m\e[22mb"),
    ok.

test_wrap() ->
    %% Short line, no wrap needed
    ["hello"] = etui_text:wrap("hello", 80),
    %% Line that needs wrapping
    Lines = etui_text:wrap("hello world foo bar", 11),
    true = length(Lines) >= 2,
    %% Empty string
    [""] = etui_text:wrap("", 80),
    %% Preserves newlines
    Result = etui_text:wrap("line1\nline2", 80),
    2 = length(Result),
    ok.
