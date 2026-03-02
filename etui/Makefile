SRCDIR = .
EBIN = ebin
SOURCES = $(wildcard $(SRCDIR)/*.erl)
BEAMS = $(patsubst $(SRCDIR)/%.erl,$(EBIN)/%.beam,$(SOURCES))

.PHONY: all clean

all: $(EBIN) $(BEAMS)

$(EBIN):
	mkdir -p $(EBIN)

$(EBIN)/%.beam: $(SRCDIR)/%.erl
	erlc -o $(EBIN) $<

clean:
	rm -rf $(EBIN)
