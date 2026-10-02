#!/bin/sh
# Guest-side test of keyboard layouts: a headless ishwl, the keymap-test client, and the
# host's bridge messages written by hand. Run inside the guest from a wl-bridge checkout
# that has been built (make CC=tools/ccwrap):
#   sh tools/keymap-test.sh
# Needs: wayland-dev wayland-protocols libxkbcommon-dev xkeyboard-config, libx11 (Compose).
set -u
cd "$(dirname "$0")/.."
XDG=$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
B=build/keymap-test
mkdir -p "$B"
wayland-scanner client-header "$XDG" "$B/xdg-shell-client.h"
wayland-scanner private-code "$XDG" "$B/xdg-shell.c"
${CC:-cc} -o "$B/keymap-test" tools/keymap-test.c "$B/xdg-shell.c" -I"$B" \
    $(pkg-config --cflags --libs wayland-client xkbcommon) || exit 1

RT=/tmp/keymap-test-rt
SOCK=wl-keymap-test
export XDG_RUNTIME_DIR=/tmp/keymap-test-xdg
rm -rf "$RT" "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
./ishwl -H -r "$RT" -s "$SOCK" -v >"$B/ishwl.log" 2>&1 &
ishwl=$!
for _ in $(seq 50); do [ -p "$RT/events" ] && break; sleep 0.2; done
WAYLAND_DISPLAY=$SOCK LC_ALL=C "$B/keymap-test" 30 >"$B/client.log" 2>&1 &
client=$!
for _ in $(seq 50); do grep -q "keymap 1" "$B/client.log" && break; sleep 0.2; done
# X11 apps: a rootful Xwayland is one more wl_keyboard client and must follow too.
xwayland=
if command -v Xwayland >/dev/null && command -v xkbcomp >/dev/null; then
    rm -f /tmp/.X11-unix/X7 /tmp/.X7-lock
    WAYLAND_DISPLAY=$SOCK Xwayland :7 -geometry 320x200 -nolisten tcp -noreset >"$B/xwayland.log" 2>&1 &
    xwayland=$!
    for _ in $(seq 100); do [ -S /tmp/.X11-unix/X7 ] && break; sleep 0.2; done
fi
x_layout() { # the X server's group 1 name, as the app would see it
    [ -n "$xwayland" ] && xkbcomp -xkb :7 - 2>/dev/null | sed -n 's/.*name\[[Gg]roup1\] *= *"\(.*\)";.*/\1/p' | head -1
}

send() { printf '%s\n' "$@" > "$RT/events"; sleep 1; }
tap() { for k in "$@"; do send "key $k 1" "key $k 0"; done; }

send "focus 1"
send "keymap de - -"
# de: the US Z position is y, [ is ü, - is ß, AltGr-Q is @, ´ (dead) then e is é.
tap 44 26 12
send "key 100 1" "key 16 1" "key 16 0" "key 100 0"
tap 13 18
[ -n "$xwayland" ] && x_layout > "$B/x-after-de.txt"
# On-screen keyboard text: Shift, AltGr and plain keys of the de keymap.
send "text Ü€{z"
send "keymap de mac -"
# Cyrillic first, Latin second: Latin text needs the second layout.
send "keymap ru,us mac, -"
send "text hi"
send "keymap fr mac lv3:ralt_alt"
send "keymap de mac lv3:alt_switch"
# Refused or uncompilable names keep the current keymap.
send "keymap ../../etc - -"
send "keymap nosuchlayout - -"
send "keymap gb mac -"

wait $client
[ -n "$xwayland" ] && x_layout > "$B/x-after-gb.txt" && kill $xwayland 2>/dev/null
kill $ishwl 2>/dev/null
wait $ishwl 2>/dev/null

echo "--- client"
cat "$B/client.log"
echo "--- ishwl (keymap lines)"
grep -E "keymap|no key" "$B/ishwl.log"

fails=0
check() { # DESCRIPTION PATTERN FILE
    if grep -qE "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
L=$B/client.log
check "compose table for the C locale" '^compose C: ok' "$L"
check "initial keymap is us" '^keymap 1 "English \(US\)".* Y=y Z=z' "$L"
check "de: Z/Y swapped, ü, ß, AltGr-Q=@" '^keymap 2 "German".* Y=z Z=y Q=q .*\[=ü -=ß .*Q\+R=@' "$L"
check "de keys typed y ü ß @ é" '^text yüß@é$' "$L"
check "de text replay Ü € { z" '^text yüß@éÜ€\{z$' "$L"
check "de(mac): right Option-L is @, Option-5 is [, left Option is Alt" '^keymap 3 "German \(Macintosh\)".* L\+R=@ .*5\+R=\[ L\+L=l' "$L"
check "ru,us: Cyrillic first" '^keymap 4 "Russian \(Macintosh\)" layouts=2 .*Q=й' "$L"
check "ru,us: Latin text through the second layout" '^text yüß@éÜ€\{zhi$' "$L"
check "fr(mac) + ralt_alt: AZERTY, right Option is Alt" '^keymap 5 "French \(Macintosh\)".* Q=a A=q .*Q\+R=a ' "$L"
check "de(mac) + alt_switch: both Option keys are AltGr" '^keymap 6 "German \(Macintosh\)".* L\+R=@ .* L\+L=@' "$L"
check "bad names refused, unknown layout kept old keymap" '^keymap 7 "English \(UK, Macintosh\)"' "$L"
check "only seven keymaps were sent" '^keymap 7 ' "$L"
if grep -q '^keymap 8 ' "$L"; then echo "FAIL extra keymap"; fails=$((fails + 1)); fi
check "ishwl refused ../" "refusing names '\.\./\.\./etc" "$B/ishwl.log"
check "ishwl kept the keymap on a compile error" "cannot compile 'nosuchlayout" "$B/ishwl.log"
if [ -n "$xwayland" ]; then
    echo "Xwayland layout after de: $(cat "$B/x-after-de.txt"), at the end: $(cat "$B/x-after-gb.txt")"
    check "Xwayland took the de keymap" '^German$' "$B/x-after-de.txt"
    check "Xwayland took the later gb(mac) keymap" '^English \(UK, Macintosh\)$' "$B/x-after-gb.txt"
else
    echo "skip Xwayland (not installed)"
fi
echo "keymap-test: $fails failure(s)"
[ $fails = 0 ]
