
PREFIX ?= /usr/local
INCDIR = $(DESTDIR)$(PREFIX)/include
LIBDIR = $(DESTDIR)$(PREFIX)/lib
DEVLIBDIR = $(LIBDIR)

CC ?= gcc
CFLAGS ?= -O3 -fPIC -g -march=native -D__PSPIN_USER__

CFLAGS += -Wall
CPPFLAGS +=

LIB = libfpspin.a
INCLUDES = fpspin.h

GENDEPFLAGS = -MD -MP -MF .$(@F).d

ALL_CFLAGS = $(CFLAGS) $(CPPFLAGS) $(GENDEPFLAGS)

all: $(LIB)

%.o: %.c
	$(CC) $(ALL_CFLAGS) -c -o $@ $<

libfpspin.a: loader.o
	ar rcs $@ $^

install:
	install -d $(DEVLIBDIR) $(INCDIR)/fpspin
	install -m 0644 $(LIB) $(DEVLIBDIR)
	install -m 0644 $(INCLUDES) $(INCDIR)/fpspin

clean:
	rm -f $(LIB)
	rm -f *.o
	rm -f .*.d

-include $(wildcard .*.d)

.PHONY: all install clean
