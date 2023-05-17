
PREFIX ?= /usr/local
BINDIR = $(DESTDIR)$(PREFIX)/bin

CC ?= gcc
CFLAGS ?= -O3 -g -fsanitize=address -march=native

CFLAGS += -Wall -D__PSPIN_USER__
CPPFLAGS += -Ilib -Iinclude
LDFLAGS += -Llib/mqnic
LDLIBS += -lmqnic

LIBMQNIC = lib/mqnic/libmqnic.a

BIN = pspin-user

GENDEPFLAGS = -MD -MP -MF .$(@F).d

ALL_CFLAGS = $(CFLAGS) $(CPPFLAGS) $(GENDEPFLAGS)

all: $(BIN)

FORCE:

$(LIBMQNIC): FORCE
	$(MAKE) -C $(dir $@) $(notdir $@)

%.o: %.c
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

pspin-user: pspin-user.o
	$(CC) $(ALL_CFLAGS) $(LDFLAGS) $^ -o $@

install:
	install -d $(BINDIR)
	install -m 0755 $(BIN) $(BINDIR)

clean:
	rm -f $(BIN)
	rm -f *.o
	rm -f .*.d

-include $(wildcard .*.d)

.PHONY: all install clean FORCE
