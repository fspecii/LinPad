#pragma once
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <xkbcommon/xkbcommon.h>

struct box {
    int32_t x, y, w, h;
};

#define ISHWL_X11_APPS "/tmp/ishwl-x11"

/* Larger than any view; view_damage clips it to the view. */
#define FULL_DAMAGE ((struct box) {-(1 << 14), -(1 << 14), 1 << 15, 1 << 15})

static inline bool box_empty(struct box b) { return b.w <= 0 || b.h <= 0; }
struct box box_union(struct box a, struct box b);
struct box box_intersect(struct box a, struct box b);

struct shm_pool {
    int refcount;
    int fd;
    void *data;
    size_t size;
};

struct shm_buffer {
    struct wl_resource *resource;
    struct shm_pool *pool;
    int32_t offset, width, height, stride;
    uint32_t format;
};

struct shm_buffer *shm_buffer_from_resource(struct wl_resource *resource);
static inline void *shm_buffer_data(struct shm_buffer *b) {
    return (uint8_t *) b->pool->data + b->offset;
}
static inline bool shm_buffer_has_alpha(struct shm_buffer *b) {
    return b->format == WL_SHM_FORMAT_ARGB8888;
}

enum surface_role {
    ROLE_NONE,
    ROLE_SUBSURFACE,
    ROLE_XDG,
    ROLE_CURSOR,
};

/* wp_viewport: a source crop in buffer-scale-divided coordinates and/or a
 * destination size; negative means unset. */
struct viewport_state {
    double src_x, src_y, src_w, src_h;
    int32_t dst_w, dst_h;
};

/* A wl_region as its add/subtract rectangles in request order; a point is inside if
 * the last rectangle containing it was added. */
struct region {
    int count, capacity;
    struct region_op {
        bool add;
        struct box box;
    } *ops;
};

struct surface_state {
    bool has_buffer;              /* attach was called */
    struct wl_resource *buffer;   /* NULL = detach */
    struct wl_listener buffer_destroy;
    int32_t dx, dy;
    struct box damage;        /* surface coordinates */
    struct box buffer_damage; /* buffer coordinates */
    int32_t scale;
    bool has_scale;
    struct viewport_state viewport;
    bool has_viewport;
    struct region *input;         /* NULL: the whole surface */
    bool has_input;
    struct wl_list frame_callbacks;
};

struct surface {
    struct wl_resource *resource;
    struct server *server;
    enum surface_role role;

    struct surface_state pending;
    struct surface_state cached;  /* synchronized subsurfaces park state here */
    bool has_cached;

    struct region *input;         /* NULL: the whole surface takes input */
    struct wl_resource *buffer;   /* current, held until replaced */
    struct wl_listener buffer_destroy;
    int32_t width, height;    /* logical: buffer size / scale */
    int32_t scale;            /* wl_surface.set_buffer_scale */
    struct viewport_state viewport;
    struct wl_resource *viewport_resource;
    bool entered_output;
    struct wl_list frame_callbacks;

    struct subsurface *subsurface; /* role ROLE_SUBSURFACE */
    struct xdg_surface *xdg;       /* role ROLE_XDG */
    struct wl_list children;       /* struct subsurface.link, bottom to top */

    struct wl_signal destroy_signal;
};

struct subsurface {
    struct wl_resource *resource;
    struct surface *surface;
    struct surface *parent;
    struct wl_list link;
    int32_t x, y, pending_x, pending_y;
    bool synchronized;
    bool below_parent;
    struct wl_listener parent_destroy;
};

enum view_kind { VIEW_TOPLEVEL, VIEW_POPUP };

struct positioner {
    int32_t width, height;
    struct box anchor_rect;
    uint32_t anchor, gravity, constraint;
    int32_t offset_x, offset_y;
};

