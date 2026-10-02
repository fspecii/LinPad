/* zwp_text_input_v3: iPadOS text input (accents, dictation, emoji, CJK composition)
 * for apps with a focused text field.
 *
 * The iPad is the input method. While the keyboard-focused app has an enabled text
 * input, the host turns UITextInput calls into `ime` messages, which become
 * delete_surrounding_text / commit_string / preedit_string + done here. The app's
 * state goes the other way: `textinput`, `surrounding` and `caret` tell the host
 * whether to compose, what text surrounds the cursor and where to put candidates.
 * Shortcuts and non-text keys keep using wl_keyboard. */
#include <linux/input-event-codes.h>
#include <stdlib.h>
#include <string.h>
#include "ishwl.h"
#include "text-input-unstable-v3-protocol.h"

/* Surrounding text sent to the host, in bytes on each side of the cursor. UIKit
 * only needs local context, and a message has to fit in one bridge line. */
#define CONTEXT_BYTES 96

/* Keys and text-input updates must reach the app in the order they were typed, but
 * toolkits apply commit_string at once while key events wait in their own queue, so
 * a fast "abc⏎d" can come out "abcd⏎". While a text input is active, each key or
 * update therefore waits for the app's next commit (which follows done, and any edit
 * a key makes), or for ORDER_TIMEOUT_MS for keys that change nothing. */
#define ORDER_TIMEOUT_MS 250

struct pending_input {
    struct wl_list link;
    bool is_key;
    uint32_t keycode;
    bool pressed;
    uint32_t delete_before, delete_after;
    char *commit, *preedit;
    int32_t begin, end;
};

static struct wl_list pending_inputs;
static bool waiting_for_app;
static uint32_t waiting_since;

struct text_input_state {
    char *text;           /* surrounding text, NULL if the app sent none */
    int32_t cursor, anchor;
    uint32_t hint, purpose;
    struct box rect;      /* cursor rectangle, surface coordinates */
};

struct text_input {
    struct wl_resource *resource;
    struct server *server;
    struct wl_list link;  /* server.text_inputs */
    struct surface *focus;
    struct wl_listener focus_destroy;
    bool enabled, pending_enabled;
    uint32_t commits;     /* the serial for done() */
    struct text_input_state current, pending;
};

static struct text_input *active_text_input;

static void state_clear(struct text_input_state *st) {
    free(st->text);
    *st = (struct text_input_state) {0};
}

static struct text_input *find_active(struct server *s) {
    struct text_input *ti;
    wl_list_for_each(ti, &s->text_inputs, link)
        if (ti->focus && ti->enabled)
            return ti;
    return NULL;
}

static struct view *focus_view(struct text_input *ti, int32_t *x, int32_t *y) {
    *x = *y = 0;
    return ti->focus ? surface_view(ti->focus, x, y) : NULL;
}

/* Cuts the text down to CONTEXT_BYTES around the cursor, on UTF-8 boundaries. */
static void send_surrounding(struct text_input *ti, uint32_t view_id) {
    const char *text = ti->current.text ? ti->current.text : "";
    int32_t len = (int32_t) strlen(text);
    int32_t cursor = ti->current.cursor < 0 ? 0 : ti->current.cursor > len ? len : ti->current.cursor;
    int32_t start = cursor > CONTEXT_BYTES ? cursor - CONTEXT_BYTES : 0;
    int32_t end = len - cursor > CONTEXT_BYTES ? cursor + CONTEXT_BYTES : len;
    while (start > 0 && (text[start] & 0xc0) == 0x80) start--;
    while (end < len && (text[end] & 0xc0) == 0x80) end++;
    char *slice = strndup(text + start, (size_t) (end - start));
    char *escaped = slice ? bridge_escape(slice) : NULL;
    if (escaped)
        bridge_send(ti->server, "surrounding %u %s %d\n", view_id, escaped, cursor - start);
    free(escaped);
    free(slice);
}

/* Tells the host which view composes text now, and with what state. */
static void sync_host(struct server *s) {
    struct text_input *ti = find_active(s);
    int32_t x, y;
    struct view *v = ti ? focus_view(ti, &x, &y) : NULL;
    if (ti != active_text_input) {
        active_text_input = ti;
        if (s->verbose)
            log_msg(s, "text input %s in view %u", ti ? "active" : "inactive", v ? v->id : 0);
        if (!ti) {
            bridge_send(s, "textinput 0 0 0 0\n");
            return;
        }
    }
    if (!ti || !v) return;
    bridge_send(s, "textinput %u 1 %u %u\n", v->id, ti->current.purpose, ti->current.hint);
    /* Terminals send none; the host then tracks what it typed itself. */
    if (ti->current.text)
        send_surrounding(ti, v->id);
    struct box r = ti->current.rect;
    bridge_send(s, "caret %u %d %d %d %d\n", v->id, r.x + x, r.y + y, r.w, r.h);
}

