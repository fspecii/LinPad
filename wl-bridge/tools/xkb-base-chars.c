/* Prints the unshifted character of each USB HID keyboard usage 0x04-0x38 and 0x64
 * (the main block, as UIKey.keyCode reports it) for XKB layouts, in the form of the
 * fingerprint table in DesktopKit's LinuxKeyboardLayout.swift:
 *   xkb-base-chars de:mac fr:mac ru:mac ...
 *   "de:mac": "abcdefghijklmnopqrstuvwxzy1234567890     ß ü+##öä^,.-<",
 * A space stands for a key with no character (dead keys, Return, Tab, ...); the space
 * bar itself is a space too, so it never distinguishes layouts. Build in the guest:
 *   cc -o xkb-base-chars tools/xkb-base-chars.c $(pkg-config --cflags --libs xkbcommon) */
#include <stdio.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

/* HID usage 0x04 + i -> evdev code (Linux hid-input), then usage 0x64. */
static const int evdev[] = {
    30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
    2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 28, 1, 14, 15, 57, 12, 13, 26, 27, 43, 43, 39, 40, 41, 51, 52, 53, 86,
};

static void put_utf8(unsigned cp) {
    if (cp < 0x80) putchar((int) cp);
    else if (cp < 0x800) printf("%c%c", 0xc0 | cp >> 6, 0x80 | (cp & 0x3f));
    else if (cp < 0x10000) printf("%c%c%c", 0xe0 | cp >> 12, 0x80 | (cp >> 6 & 0x3f), 0x80 | (cp & 0x3f));
    else printf("%c%c%c%c", 0xf0 | cp >> 18, 0x80 | (cp >> 12 & 0x3f), 0x80 | (cp >> 6 & 0x3f), 0x80 | (cp & 0x3f));
}

int main(int argc, char **argv) {
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    int status = 0;
    for (int a = 1; a < argc; a++) {
        char layout[64], *variant;
        snprintf(layout, sizeof(layout), "%s", argv[a]);
        variant = strchr(layout, ':');
        if (variant) *variant++ = '\0';
        struct xkb_rule_names names = {.rules = "evdev", .model = "pc105", .layout = layout, .variant = variant};
        struct xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (!keymap) {
            fprintf(stderr, "cannot compile %s\n", argv[a]);
            status = 1;
            continue;
        }
        struct xkb_state *state = xkb_state_new(keymap);
        printf("        \"%s\": \"", argv[a]);
        for (size_t i = 0; i < sizeof(evdev) / sizeof(evdev[0]); i++) {
            unsigned cp = xkb_state_key_get_utf32(state, (xkb_keycode_t) evdev[i] + 8);
            if (cp == '"' || cp == '\\') printf("\\%c", cp);
            else if (cp <= ' ' || cp == 0x7f) putchar(' ');
            else put_utf8(cp);
        }
        printf("\",\n");
        xkb_state_unref(state);
        xkb_keymap_unref(keymap);
    }
    return status;
}