struct xdg_surface {
    struct wl_resource *resource;
    struct surface *surface;
    struct view *view;            /* set once get_toplevel/get_popup ran */
    struct box geometry, pending_geometry;
    bool has_geometry, pending_has_geometry;
    uint32_t configure_serial;
    bool configured;              /* the initial configure has been sent */
    bool acked;
    struct wl_listener surface_destroy;
};

struct out_buffer {
    int fd;
    void *data;
    int32_t width, height, stride;
    uint32_t generation;
    char path[128];
};

struct view {
    struct server *server;
    struct wl_list link;
    uint32_t id;
    enum view_kind kind;
    struct xdg_surface *xdg;
    struct wl_resource *role_resource; /* xdg_toplevel or xdg_popup */
    struct view *parent;
    bool mapped;
    bool announced;

    /* toplevel */
    char *title, *app_id;
    bool x11_app;          /* an ishwl-x11 Xwayland: named after its app */
    int32_t min_w, min_h, max_w, max_h;
    int32_t host_width, host_height; /* size the host asked for, 0 = client's choice */
    bool activated, maximized;
    bool fullscreen;          /* xdg set_fullscreen: the client sees its app-scale fullscreen scale */

    /* popup */
    struct positioner positioner;
    int32_t popup_x, popup_y;        /* relative to parent's geometry origin */
    bool grabbing;
    bool dismissed;        /* popup_done sent */

    struct out_buffer out;
    struct wl_list presented_callbacks; /* fired when the host acks frame_seq */
    bool png_dirty;
    struct box damage;
    bool needs_composite;
    bool awaiting_ack;
    uint32_t frame_seq;
    uint32_t frame_sent_ms;
    uint64_t last_png_ms;
};

struct client_seat {
    struct wl_list pointers;  /* wl_resource links */
    struct wl_list keyboards;
};

struct server {
    struct wl_display *display;
    struct wl_event_loop *loop;
    const char *socket_name;
    const char *runtime_dir;  /* frame buffers and the bridge FIFOs live here */
    bool headless;            /* no host: frames are acked locally (and dumped with png_dir) */
    const char *png_dir;
    FILE *frame_log;          /* $ISHWL_FRAMELOG: "MS VIEW SEQ DAMAGE_W DAMAGE_H" per composited frame */
    int verbose;              /* -v: lifecycle; -vv: also every bridge message */

    struct wl_list views;
    uint32_t next_view_id;
    struct wl_event_source *composite_idle;
    bool running;
    struct wl_list orphan_callbacks; /* frame callbacks of surfaces nobody displays */

    int32_t output_width, output_height; /* logical */
    int32_t output_scale;
    struct wl_list output_resources;

    /* seat */
    struct wl_list seat_clients; /* per-client resource lists live on the resources */
    struct wl_list pointer_resources;
    struct wl_list keyboard_resources;
    struct surface *pointer_focus;
    struct view *pointer_view;
    struct surface *keyboard_focus;
    struct view *focused_view;
    uint32_t buttons_down;
    struct wl_listener pointer_focus_destroy;
    struct wl_listener keyboard_focus_destroy;
    struct xkb_context *xkb;
    struct xkb_keymap *keymap;
    struct xkb_state *xkb_state;
    char *keymap_string;
    char *keymap_names;       /* "layout variant options" as the host last set them */
    uint32_t mods_depressed, mods_latched, mods_locked, group;

    /* text input (textinput.c) */
    struct wl_list text_inputs;

    /* clipboard */
    struct wl_list data_devices;
    struct wl_resource *selection_source;
    char *selection;
    size_t selection_len;

    /* bridge */
    int events_fd;
    int notify_fd;
    char event_buf[8192];
    size_t event_len;
};