static void focus_destroyed(struct wl_listener *listener, void *data) {
    struct text_input *ti = wl_container_of(listener, ti, focus_destroy);
    wl_list_remove(&ti->focus_destroy.link);
    wl_list_init(&ti->focus_destroy.link);
    ti->focus = NULL;
    sync_host(ti->server);
}

static void set_focus(struct text_input *ti, struct surface *surface) {
    if (ti->focus == surface) return;
    if (ti->focus) {
        zwp_text_input_v3_send_leave(ti->resource, ti->focus->resource);
        wl_list_remove(&ti->focus_destroy.link);
        wl_list_init(&ti->focus_destroy.link);
    }
    ti->focus = NULL;
    if (surface && wl_resource_get_client(surface->resource) == wl_resource_get_client(ti->resource)) {
        ti->focus = surface;
        wl_signal_add(&surface->destroy_signal, &ti->focus_destroy);
        zwp_text_input_v3_send_enter(ti->resource, surface->resource);
    }
}

void text_input_focus_changed(struct server *s, struct surface *surface) {
    struct text_input *ti;
    wl_list_for_each(ti, &s->text_inputs, link)
        set_focus(ti, surface);
    sync_host(s);
}

static bool is_modifier(uint32_t keycode) {
    switch (keycode) {
    case KEY_LEFTCTRL: case KEY_RIGHTCTRL: case KEY_LEFTSHIFT: case KEY_RIGHTSHIFT:
    case KEY_LEFTALT: case KEY_RIGHTALT: case KEY_LEFTMETA: case KEY_RIGHTMETA: case KEY_CAPSLOCK:
        return true;
    default:
        return false;
    }
}

static void deliver(struct server *s, struct pending_input *in) {
    struct text_input *ti = find_active(s);
    if (in->is_key) {
        seat_key(s, in->keycode, in->pressed);
    } else if (ti) {
        if (in->delete_before || in->delete_after)
            zwp_text_input_v3_send_delete_surrounding_text(ti->resource, in->delete_before, in->delete_after);
        if (in->commit && *in->commit)
            zwp_text_input_v3_send_commit_string(ti->resource, in->commit);
        zwp_text_input_v3_send_preedit_string(ti->resource, in->preedit && *in->preedit ? in->preedit : NULL,
                                              in->begin, in->end);
        zwp_text_input_v3_send_done(ti->resource, ti->commits);
    }
    /* Releases and modifiers edit nothing; waiting after them would only add lag. */
    waiting_for_app = ti && (!in->is_key || (in->pressed && !is_modifier(in->keycode)));
    waiting_since = now_ms();
}

static void drain(struct server *s) {
    while (!waiting_for_app && !wl_list_empty(&pending_inputs)) {
        struct pending_input *in = wl_container_of(pending_inputs.next, in, link);
        wl_list_remove(&in->link);
        deliver(s, in);
        free(in->commit);
        free(in->preedit);
        free(in);
    }
}

static void submit(struct server *s, struct pending_input in) {
    if (!find_active(s) && wl_list_empty(&pending_inputs)) {
        waiting_for_app = false;
        deliver(s, &in);
        return;
    }
    struct pending_input *queued = malloc(sizeof(*queued));
    if (!queued) return;
    *queued = in;
    queued->commit = in.commit ? strdup(in.commit) : NULL;
    queued->preedit = in.preedit ? strdup(in.preedit) : NULL;
    wl_list_insert(pending_inputs.prev, &queued->link);
    drain(s);
}

void text_input_key(struct server *s, uint32_t keycode, bool pressed) {
    submit(s, (struct pending_input) {.is_key = true, .keycode = keycode, .pressed = pressed});
}

/* ime DELETE_BEFORE DELETE_AFTER COMMIT PREEDIT PREEDIT_BEGIN PREEDIT_END
 * Lengths and preedit cursor offsets are UTF-8 bytes; strings are unescaped. */
void text_input_apply(struct server *s, uint32_t delete_before, uint32_t delete_after,
                      const char *commit, const char *preedit, int32_t begin, int32_t end) {
    submit(s, (struct pending_input) {
        .delete_before = delete_before, .delete_after = delete_after,
        .commit = (char *) commit, .preedit = (char *) preedit, .begin = begin, .end = end,
    });
}

