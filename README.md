# Erlang Agent

Zero-dependency Erlang agent for hackathon use. SSH in, ask questions, run tools — hot reload while running.

## Quick Start

```bash
make shell                           # compile + open Erlang shell
agent:start().                       # start with defaults (GLM-4.7-Flash on spark.local:8000)
agent:chat("hello").                 # {ok, <<"...">>}
agent:stop().
```

## Modules

### agent.erl — Core LLM Process

Persistent process with chat history, model switching, hot reload.

```erlang
agent:start().                                          % defaults
agent:start(#{llm_url => "http://host:8000/v1/chat/completions", model => "model-name"}).

agent:chat("prompt").                                   % one-shot, no history
agent:chat("prompt", #{keep_history => true}).           % multi-turn
agent:exec("ls -la").                                   % run shell command
agent ! {set_system, <<"New system prompt">>}.           % change system prompt
agent ! {set_model, "other-model"}.                      % switch model
agent ! clear_history.                                   % reset conversation
```

### ssh_agent.erl — SSH Daemon

Wraps agent in an SSH server. Any SSH client becomes an inference endpoint.

```bash
make ssh                             # start agent + SSH on port 2222
ssh localhost -p 2222 "What is PCI enumeration?"
```

```erlang
ssh_agent:start().                   % port 2222
ssh_agent:start(#{port => 9999}).    % custom port
```

Auto-generates host keys on first run. Creates `~/.ssh/authorized_keys` from your public key if missing.

### tool_agent.erl — Agentic Loop

LLM decides which tools to call, loops until done or max steps.

**Tools:** `exec(cmd)`, `read_file(path)`, `write_file(path, content)`, `http_get(url)`, `http_post(url, body)`

```erlang
tool_agent:run("Find network interfaces and get an IP via DHCP").
tool_agent:run("POST 'hello' to http://ctf.local/submit", #{max_steps => 20}).
```

```bash
make tool GOAL="List network interfaces on this machine"
```

### json.erl — JSON Codec

Minimal encode/decode. Maps, lists, binaries, atoms, numbers. No dependencies.

## Hot Reload

Edit any `.erl` file, then:

```bash
make reload                          # compiles + pushes to running node
```

Or from the shell:

```erlang
agent:reload().                      % recompile first with: make all
```

No restart, no dropped SSH connections. The agent process switches to new code on next message.

## Configuration

Defaults point at GLM-4.7-Flash on spark.local:8000. Override at start:

```erlang
agent:start(#{
    llm_url => "http://192.168.1.100:8000/v1/chat/completions",
    model   => "glm-4.7-flash",
    system  => <<"You are a bare-metal systems agent.">>
}).
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make all` | Compile all modules to `ebin/` |
| `make shell` | Compile + open interactive shell |
| `make agent` | Compile + start agent process |
| `make ssh` | Compile + start agent + SSH daemon |
| `make tool GOAL="..."` | Run tool agent with a goal |
| `make reload` | Hot reload into running node |
| `make clean` | Remove `ebin/` and generated keys |

## Requirements

- Erlang/OTP 26+ (tested on 28)
- Network access to an OpenAI-compatible LLM endpoint
- No external dependencies