/* main.c */
uint32_t now_ms(void);
void log_msg(struct server *s, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void spawn_command(struct server *s, const char *command);

/* compositor.c */
void compositor_init(struct server *s);
struct surface *surface_from_resource(struct wl_resource *resource);
void surface_send_frame_done(struct wl_list *callbacks, uint32_t time);
void surface_for_each(struct surface *s, int32_t x, int32_t y,
                      void (*fn)(struct surface *, int32_t, int32_t, void *), void *data);
/* The view a surface is shown in, and the surface's origin in view coordinates. */
struct view *surface_view(struct surface *s, int32_t *x, int32_t *y);
struct surface *surface_at(struct surface *root, double x, double y, double *sx, double *sy);

/* shm.c */
void shm_init(struct server *s);

/* xdg.c */
void xdg_init(struct server *s);
void xdg_surface_committed(struct xdg_surface *xdg);
void view_configure(struct view *v);
void view_send_close(struct view *v);
void view_dismiss_popups(struct server *s, struct view *keep);
struct view *view_by_id(struct server *s, uint32_t id);
struct view *view_toplevel(struct view *v);

/* view.c */
void view_damage(struct view *v, struct box b);
void view_schedule(struct view *v);
void view_ack(struct view *v, uint32_t seq);
void view_check_ack(struct view *v);
void view_announce(struct view *v);
void view_unmap(struct view *v);
void view_destroy(struct view *v);
void view_notify_title(struct view *v);
void composite_all(void *data);
void view_flush_callbacks(struct view *v);

/* seat.c */
void seat_init(struct server *s);
void seat_pointer_motion(struct server *s, struct view *v, double x, double y);
void seat_pointer_button(struct server *s, struct view *v, double x, double y, uint32_t button, bool pressed);
void seat_pointer_axis(struct server *s, struct view *v, double dx, double dy, uint32_t source);
void seat_pointer_axis_stop(struct server *s);
void seat_pointer_leave(struct server *s);
void seat_key(struct server *s, uint32_t keycode, bool pressed);
void seat_type_text(struct server *s, const char *utf8);
/* Recompiles the XKB keymap (rules evdev, model pc105) and re-sends it to every client.
 * Empty fields take libxkbcommon's defaults; returns false and keeps the old keymap
 * when the names are invalid or do not compile. */
bool seat_set_keymap(struct server *s, const char *layout, const char *variant, const char *options);
void seat_focus_view(struct server *s, struct view *v);

/* misc.c: output, decorations, data device */
void misc_globals_init(struct server *s);
void output_client_fullscreen(struct server *s, struct wl_client *client, bool fullscreen);

/* clipboard.c */
void clipboard_init(struct server *s);

/* dmabuf.c: render-node feedback for EGL when the virtio-gpu device exists */
void dmabuf_init(struct server *s);
void clipboard_focus_changed(struct server *s, struct wl_client *client);

/* textinput.c */
void text_input_init(struct server *s);
void text_input_focus_changed(struct server *s, struct surface *surface);
void text_input_apply(struct server *s, uint32_t delete_before, uint32_t delete_after,
                      const char *commit, const char *preedit, int32_t begin, int32_t end);
void text_input_key(struct server *s, uint32_t keycode, bool pressed);
bool text_input_waiting(struct server *s);
void text_input_tick(struct server *s);
void clipboard_set_from_host(struct server *s);

/* dnd.c: drag and drop, see DND-SPEC.md */
void dnd_init(struct server *s);
void dnd_handle(struct server *s, int argc, char **argv);
void dnd_source_offer(struct wl_resource *source, const char *mime);
void dnd_source_actions(struct wl_resource *source, uint32_t actions);
void dnd_start_drag(struct server *s, struct wl_client *client, struct wl_resource *source,
                    struct wl_resource *origin, struct wl_resource *icon, uint32_t serial);
bool dnd_grabs_pointer(struct server *s);
bool dnd_pointer_button(struct server *s, uint32_t button, bool pressed);

/* bridge.c */
void bridge_init(struct server *s);
void bridge_send(struct server *s, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
char *bridge_escape(const char *text);

/* scm-compat.c */
const char *scm_compat_mode(void);

/* png.c */
int png_write(const char *path, const void *pixels, int32_t width, int32_t height, int32_t stride, bool has_alpha);
