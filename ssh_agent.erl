-module(ssh_agent).
-export([start/0, start/1, stop/0]).

%% SSH daemon that exposes the agent over SSH.
%% Usage:
%%   ssh_agent:start().
%%   # Then from any terminal:
%%   ssh localhost -p 2222 "what is PCI enumeration?"

-define(DEFAULT_PORT, 2222).
-define(SSH_DIR, "priv/ssh").

start() -> start(#{}).
start(Opts) ->
    ok = agent:start(Opts),
    ok = ssh:start(),
    Port = maps:get(port, Opts, ?DEFAULT_PORT),
    ensure_host_keys(),
    %% Ensure authorized_keys exists (copy public key if needed)
    ensure_authorized_keys(),
    {ok, Sshd} = ssh:daemon(Port, [
        {system_dir, ?SSH_DIR},
        {user_dir, user_ssh_dir()},
        {auth_methods, "publickey"},
        {exec, {direct, fun handle_exec/1}}
    ]),
    io:format("ssh_agent: listening on port ~p~n", [Port]),
    io:format("ssh_agent: try: ssh localhost -p ~p \"hello\"~n", [Port]),
    {ok, Sshd}.

stop() ->
    agent:stop(),
    ssh:stop().

handle_exec(Command) ->
    Prompt = string:trim(Command),
    case agent:chat(Prompt) of
        {ok, Reply} ->
            {ok, binary_to_list(Reply) ++ "\n"};
        {error, Reason} ->
            {error, io_lib:format("error: ~p", [Reason])}
    end.

%%--------------------------------------------------------------------
%% Key management
%%--------------------------------------------------------------------

ensure_host_keys() ->
    filelib:ensure_dir(?SSH_DIR ++ "/"),
    case filelib:is_file(?SSH_DIR ++ "/ssh_host_rsa_key") of
        true -> ok;
        false ->
            os:cmd("ssh-keygen -t rsa -f " ++ ?SSH_DIR ++ "/ssh_host_rsa_key -N ''"),
            os:cmd("ssh-keygen -t ecdsa -f " ++ ?SSH_DIR ++ "/ssh_host_ecdsa_key -N ''"),
            io:format("ssh_agent: generated host keys in ~s~n", [?SSH_DIR])
    end.

user_ssh_dir() ->
    Home = os:getenv("HOME"),
    Home ++ "/.ssh".

ensure_authorized_keys() ->
    SshDir = user_ssh_dir(),
    AuthKeys = SshDir ++ "/authorized_keys",
    case filelib:is_file(AuthKeys) of
        true -> ok;
        false ->
            %% Find any .pub key and add it
            Pubs = filelib:wildcard(SshDir ++ "/id_*.pub"),
            case Pubs of
                [Pub | _] ->
                    {ok, Key} = file:read_file(Pub),
                    ok = file:write_file(AuthKeys, Key),
                    io:format("ssh_agent: created authorized_keys from ~s~n", [Pub]);
                [] ->
                    io:format("ssh_agent: WARNING no public keys found in ~s~n", [SshDir])
            end
    end.
