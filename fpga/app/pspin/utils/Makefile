
PREFIX ?= /usr/local
BINDIR = $(DESTDIR)$(PREFIX)/bin

CC ?= gcc
CFLAGS ?= -O3 -g -fsanitize=address -march=native

CFLAGS += -Wall -D__PSPIN_USER__
CPPFLAGS += -Ilib -Iinclude
LDFLAGS += -Llib/mqnic -Llib/fpspin
LDLIBS += -lmqnic -lfpspin

LIBMQNIC = lib/mqnic/libmqnic.a
LIBFPSPIN = lib/fpspin/libfpspin.a

BIN = pspin-user

GENDEPFLAGS = -MD -MP -MF .$(@F).d

ALL_CFLAGS = $(CFLAGS) $(CPPFLAGS) $(GENDEPFLAGS)

all: $(BIN)

FORCE:

$(LIBMQNIC): FORCE
	$(MAKE) -C $(dir $@) $(notdir $@)

$(LIBFPSPIN): FORCE
	$(MAKE) -C $(dir $@) $(notdir $@)

%.o: %.c
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

pspin-user: pspin-user.o $(LIBFPSPIN)
	$(CC) $(ALL_CFLAGS) $(LDFLAGS) $^ $(LDLIBS) -o $@

install:
	install -d $(BINDIR)
	install -m 0755 $(BIN) $(BINDIR)

clean:
	rm -f $(BIN)
	rm -f *.o
	rm -f .*.d

-include $(wildcard .*.d)

.PHONY: all install clean FORCE
