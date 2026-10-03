# Built inside the iSH guest:
#   apk add build-base wayland-dev wayland-protocols pkgconf zlib-dev libxkbcommon-dev
#   (the desktop's terminal and system info: apk add foot font-jetbrains-mono fastfetch)
#   (+ libx11-dev for ishwl-x11-wm, the X11 apps' window manager)
#   make CC=tools/ccwrap && make install   (ccwrap: see DESIGN.md, iSH wait4 EINTR)
PREFIX ?= /usr/local
PKGS := wayland-server xkbcommon zlib
WP := $(shell pkg-config --variable=pkgdatadir wayland-protocols)
SCANNER := $(shell pkg-config --variable=wayland_scanner wayland-scanner 2>/dev/null || echo wayland-scanner)

CFLAGS ?= -O2 -g
CFLAGS += -DISHWL_PREFIX='"$(PREFIX)"' -std=c11 -D_GNU_SOURCE -Wall -Wextra -Wno-unused-parameter -Igen -Isrc \
          $(shell pkg-config --cflags $(PKGS))
LDLIBS += $(shell pkg-config --libs $(PKGS))

PROTOCOLS := xdg-shell=$(WP)/stable/xdg-shell/xdg-shell.xml \
             xdg-decoration-unstable-v1=$(WP)/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml \
             server-decoration=protocols/server-decoration.xml \
             viewporter=$(WP)/stable/viewporter/viewporter.xml \
             text-input-unstable-v3=$(WP)/unstable/text-input/text-input-unstable-v3.xml \
             xdg-activation-v1=$(WP)/staging/xdg-activation/xdg-activation-v1.xml \
             linux-dmabuf-v1=$(WP)/stable/linux-dmabuf/linux-dmabuf-v1.xml
PROTO_NAMES := $(foreach p,$(PROTOCOLS),$(firstword $(subst =, ,$(p))))
PROTO_HEADERS := $(PROTO_NAMES:%=gen/%-protocol.h)
PROTO_SOURCES := $(PROTO_NAMES:%=gen/%-protocol.c)

SRCS := $(wildcard src/*.c)
OBJS := $(SRCS:src/%.c=build/%.o) $(PROTO_NAMES:%=build/%-protocol.o)

X11_WM := $(shell pkg-config --exists x11 && echo ishwl-x11-wm)

all: ishwl libishwl-scm.so libishwl-compat.so $(X11_WM)

ishwl-x11-wm: x11/ishwl-x11-wm.c
	$(CC) $(CFLAGS) -o $@ $< $(shell pkg-config --libs x11)

ishwl: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

# Preloaded into every app ishwl starts; see src/scm-compat.c.
libishwl-scm.so: src/scm-compat.c
	$(CC) $(CFLAGS) -fPIC -c -o build/scm-compat.pic.o $<
	$(CC) -shared -o $@ build/scm-compat.pic.o

# Preloaded only into the apps /etc/ishwl/apps marks "compat"; see ishwl-launch.
libishwl-compat.so: preload/appcompat.c
	@mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c -o build/appcompat.pic.o $<
	$(CC) -shared -o $@ build/appcompat.pic.o

proto_xml = $(lastword $(subst =, ,$(filter $(1)=%,$(PROTOCOLS))))

gen/%-protocol.h:
	@mkdir -p gen
	$(SCANNER) server-header $(call proto_xml,$*) $@

gen/%-protocol.c:
	@mkdir -p gen
	$(SCANNER) private-code $(call proto_xml,$*) $@

build/%-protocol.o: gen/%-protocol.c
	@mkdir -p build
	$(CC) $(CFLAGS) -c -o $@ $<

build/%.o: src/%.c src/ishwl.h $(PROTO_HEADERS)
	@mkdir -p build
	$(CC) $(CFLAGS) -c -o $@ $<

install: all
	install -Dm755 ishwl $(DESTDIR)$(PREFIX)/bin/ishwl
	install -Dm755 libishwl-scm.so $(DESTDIR)$(PREFIX)/lib/libishwl-scm.so
	install -Dm755 libishwl-compat.so $(DESTDIR)$(PREFIX)/lib/libishwl-compat.so
	install -Dm755 ishwl-session $(DESTDIR)$(PREFIX)/bin/ishwl-session
	install -Dm755 ishwl-launch $(DESTDIR)$(PREFIX)/bin/ishwl-launch
	install -Dm755 ishwl-x11 $(DESTDIR)$(PREFIX)/bin/ishwl-x11
	[ -z "$(X11_WM)" ] || install -Dm755 ishwl-x11-wm $(DESTDIR)$(PREFIX)/bin/ishwl-x11-wm
	[ -e $(DESTDIR)/etc/ishwl/apps ] || install -Dm644 apps $(DESTDIR)/etc/ishwl/apps
	[ -e $(DESTDIR)/etc/ishwl/prewarm ] || install -Dm644 prewarm $(DESTDIR)/etc/ishwl/prewarm
	[ ! -d $(DESTDIR)/usr/lib/firefox-esr ] || { install -Dm644 firefox-prefs.js $(DESTDIR)/usr/lib/firefox-esr/browser/defaults/preferences/ishwl.js && rm -f $(DESTDIR)/usr/lib/firefox-esr/defaults/pref/ishwl.js; }
	install -Dm755 guest/ish-terminal $(DESTDIR)$(PREFIX)/bin/ish-terminal
	install -Dm755 guest/ish-open $(DESTDIR)$(PREFIX)/bin/ish-open
	install -Dm755 guest/ish-device-info $(DESTDIR)$(PREFIX)/bin/ish-device-info
	install -Dm755 guest/neofetch $(DESTDIR)$(PREFIX)/bin/neofetch
	install -Dm755 guest/linpad-fetch $(DESTDIR)$(PREFIX)/bin/linpad-fetch
	for f in guest/foot/*.ini; do install -Dm644 $$f $(DESTDIR)/etc/ish/foot/$${f##*/}; done
	install -Dm644 guest/fastfetch/config.jsonc $(DESTDIR)/etc/xdg/fastfetch/config.jsonc
	install -Dm644 guest/fastfetch/logo.txt $(DESTDIR)/usr/share/ish/logo.txt
	guest/os-release.sh $(DESTDIR)/etc/os-release

clean:
	rm -rf build gen ishwl libishwl-scm.so libishwl-compat.so ishwl-x11-wm

.PHONY: all install clean
.SECONDARY: $(PROTO_SOURCES)
