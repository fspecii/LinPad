#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "ishwl.h"

#define KEY_BACKSPACE 14
#define KEY_TAB 15
#define KEY_ENTER 28

static void resource_unlink(struct wl_resource *resource) {
    wl_list_remove(wl_resource_get_link(resource));
}

static bool same_client(struct wl_resource *a, struct wl_resource *b) {
    return wl_resource_get_client(a) == wl_resource_get_client(b);
}

/* ---- pointer ---- */

static void pointer_set_cursor(struct wl_client *client, struct wl_resource *resource, uint32_t serial,
                               struct wl_resource *surface_resource, int32_t hx, int32_t hy) {
    if (!surface_resource) return;
    struct surface *surface = surface_from_resource(surface_resource);
    if (surface->role == ROLE_NONE)
        surface->role = ROLE_CURSOR;
}

static void pointer_release(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static const struct wl_pointer_interface pointer_impl = {
    .set_cursor = pointer_set_cursor,
    .release = pointer_release,
};

static void pointer_frame(struct server *s, struct wl_resource *surface) {
    struct wl_resource *p;
    wl_resource_for_each(p, &s->pointer_resources)
        if (same_client(p, surface) && wl_resource_get_version(p) >= WL_POINTER_FRAME_SINCE_VERSION)
            wl_pointer_send_frame(p);
}

static void pointer_set_focus(struct server *s, struct surface *surface, double sx, double sy) {
    if (s->pointer_focus == surface)
        return;
    struct wl_resource *p;
    if (s->pointer_focus) {
        uint32_t serial = wl_display_next_serial(s->display);
        wl_resource_for_each(p, &s->pointer_resources)
            if (same_client(p, s->pointer_focus->resource))
                wl_pointer_send_leave(p, serial, s->pointer_focus->resource);
        pointer_frame(s, s->pointer_focus->resource);
        wl_list_remove(&s->pointer_focus_destroy.link);
        wl_list_init(&s->pointer_focus_destroy.link);
    }
    s->pointer_focus = surface;
    if (!surface)
        return;
    wl_signal_add(&surface->destroy_signal, &s->pointer_focus_destroy);
    uint32_t serial = wl_display_next_serial(s->display);
    wl_resource_for_each(p, &s->pointer_resources)
        if (same_client(p, surface->resource))
            wl_pointer_send_enter(p, serial, surface->resource, wl_fixed_from_double(sx), wl_fixed_from_double(sy));
}

static void pointer_focus_destroyed(struct wl_listener *listener, void *data) {
    struct server *s = wl_container_of(listener, s, pointer_focus_destroy);
    wl_list_remove(&s->pointer_focus_destroy.link);
    wl_list_init(&s->pointer_focus_destroy.link);
    s->pointer_focus = NULL;
    s->buttons_down = 0;
}

/* Position (view coordinates) → surface-local coordinates of the surface that
 * should get the event. While a button is held the pressed surface keeps the
 * pointer, like an implicit grab on any desktop. */
static struct surface *pointer_target(struct server *s, struct view *v, double x, double y, double *sx, double *sy) {
    if (s->buttons_down && s->pointer_focus) {
        int32_t ox, oy;
        if (surface_view(s->pointer_focus, &ox, &oy) == v) {
            *sx = x - ox;
            *sy = y - oy;
            return s->pointer_focus;
        }
    }
    if (!v || !v->mapped || !v->xdg || !v->xdg->surface)
        return NULL;
    struct box g = v->xdg->geometry;
    return surface_at(v->xdg->surface, x + g.x, y + g.y, sx, sy);
}

void seat_pointer_motion(struct server *s, struct view *v, double x, double y) {
    if (dnd_grabs_pointer(s)) return;
    double sx = 0, sy = 0;
    struct surface *target = pointer_target(s, v, x, y, &sx, &sy);
    s->pointer_view = v;
    if (target != s->pointer_focus) {
        pointer_set_focus(s, target, sx, sy);
        if (target)
            pointer_frame(s, target->resource);
        return;
    }
    if (!target)
        return;
    struct wl_resource *p;
    wl_resource_for_each(p, &s->pointer_resources)
        if (same_client(p, target->resource))
            wl_pointer_send_motion(p, now_ms(), wl_fixed_from_double(sx), wl_fixed_from_double(sy));
    pointer_frame(s, target->resource);
}

/* A dismissed popup no longer grabs: its client can take seconds under emulation to
 * destroy it, and a press in that time must reach the window, not dismiss again. */
static bool has_grabbing_popup(struct server *s) {
    struct view *v;
    wl_list_for_each(v, &s->views, link)
        if (v->kind == VIEW_POPUP && v->mapped && v->grabbing && !v->dismissed)
            return true;
    return false;
}

void seat_pointer_button(struct server *s, struct view *v, double x, double y, uint32_t button, bool pressed) {
    if (dnd_pointer_button(s, button, pressed)) return;
    /* A press outside the open menu chain only dismisses it, as on other desktops. */
    if (pressed && !s->buttons_down && has_grabbing_popup(s) && (!v || v->kind != VIEW_POPUP)) {
        view_dismiss_popups(s, NULL);
        return;
    }
    if (pressed && v && v->kind == VIEW_POPUP)
        view_dismiss_popups(s, v);

    seat_pointer_motion(s, v, x, y);
    struct surface *target = s->pointer_focus;
    uint32_t bit = 1u << (button & 31);
    if (pressed)
        s->buttons_down |= bit;
    else if (!(s->buttons_down & bit))
        return;
    else
        s->buttons_down &= ~bit;
    if (!target)
        return;
    uint32_t serial = wl_display_next_serial(s->display);
    struct wl_resource *p;
    wl_resource_for_each(p, &s->pointer_resources)
        if (same_client(p, target->resource))
            wl_pointer_send_button(p, serial, now_ms(), button,
                                   pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    pointer_frame(s, target->resource);
}

/* source: WL_POINTER_AXIS_SOURCE_* as sent by the host. Wheel motion is also sent as
 * discrete steps (v5-7) or value120 (v8+), which is what Qt and GTK use for notches;
 * finger scrolling ends with axis_stop, which starts kinetic scrolling in clients. */
void seat_pointer_axis(struct server *s, struct view *v, double dx, double dy, uint32_t source) {
    struct surface *target = s->pointer_focus;
    if (!target)
        return;
    struct wl_resource *p;
    uint32_t time = now_ms();
    const double step = 15; /* surface pixels per wheel notch, as in weston and wlroots */
    wl_resource_for_each(p, &s->pointer_resources) {
        if (!same_client(p, target->resource)) continue;
        uint32_t version = wl_resource_get_version(p);
        if (version >= WL_POINTER_AXIS_SOURCE_SINCE_VERSION)
            wl_pointer_send_axis_source(p, source);
        const double deltas[2] = {dy, dx};
        const uint32_t axes[2] = {WL_POINTER_AXIS_VERTICAL_SCROLL, WL_POINTER_AXIS_HORIZONTAL_SCROLL};
        for (int i = 0; i < 2; i++) {
            if (deltas[i] == 0) continue;
            if (source == WL_POINTER_AXIS_SOURCE_WHEEL) {
                int32_t value120 = (int32_t) (deltas[i] / step * 120);
                if (value120 == 0) value120 = deltas[i] > 0 ? 1 : -1;
                if (version >= WL_POINTER_AXIS_VALUE120_SINCE_VERSION)
                    wl_pointer_send_axis_value120(p, axes[i], value120);
                else if (version >= WL_POINTER_AXIS_DISCRETE_SINCE_VERSION && (value120 >= 120 || value120 <= -120))
                    wl_pointer_send_axis_discrete(p, axes[i], value120 / 120);
            }
            wl_pointer_send_axis(p, time, axes[i], wl_fixed_from_double(deltas[i]));
        }
    }
    pointer_frame(s, target->resource);
}

void seat_pointer_axis_stop(struct server *s) {
    struct surface *target = s->pointer_focus;
    if (!target)
        return;
    struct wl_resource *p;
    uint32_t time = now_ms();
    wl_resource_for_each(p, &s->pointer_resources) {
        if (!same_client(p, target->resource) || wl_resource_get_version(p) < WL_POINTER_AXIS_STOP_SINCE_VERSION)
            continue;
        wl_pointer_send_axis_source(p, WL_POINTER_AXIS_SOURCE_FINGER);
        wl_pointer_send_axis_stop(p, time, WL_POINTER_AXIS_VERTICAL_SCROLL);
        wl_pointer_send_axis_stop(p, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL);
    }
    pointer_frame(s, target->resource);
}

void seat_pointer_leave(struct server *s) {
    if (s->buttons_down)
        return;
    struct wl_resource *focus = s->pointer_focus ? s->pointer_focus->resource : NULL;
    pointer_set_focus(s, NULL, 0, 0);
    if (focus)
        pointer_frame(s, focus);
    s->pointer_view = NULL;
}

/* ---- keyboard ---- */

static void keyboard_release(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static const struct wl_keyboard_interface keyboard_impl = {
    .release = keyboard_release,
};

static int keymap_fd(struct server *s, size_t *size) {
    char path[256];
    snprintf(path, sizeof(path), "%s/keymap-XXXXXX", s->runtime_dir);
    int fd = mkstemp(path);
    if (fd < 0)
        return -1;
    unlink(path);
    *size = strlen(s->keymap_string) + 1;
    if (write(fd, s->keymap_string, *size) != (ssize_t) *size) {
        close(fd);
        return -1;
    }
    return fd;
}

static void keyboard_send_keymap(struct server *s, struct wl_resource *kb) {
    size_t size;
    int fd = keymap_fd(s, &size);
    if (fd < 0) return;
    wl_keyboard_send_keymap(kb, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    close(fd);
}

static void keyboard_send_modifiers(struct server *s, struct wl_resource *kb) {
    wl_keyboard_send_modifiers(kb, wl_display_next_serial(s->display), s->mods_depressed,
                               s->mods_latched, s->mods_locked, s->group);
}

static void keyboard_enter(struct server *s, struct wl_resource *kb, struct surface *surface) {
    struct wl_array keys;
    wl_array_init(&keys);
    wl_keyboard_send_enter(kb, wl_display_next_serial(s->display), surface->resource, &keys);
    wl_array_release(&keys);
    keyboard_send_modifiers(s, kb);
}

static void keyboard_set_focus(struct server *s, struct surface *surface) {
    if (s->keyboard_focus == surface)
        return;
    struct wl_resource *kb;
    if (s->keyboard_focus) {
        uint32_t serial = wl_display_next_serial(s->display);
        wl_resource_for_each(kb, &s->keyboard_resources)
            if (same_client(kb, s->keyboard_focus->resource))
                wl_keyboard_send_leave(kb, serial, s->keyboard_focus->resource);
        wl_list_remove(&s->keyboard_focus_destroy.link);
        wl_list_init(&s->keyboard_focus_destroy.link);
    }
    s->keyboard_focus = surface;
    text_input_focus_changed(s, surface);
    if (!surface)
        return;
    wl_signal_add(&surface->destroy_signal, &s->keyboard_focus_destroy);
    wl_resource_for_each(kb, &s->keyboard_resources)
        if (same_client(kb, surface->resource))
            keyboard_enter(s, kb, surface);
    clipboard_focus_changed(s, wl_resource_get_client(surface->resource));
}

static void keyboard_focus_destroyed(struct wl_listener *listener, void *data) {
    struct server *s = wl_container_of(listener, s, keyboard_focus_destroy);
    wl_list_remove(&s->keyboard_focus_destroy.link);
    wl_list_init(&s->keyboard_focus_destroy.link);
    s->keyboard_focus = NULL;
}

void seat_focus_view(struct server *s, struct view *v) {
    v = view_toplevel(v);
    if (s->focused_view != v) {
        struct view *old = s->focused_view;
        s->focused_view = v;
        if (old && old->activated) {
            old->activated = false;
            if (old->mapped) view_configure(old);
        }
        if (v && !v->activated) {
            v->activated = true;
            if (v->mapped) view_configure(v);
        }
    }
    /* Keyboard focus stays on the toplevel while its popups grab: Qt and GTK route
     * keys to their open popup themselves, and moving wl_keyboard focus to the popup
     * makes Qt's completer take typed keys (and Enter) away from the line edit. */
    keyboard_set_focus(s, v && v->mapped && v->xdg ? v->xdg->surface : NULL);
}

static void update_modifiers(struct server *s) {
    uint32_t depressed = xkb_state_serialize_mods(s->xkb_state, XKB_STATE_MODS_DEPRESSED);
    uint32_t latched = xkb_state_serialize_mods(s->xkb_state, XKB_STATE_MODS_LATCHED);
    uint32_t locked = xkb_state_serialize_mods(s->xkb_state, XKB_STATE_MODS_LOCKED);
    uint32_t group = xkb_state_serialize_layout(s->xkb_state, XKB_STATE_LAYOUT_EFFECTIVE);
    if (depressed == s->mods_depressed && latched == s->mods_latched &&
        locked == s->mods_locked && group == s->group)
        return;
    s->mods_depressed = depressed;
    s->mods_latched = latched;
    s->mods_locked = locked;
    s->group = group;
    if (!s->keyboard_focus) return;
    struct wl_resource *kb;
    wl_resource_for_each(kb, &s->keyboard_resources)
        if (same_client(kb, s->keyboard_focus->resource))
            keyboard_send_modifiers(s, kb);
}

void seat_key(struct server *s, uint32_t keycode, bool pressed) {
    xkb_state_update_key(s->xkb_state, keycode + 8, pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
    if (s->keyboard_focus) {
        uint32_t serial = wl_display_next_serial(s->display);
        struct wl_resource *kb;
        wl_resource_for_each(kb, &s->keyboard_resources)
            if (same_client(kb, s->keyboard_focus->resource))
                wl_keyboard_send_key(kb, serial, now_ms(), keycode,
                                     pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    }
    update_modifiers(s);
}

/* A key press that types one character: the key, the modifier keys to hold and the
 * layout (group) it lives in. */
struct key_recipe {
    xkb_keycode_t keycode;
    xkb_keycode_t mods[2];
    int nmods;
    xkb_layout_index_t layout;
};

static xkb_keycode_t key_with_sym(struct xkb_keymap *keymap, xkb_layout_index_t layout, xkb_keysym_t sym) {
    xkb_keycode_t min = xkb_keymap_min_keycode(keymap), max = xkb_keymap_max_keycode(keymap);
    for (xkb_keycode_t kc = min; kc <= max; kc++) {
        const xkb_keysym_t *syms;
        int n = xkb_keymap_key_get_syms_by_level(keymap, kc, layout, 0, &syms);
        for (int i = 0; i < n; i++)
            if (syms[i] == sym)
                return kc;
    }
    return XKB_KEYCODE_INVALID;
}

/* Tries every layout of the keymap (the active one first) with no modifier, Shift,
 * the third-level key (AltGr) and Shift+AltGr, on a scratch xkb_state, so it finds
 * whatever key the current keymap really uses for the character. */
static bool find_key(struct server *s, uint32_t cp, struct key_recipe *out) {
    xkb_layout_index_t layouts = xkb_keymap_num_layouts(s->keymap);
    xkb_keycode_t min = xkb_keymap_min_keycode(s->keymap), max = xkb_keymap_max_keycode(s->keymap);
    xkb_keycode_t shift = key_with_sym(s->keymap, 0, XKB_KEY_Shift_L);
    for (xkb_layout_index_t i = 0; i < layouts; i++) {
        xkb_layout_index_t layout = (s->group + i) % layouts;
        xkb_keycode_t level3 = key_with_sym(s->keymap, layout, XKB_KEY_ISO_Level3_Shift);
        const xkb_keycode_t combos[4][2] = {
            {XKB_KEYCODE_INVALID, XKB_KEYCODE_INVALID}, {shift, XKB_KEYCODE_INVALID},
            {level3, XKB_KEYCODE_INVALID}, {shift, level3},
        };
        for (int c = 0; c < 4; c++) {
            if (c > 0 && (combos[c][0] == XKB_KEYCODE_INVALID || (c == 3 && level3 == XKB_KEYCODE_INVALID)))
                continue;
            struct xkb_state *state = xkb_state_new(s->keymap);
            if (!state) return false;
            xkb_state_update_mask(state, 0, 0, 0, 0, 0, layout);
            int nmods = 0;
            for (int m = 0; m < 2; m++) {
                if (combos[c][m] == XKB_KEYCODE_INVALID) continue;
                xkb_state_update_key(state, combos[c][m], XKB_KEY_DOWN);
                nmods++;
            }
            for (xkb_keycode_t kc = min; kc <= max; kc++) {
                if (kc == shift || kc == level3) continue;
                if (xkb_state_key_get_utf32(state, kc) != cp) continue;
                *out = (struct key_recipe) {.keycode = kc, .nmods = nmods, .layout = layout,
                                            .mods = {combos[c][0], combos[c][1]}};
                xkb_state_unref(state);
                return true;
            }
            xkb_state_unref(state);
        }
    }
    return false;
}

static void lock_layout(struct server *s, xkb_layout_index_t base, xkb_layout_index_t latched,
                        xkb_layout_index_t locked) {
    xkb_state_update_mask(s->xkb_state,
                          xkb_state_serialize_mods(s->xkb_state, XKB_STATE_MODS_DEPRESSED),
                          xkb_state_serialize_mods(s->xkb_state, XKB_STATE_MODS_LATCHED),
                          xkb_state_serialize_mods(s->xkb_state, XKB_STATE_MODS_LOCKED),
                          base, latched, locked);
    update_modifiers(s);
}

static void type_key(struct server *s, const struct key_recipe *r) {
    xkb_layout_index_t base = xkb_state_serialize_layout(s->xkb_state, XKB_STATE_LAYOUT_DEPRESSED);
    xkb_layout_index_t latched = xkb_state_serialize_layout(s->xkb_state, XKB_STATE_LAYOUT_LATCHED);
    xkb_layout_index_t locked = xkb_state_serialize_layout(s->xkb_state, XKB_STATE_LAYOUT_LOCKED);
    bool other_layout = r->layout != s->group;
    if (other_layout) lock_layout(s, 0, 0, r->layout);
    for (int m = 0; m < r->nmods; m++) seat_key(s, r->mods[m] - 8, true);
    seat_key(s, r->keycode - 8, true);
    seat_key(s, r->keycode - 8, false);
    for (int m = r->nmods - 1; m >= 0; m--) seat_key(s, r->mods[m] - 8, false);
    if (other_layout) lock_layout(s, base, latched, locked);
}

static uint32_t utf8_next(const unsigned char **p) {
    const unsigned char *c = *p;
    uint32_t cp;
    int extra;
    if (c[0] < 0x80) { cp = c[0]; extra = 0; }
    else if ((c[0] & 0xe0) == 0xc0) { cp = c[0] & 0x1f; extra = 1; }
    else if ((c[0] & 0xf0) == 0xe0) { cp = c[0] & 0x0f; extra = 2; }
    else { cp = c[0] & 0x07; extra = 3; }
    c++;
    for (; extra > 0 && (*c & 0xc0) == 0x80; extra--, c++)
        cp = cp << 6 | (*c & 0x3f);
    *p = c;
    return cp;
}

/* Text from an on-screen keyboard has no key codes; replay it through the current
 * keymap, with Shift, AltGr or another of its layouts where the character needs them. */
void seat_type_text(struct server *s, const char *utf8) {
    const unsigned char *p = (const unsigned char *) utf8;
    while (*p) {
        uint32_t cp = utf8_next(&p);
        struct key_recipe recipe = {.layout = s->group};
        switch (cp) {
        case '\n': case '\r': recipe.keycode = KEY_ENTER + 8; break;
        case '\t': recipe.keycode = KEY_TAB + 8; break;
        case '\b': recipe.keycode = KEY_BACKSPACE + 8; break;
        default:
            if (!find_key(s, cp, &recipe)) {
                log_msg(s, "no key for U+%04X in keymap %s", cp, s->keymap_names ? s->keymap_names : "default");
                continue;
            }
        }
        type_key(s, &recipe);
    }
}

/* Layout, variant and option names go into include paths of the XKB rules, so only
 * the characters real names use are accepted (e.g. "ru,us", "ch(de_mac)", "lv3:ralt_alt"). */
static bool valid_xkb_names(const char *text) {
    if (strlen(text) > 128) return false;
    for (const char *p = text; *p; p++)
        if (!strchr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+,:()", *p))
            return false;
    return strstr(text, "..") == NULL;
}

bool seat_set_keymap(struct server *s, const char *layout, const char *variant, const char *options) {
    char label[400];
    snprintf(label, sizeof(label), "%s %s %s", *layout ? layout : "-", *variant ? variant : "-",
             *options ? options : "-");
    if (s->keymap_names && strcmp(label, s->keymap_names) == 0)
        return true;
    if (!valid_xkb_names(layout) || !valid_xkb_names(variant) || !valid_xkb_names(options)) {
        log_msg(s, "keymap: refusing names '%s'", label);
        return false;
    }
    struct xkb_rule_names names = {
        .rules = "evdev", .model = "pc105",
        .layout = *layout ? layout : NULL, .variant = *variant ? variant : NULL,
        .options = *options ? options : NULL,
    };
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(s->xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    struct xkb_state *state = keymap ? xkb_state_new(keymap) : NULL;
    char *string = keymap ? xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1) : NULL;
    if (!state || !string) {
        log_msg(s, "keymap: cannot compile '%s', keeping %s", label, s->keymap_names);
        free(string);
        xkb_state_unref(state);
        xkb_keymap_unref(keymap);
        return false;
    }
    xkb_state_unref(s->xkb_state);
    xkb_keymap_unref(s->keymap);
    free(s->keymap_string);
    free(s->keymap_names);
    s->keymap = keymap;
    s->xkb_state = state;
    s->keymap_string = string;
    s->keymap_names = strdup(label);
    s->mods_depressed = s->mods_latched = s->mods_locked = s->group = 0;
    log_msg(s, "keymap: %s", label);

    /* Every client recompiles from the new keymap (Xwayland applies it to its X server
     * too); the focused one also needs the modifier state that goes with it. */
    struct wl_resource *kb;
    wl_resource_for_each(kb, &s->keyboard_resources) {
        keyboard_send_keymap(s, kb);
        if (s->keyboard_focus && same_client(kb, s->keyboard_focus->resource))
            keyboard_send_modifiers(s, kb);
    }
    return true;
}

/* ---- wl_seat ---- */

static void seat_get_pointer(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct server *s = wl_resource_get_user_data(resource);
    struct wl_resource *p = wl_resource_create(client, &wl_pointer_interface, wl_resource_get_version(resource), id);
    if (!p) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(p, &pointer_impl, s, resource_unlink);
    wl_list_insert(&s->pointer_resources, wl_resource_get_link(p));
}

static void seat_get_keyboard(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct server *s = wl_resource_get_user_data(resource);
    struct wl_resource *kb = wl_resource_create(client, &wl_keyboard_interface, wl_resource_get_version(resource), id);
    if (!kb) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(kb, &keyboard_impl, s, resource_unlink);
    wl_list_insert(&s->keyboard_resources, wl_resource_get_link(kb));

    keyboard_send_keymap(s, kb);
    if (wl_resource_get_version(kb) >= WL_KEYBOARD_REPEAT_INFO_SINCE_VERSION)
        wl_keyboard_send_repeat_info(kb, 30, 500);
    if (s->keyboard_focus && same_client(kb, s->keyboard_focus->resource))
        keyboard_enter(s, kb, s->keyboard_focus);
}

static void seat_get_touch(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    wl_resource_post_error(resource, WL_SEAT_ERROR_MISSING_CAPABILITY, "no touch");
}

static void seat_release(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static const struct wl_seat_interface seat_impl = {
    .get_pointer = seat_get_pointer,
    .get_keyboard = seat_get_keyboard,
    .get_touch = seat_get_touch,
    .release = seat_release,
};

static void seat_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &wl_seat_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &seat_impl, data, NULL);
    wl_seat_send_capabilities(resource, WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);
    if (version >= WL_SEAT_NAME_SINCE_VERSION)
        wl_seat_send_name(resource, "seat0");
}

void seat_init(struct server *s) {
    wl_list_init(&s->pointer_resources);
    wl_list_init(&s->keyboard_resources);
    wl_list_init(&s->pointer_focus_destroy.link);
    wl_list_init(&s->keyboard_focus_destroy.link);
    s->pointer_focus_destroy.notify = pointer_focus_destroyed;
    s->keyboard_focus_destroy.notify = keyboard_focus_destroyed;

    s->xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    /* XKB_DEFAULT_LAYOUT and friends apply until the host sends the iPad's layout. */
    struct xkb_rule_names names = {.rules = "evdev", .model = "pc105"};
    s->keymap = s->xkb ? xkb_keymap_new_from_names(s->xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
    if (!s->keymap) {
        fprintf(stderr, "ishwl: cannot compile the xkb keymap (is xkeyboard-config installed?)\n");
        exit(1);
    }
    s->xkb_state = xkb_state_new(s->keymap);
    s->keymap_string = xkb_keymap_get_as_string(s->keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    s->keymap_names = strdup("default");
    wl_global_create(s->display, &wl_seat_interface, 8, s, seat_bind);
}
