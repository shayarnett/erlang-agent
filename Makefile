ERLC = erlc
ERL = erl
EBIN = ebin
SRCS = $(wildcard *.erl)
BEAMS = $(patsubst %.erl,$(EBIN)/%.beam,$(SRCS))

.PHONY: all clean shell agent tool

all: $(BEAMS)

$(EBIN)/%.beam: %.erl | $(EBIN)
	$(ERLC) -o $(EBIN) $<

$(EBIN):
	mkdir -p $(EBIN)

# Interactive shell with all modules loaded
shell: all
	$(ERL) -pa $(EBIN) -sname agent -setcookie hackathon

# Start agent process, drop into shell
agent: all
	$(ERL) -pa $(EBIN) -sname agent -setcookie hackathon \
		-eval 'agent:start().'

# Start agent + SSH daemon
ssh: all
	$(ERL) -pa $(EBIN) -sname agent -setcookie hackathon \
		-eval 'ssh_agent:start().'

# Run tool agent with a goal (use GOAL="...")
tool: all
	$(ERL) -pa $(EBIN) -noshell -sname tool_runner -setcookie hackathon \
		-eval 'inets:start(), ssl:start(), tool_agent:run("$(GOAL)"), halt().'

# Hot reload into running node
reload: all
	$(ERL) -pa $(EBIN) -noshell -sname reloader -setcookie hackathon \
		-eval 'net_kernel:connect_node(agent@$(shell hostname -s)), rpc:call(agent@$(shell hostname -s), agent, reload, []), halt().'

clean:
	rm -rf $(EBIN) priv/ssh
