-module(etui_keys).
-export([parse/1]).

%% Parse raw terminal input into key events.
%% Returns: {key, Atom} | {key, Atom, Mods} | {char, Char} | {paste, Text} | unknown

%% Bracketed paste
parse(<<"\e[200~", Rest/binary>>) ->
    case binary:split(Rest, <<"\e[201~">>) of
        [Pasted, _] -> {paste, Pasted};
        [_] -> {paste, Rest}
    end;
parse("\e[200~" ++ Rest) ->
    case string:split(Rest, "\e[201~") of
        [Pasted, _] -> {paste, Pasted};
        [_] -> {paste, Rest}
    end;

%% Enter/Return
parse(<<13>>) -> {key, enter};
parse([13]) -> {key, enter};
parse(<<10>>) -> {key, enter};
parse([10]) -> {key, enter};

%% Tab
parse(<<9>>) -> {key, tab};
parse([9]) -> {key, tab};

%% Escape
parse(<<27>>) -> {key, escape};
parse([27]) -> {key, escape};

%% Backspace
parse(<<127>>) -> {key, backspace};
parse([127]) -> {key, backspace};
parse(<<8>>) -> {key, backspace};
parse([8]) -> {key, backspace};

%% Arrow keys
parse(<<"\e[A">>) -> {key, up};
parse("\e[A") -> {key, up};
parse(<<"\e[B">>) -> {key, down};
parse("\e[B") -> {key, down};
parse(<<"\e[C">>) -> {key, right};
parse("\e[C") -> {key, right};
parse(<<"\e[D">>) -> {key, left};
parse("\e[D") -> {key, left};

%% Ctrl+arrows
parse(<<"\e[1;5A">>) -> {key, up, [ctrl]};
parse("\e[1;5A") -> {key, up, [ctrl]};
parse(<<"\e[1;5B">>) -> {key, down, [ctrl]};
parse("\e[1;5B") -> {key, down, [ctrl]};
parse(<<"\e[1;5C">>) -> {key, right, [ctrl]};
parse("\e[1;5C") -> {key, right, [ctrl]};
parse(<<"\e[1;5D">>) -> {key, left, [ctrl]};
parse("\e[1;5D") -> {key, left, [ctrl]};

%% Alt+arrows
parse(<<"\e[1;3A">>) -> {key, up, [alt]};
parse("\e[1;3A") -> {key, up, [alt]};
parse(<<"\e[1;3B">>) -> {key, down, [alt]};
parse("\e[1;3B") -> {key, down, [alt]};
parse(<<"\e[1;3C">>) -> {key, right, [alt]};
parse("\e[1;3C") -> {key, right, [alt]};
parse(<<"\e[1;3D">>) -> {key, left, [alt]};
parse("\e[1;3D") -> {key, left, [alt]};

%% Shift+arrows
parse(<<"\e[1;2A">>) -> {key, up, [shift]};
parse("\e[1;2A") -> {key, up, [shift]};
parse(<<"\e[1;2B">>) -> {key, down, [shift]};
parse("\e[1;2B") -> {key, down, [shift]};
parse(<<"\e[1;2C">>) -> {key, right, [shift]};
parse("\e[1;2C") -> {key, right, [shift]};
parse(<<"\e[1;2D">>) -> {key, left, [shift]};
parse("\e[1;2D") -> {key, left, [shift]};

%% Home/End
parse(<<"\e[H">>) -> {key, home};
parse("\e[H") -> {key, home};
parse(<<"\e[F">>) -> {key, 'end'};
parse("\e[F") -> {key, 'end'};
parse(<<"\e[1~">>) -> {key, home};
parse("\e[1~") -> {key, home};
parse(<<"\e[4~">>) -> {key, 'end'};
parse("\e[4~") -> {key, 'end'};

%% Insert/Delete/PageUp/PageDown
parse(<<"\e[2~">>) -> {key, insert};
parse("\e[2~") -> {key, insert};
parse(<<"\e[3~">>) -> {key, delete};
parse("\e[3~") -> {key, delete};
parse(<<"\e[5~">>) -> {key, page_up};
parse("\e[5~") -> {key, page_up};
parse(<<"\e[6~">>) -> {key, page_down};
parse("\e[6~") -> {key, page_down};

%% F1-F12
parse(<<"\eOP">>) -> {key, f1};
parse("\eOP") -> {key, f1};
parse(<<"\eOQ">>) -> {key, f2};
parse("\eOQ") -> {key, f2};
parse(<<"\eOR">>) -> {key, f3};
parse("\eOR") -> {key, f3};
parse(<<"\eOS">>) -> {key, f4};
parse("\eOS") -> {key, f4};
parse(<<"\e[15~">>) -> {key, f5};
parse("\e[15~") -> {key, f5};
parse(<<"\e[17~">>) -> {key, f6};
parse("\e[17~") -> {key, f6};
parse(<<"\e[18~">>) -> {key, f7};
parse("\e[18~") -> {key, f7};
parse(<<"\e[19~">>) -> {key, f8};
parse("\e[19~") -> {key, f8};
parse(<<"\e[20~">>) -> {key, f9};
parse("\e[20~") -> {key, f9};
parse(<<"\e[21~">>) -> {key, f10};
parse("\e[21~") -> {key, f10};
parse(<<"\e[23~">>) -> {key, f11};
parse("\e[23~") -> {key, f11};
parse(<<"\e[24~">>) -> {key, f12};
parse("\e[24~") -> {key, f12};

%% Alt+Enter
parse(<<"\e\r">>) -> {key, enter, [alt]};
parse([27, 13]) -> {key, enter, [alt]};

%% Alt+letter (Esc + char)
parse(<<27, C>>) when C >= $a, C =< $z -> {key, list_to_atom([C]), [alt]};
parse(<<27, C>>) when C >= $A, C =< $Z -> {key, list_to_atom([C + 32]), [alt, shift]};
parse([27, C]) when C >= $a, C =< $z -> {key, list_to_atom([C]), [alt]};
parse([27, C]) when C >= $A, C =< $Z -> {key, list_to_atom([C + 32]), [alt, shift]};

%% Alt+Backspace
parse(<<27, 127>>) -> {key, backspace, [alt]};
parse([27, 127]) -> {key, backspace, [alt]};

%% Ctrl+A through Ctrl+Z (1-26, except 9=tab, 10/13=enter, 8=backspace)
parse(<<C>>) when C >= 1, C =< 26, C =/= 9, C =/= 10, C =/= 13, C =/= 8 ->
    {key, list_to_atom([C + $a - 1]), [ctrl]};
parse([C]) when C >= 1, C =< 26, C =/= 9, C =/= 10, C =/= 13, C =/= 8 ->
    {key, list_to_atom([C + $a - 1]), [ctrl]};

%% Single printable character (binary)
parse(<<C/utf8>>) when C >= 32 -> {char, <<C/utf8>>};

%% Single printable character (list/string) — UTF-8 codepoints
parse([C]) when C >= 32 -> {char, [C]};
%% Multi-byte UTF-8 grapheme as list
parse([C | _] = Str) when C >= 32 ->
    case is_printable_string(Str) of
        true -> {char, Str};
        false -> unknown
    end;

%% Catch-all
parse(_) -> unknown.

is_printable_string([]) -> true;
is_printable_string([C | Rest]) when C >= 32 -> is_printable_string(Rest);
is_printable_string(_) -> false.
