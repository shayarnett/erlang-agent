-module(etui_style).
-export([
    bold/1, dim/1, italic/1, underline/1, inverse/1, strikethrough/1,
    fg/2, bg/2, rgb/4, bg_rgb/4,
    reset/0,
    sgr/2
]).

%% SGR convenience wrappers
bold(Text)          -> sgr(1, Text).
dim(Text)           -> sgr(2, Text).
italic(Text)        -> sgr(3, Text).
underline(Text)     -> sgr(4, Text).
inverse(Text)       -> sgr(7, Text).
strikethrough(Text) -> sgr(9, Text).

%% Standard 16 colors: 0-7 normal, 8-15 bright
fg(Color, Text) when Color >= 0, Color =< 7 ->
    ["\e[", integer_to_list(30 + Color), $m, Text, "\e[39m"];
fg(Color, Text) when Color >= 8, Color =< 15 ->
    ["\e[", integer_to_list(82 + Color), $m, Text, "\e[39m"];
%% 256 colors
fg(Color, Text) when Color >= 0, Color =< 255 ->
    ["\e[38;5;", integer_to_list(Color), $m, Text, "\e[39m"].

bg(Color, Text) when Color >= 0, Color =< 7 ->
    ["\e[", integer_to_list(40 + Color), $m, Text, "\e[49m"];
bg(Color, Text) when Color >= 8, Color =< 15 ->
    ["\e[", integer_to_list(92 + Color), $m, Text, "\e[49m"];
bg(Color, Text) when Color >= 0, Color =< 255 ->
    ["\e[48;5;", integer_to_list(Color), $m, Text, "\e[49m"].

rgb(R, G, B, Text) ->
    ["\e[38;2;", integer_to_list(R), $;, integer_to_list(G), $;, integer_to_list(B), $m,
     Text, "\e[39m"].

bg_rgb(R, G, B, Text) ->
    ["\e[48;2;", integer_to_list(R), $;, integer_to_list(G), $;, integer_to_list(B), $m,
     Text, "\e[49m"].

reset() -> "\e[0m".

%% Generic SGR wrap: sgr(Code, Text) -> apply code, text, undo code
sgr(Code, Text) ->
    Off = sgr_off(Code),
    ["\e[", integer_to_list(Code), $m, Text, "\e[", integer_to_list(Off), $m].

sgr_off(1) -> 22; % bold off
sgr_off(2) -> 22; % dim off
sgr_off(3) -> 23; % italic off
sgr_off(4) -> 24; % underline off
sgr_off(7) -> 27; % inverse off
sgr_off(9) -> 29; % strikethrough off
sgr_off(_) -> 0.
