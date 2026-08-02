CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu11

# The threaded build wants its dispatch duplicated at the end of every
# primitive; without this the compiler merges the sixty copies back into one
# and the branch predictor loses what the duplication was for (doc/11-dispatch.md).
NOMERGE := $(shell $(CC) -fno-crossjumping -S -o /dev/null -xc /dev/null 2>/dev/null && echo -fno-crossjumping)

# `ermine` uses a computed goto to get from one word to the next; `ermine-switch`
# is the same kernel with a switch, so that the two can be measured against each
# other (doc/11-dispatch.md).
all: ermine ermine-switch

ermine: src/ermine.c
	$(CC) $(CFLAGS) $(NOMERGE) -o $@ $<

ermine-switch: src/ermine.c
	$(CC) $(CFLAGS) $(NOMERGE) -DERMINE_SWITCH -o $@ $<

# A saved image starts without reading lib/core.erm at all.
core.img: ermine lib/core.erm
	./ermine -e 's" core.img" save-image bye'

test: ermine ermine-switch
	@tests/run.sh

bench: ermine ermine-switch
	@./ermine examples/bench.erm
	@./ermine-switch examples/bench.erm

clean:
	rm -f ermine ermine-switch core.img

.PHONY: all test bench clean