bool text_input_waiting(struct server *s) {
    return waiting_for_app;
}

void text_input_tick(struct server *s) {
    if (waiting_for_app && now_ms() - waiting_since >= ORDER_TIMEOUT_MS) {
        waiting_for_app = false;
        drain(s);
    }
}

static void ti_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void ti_enable(struct wl_client *client, struct wl_resource *resource) {
    struct text_input *ti = wl_resource_get_user_data(resource);
    /* enable resets the state to its defaults; the requests that follow set it. */
    state_clear(&ti->pending);
    ti->pending_enabled = true;
}

static void ti_disable(struct wl_client *client, struct wl_resource *resource) {
    struct text_input *ti = wl_resource_get_user_data(resource);
    ti->pending_enabled = false;
}

static void ti_set_surrounding_text(struct wl_client *client, struct wl_resource *resource,
                                    const char *text, int32_t cursor, int32_t anchor) {
    struct text_input *ti = wl_resource_get_user_data(resource);
    free(ti->pending.text);
    ti->pending.text = strdup(text);
    ti->pending.cursor = cursor;
    ti->pending.anchor = anchor;
}

static void ti_set_text_change_cause(struct wl_client *client, struct wl_resource *resource, uint32_t cause) {
}

static void ti_set_content_type(struct wl_client *client, struct wl_resource *resource,
                                uint32_t hint, uint32_t purpose) {
    struct text_input *ti = wl_resource_get_user_data(resource);
    ti->pending.hint = hint;
    ti->pending.purpose = purpose;
}

static void ti_set_cursor_rectangle(struct wl_client *client, struct wl_resource *resource,
                                    int32_t x, int32_t y, int32_t w, int32_t h) {
    struct text_input *ti = wl_resource_get_user_data(resource);
    ti->pending.rect = (struct box) {x, y, w, h};
}

static void ti_commit(struct wl_client *client, struct wl_resource *resource) {
    struct text_input *ti = wl_resource_get_user_data(resource);
    ti->commits++;
    ti->enabled = ti->pending_enabled;
    state_clear(&ti->current);
    ti->current = ti->pending;
    if (ti->pending.text)
        ti->pending.text = strdup(ti->pending.text);
    sync_host(ti->server);
    waiting_for_app = false;
    drain(ti->server);
}

static const struct zwp_text_input_v3_interface text_input_impl = {
    .destroy = ti_destroy,
    .enable = ti_enable,
    .disable = ti_disable,
    .set_surrounding_text = ti_set_surrounding_text,
    .set_text_change_cause = ti_set_text_change_cause,
    .set_content_type = ti_set_content_type,
    .set_cursor_rectangle = ti_set_cursor_rectangle,
    .commit = ti_commit,
};

static void text_input_resource_destroy(struct wl_resource *resource) {
    struct text_input *ti = wl_resource_get_user_data(resource);
    struct server *s = ti->server;
    wl_list_remove(&ti->link);
    wl_list_remove(&ti->focus_destroy.link);
    state_clear(&ti->current);
    state_clear(&ti->pending);
    free(ti);
    sync_host(s);
}

static void manager_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void manager_get_text_input(struct wl_client *client, struct wl_resource *resource,
                                   uint32_t id, struct wl_resource *seat) {
    struct server *s = wl_resource_get_user_data(resource);
    struct text_input *ti = calloc(1, sizeof(*ti));
    if (!ti) {
        wl_client_post_no_memory(client);
        return;
    }
    ti->resource = wl_resource_create(client, &zwp_text_input_v3_interface, wl_resource_get_version(resource), id);
    if (!ti->resource) {
        free(ti);
        wl_client_post_no_memory(client);
        return;
    }
    ti->server = s;
    wl_list_init(&ti->focus_destroy.link);
    ti->focus_destroy.notify = focus_destroyed;
    wl_list_insert(&s->text_inputs, &ti->link);
    wl_resource_set_implementation(ti->resource, &text_input_impl, ti, text_input_resource_destroy);
    set_focus(ti, s->keyboard_focus);
}

static const struct zwp_text_input_manager_v3_interface manager_impl = {
    .destroy = manager_destroy,
    .get_text_input = manager_get_text_input,
};

static void manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &zwp_text_input_manager_v3_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &manager_impl, data, NULL);
}

void text_input_init(struct server *s) {
    wl_list_init(&s->text_inputs);
    wl_list_init(&pending_inputs);
    wl_global_create(s->display, &zwp_text_input_manager_v3_interface, 1, s, manager_bind);
}
