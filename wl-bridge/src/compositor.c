#include <stdlib.h>
#include <string.h>
#include "ishwl.h"
#include "viewporter-protocol.h"

struct box box_union(struct box a, struct box b) {
    if (box_empty(a)) return b;
    if (box_empty(b)) return a;
    int32_t x0 = a.x < b.x ? a.x : b.x, y0 = a.y < b.y ? a.y : b.y;
    int32_t x1 = a.x + a.w > b.x + b.w ? a.x + a.w : b.x + b.w;
    int32_t y1 = a.y + a.h > b.y + b.h ? a.y + a.h : b.y + b.h;
    return (struct box) {x0, y0, x1 - x0, y1 - y0};
}

struct box box_intersect(struct box a, struct box b) {
    int32_t x0 = a.x > b.x ? a.x : b.x, y0 = a.y > b.y ? a.y : b.y;
    int32_t x1 = a.x + a.w < b.x + b.w ? a.x + a.w : b.x + b.w;
    int32_t y1 = a.y + a.h < b.y + b.h ? a.y + a.h : b.y + b.h;
    if (x1 <= x0 || y1 <= y0) return (struct box) {0, 0, 0, 0};
    return (struct box) {x0, y0, x1 - x0, y1 - y0};
}

/* Damage coordinates are clamped so a client asking for INT32_MAX damage
 * (wayland's "everything" idiom) cannot overflow the box arithmetic. */
static struct box clamp_damage(int32_t x, int32_t y, int32_t w, int32_t h) {
    const int32_t limit = 1 << 15;
    if (x < -limit) x = -limit;
    if (y < -limit) y = -limit;
    if (w > limit) w = limit;
    if (h > limit) h = limit;
    return (struct box) {x, y, w, h};
}

void surface_send_frame_done(struct wl_list *callbacks, uint32_t time) {
    struct wl_resource *cb, *tmp;
    wl_resource_for_each_safe(cb, tmp, callbacks) {
        wl_callback_send_done(cb, time);
        wl_resource_destroy(cb);
    }
}

static void callback_resource_destroy(struct wl_resource *resource) {
    wl_list_remove(wl_resource_get_link(resource));
}

/* ---- regions ---- */

static void region_free(struct region *r) {
    if (!r) return;
    free(r->ops);
    free(r);
}

static struct region *region_copy(const struct region *r) {
    struct region *copy = calloc(1, sizeof(*copy));
    if (!copy) return NULL;
    if (r && r->count) {
        copy->ops = malloc(sizeof(*copy->ops) * (size_t) r->count);
        if (!copy->ops) {
            free(copy);
            return NULL;
        }
        memcpy(copy->ops, r->ops, sizeof(*copy->ops) * (size_t) r->count);
        copy->count = copy->capacity = r->count;
    }
    return copy;
}

static bool region_contains(const struct region *r, double x, double y) {
    if (!r) return true;
    for (int i = r->count - 1; i >= 0; i--) {
        struct box b = r->ops[i].box;
        if (x >= b.x && y >= b.y && x < (double) b.x + b.w && y < (double) b.y + b.h)
            return r->ops[i].add;
    }
    return false;
}

/* ---- surface state ---- */

static void state_buffer_destroyed(struct wl_listener *listener, void *data) {
    struct surface_state *st = wl_container_of(listener, st, buffer_destroy);
    st->buffer = NULL;
    wl_list_remove(&st->buffer_destroy.link);
    wl_list_init(&st->buffer_destroy.link);
}

static void state_init(struct surface_state *st) {
    *st = (struct surface_state) {0};
    st->viewport = (struct viewport_state) {-1, -1, -1, -1, -1, -1};
    wl_list_init(&st->frame_callbacks);
    wl_list_init(&st->buffer_destroy.link);
    st->buffer_destroy.notify = state_buffer_destroyed;
}

static void state_set_buffer(struct surface_state *st, struct wl_resource *buffer) {
    wl_list_remove(&st->buffer_destroy.link);
    wl_list_init(&st->buffer_destroy.link);
    st->buffer = buffer;
    st->has_buffer = true;
    if (buffer)
        wl_resource_add_destroy_listener(buffer, &st->buffer_destroy);
}

static void state_finish(struct surface_state *st) {
    region_free(st->input);
    struct wl_resource *cb, *tmp;
    wl_resource_for_each_safe(cb, tmp, &st->frame_callbacks)
        wl_resource_destroy(cb);
    wl_list_remove(&st->buffer_destroy.link);
}

/* Moves `from` on top of `to`, as if both commits had happened in order. */
static void state_merge(struct surface_state *to, struct surface_state *from) {
    if (from->has_buffer) {
        state_set_buffer(to, from->buffer);
        to->dx += from->dx;
        to->dy += from->dy;
    }
    to->damage = box_union(to->damage, from->damage);
    to->buffer_damage = box_union(to->buffer_damage, from->buffer_damage);
    if (from->has_scale) {
        to->scale = from->scale;
        to->has_scale = true;
    }
    if (from->has_viewport) {
        to->viewport = from->viewport;
        to->has_viewport = true;
    }
    if (from->has_input) {
        region_free(to->input);
        to->input = from->input;
        to->has_input = true;
    }
    wl_list_insert_list(to->frame_callbacks.prev, &from->frame_callbacks);
    wl_list_init(&from->frame_callbacks);
    wl_list_remove(&from->buffer_destroy.link);
    state_init(from);
}

static void surface_buffer_destroyed(struct wl_listener *listener, void *data) {
    struct surface *s = wl_container_of(listener, s, buffer_destroy);
    s->buffer = NULL;
    wl_list_remove(&s->buffer_destroy.link);
    wl_list_init(&s->buffer_destroy.link);
}

static void surface_position_in_root(struct surface *s, int32_t *x, int32_t *y, struct surface **root) {
    *x = *y = 0;
    while (s->role == ROLE_SUBSURFACE && s->subsurface && s->subsurface->parent) {
        *x += s->subsurface->x;
        *y += s->subsurface->y;
        s = s->subsurface->parent;
    }
    *root = s;
}

struct view *surface_view(struct surface *s, int32_t *x, int32_t *y) {
    struct surface *root;
    surface_position_in_root(s, x, y, &root);
    if (root->role != ROLE_XDG || !root->xdg || !root->xdg->view)
        return NULL;
    struct xdg_surface *xdg = root->xdg;
    if (xdg->has_geometry) {
        *x -= xdg->geometry.x;
        *y -= xdg->geometry.y;
    }
    return xdg->view;
}

/* Buffer damage in surface coordinates, rounded outwards. */
static struct box buffer_to_surface(struct box b, int32_t scale) {
    if (box_empty(b) || scale <= 1) return b;
    int32_t x0 = b.x / scale, y0 = b.y / scale;
    int32_t x1 = (b.x + b.w + scale - 1) / scale, y1 = (b.y + b.h + scale - 1) / scale;
    return (struct box) {x0, y0, x1 - x0, y1 - y0};
}

/* GTK picks its buffer scale from the outputs a surface is on, so every displayed
 * surface is told it is on every output (there is only one). */
static void surface_enter_outputs(struct surface *s) {
    if (s->entered_output) return;
    s->entered_output = true;
    struct wl_resource *output;
    wl_resource_for_each(output, &s->server->output_resources)
        if (wl_resource_get_client(output) == wl_resource_get_client(s->resource))
            wl_surface_send_enter(s->resource, output);
}

static void surface_apply(struct surface *s, struct surface_state *st) {
    bool resized = false;
    bool rescaled = st->has_scale && st->scale != s->scale;
    if (rescaled)
        s->scale = st->scale;
    if (st->has_viewport && memcmp(&st->viewport, &s->viewport, sizeof(s->viewport)) != 0) {
        s->viewport = st->viewport;
        rescaled = true;
    }
    if (st->has_input) {
        region_free(s->input);
        s->input = st->input;
    }
    if (st->has_buffer) {
        if (s->buffer != st->buffer) {
            if (s->buffer)
                wl_buffer_send_release(s->buffer);
            wl_list_remove(&s->buffer_destroy.link);
            wl_list_init(&s->buffer_destroy.link);
            s->buffer = st->buffer;
            if (s->buffer)
                wl_resource_add_destroy_listener(s->buffer, &s->buffer_destroy);
        }
    }
    if (st->has_buffer || rescaled) {
        int32_t w = 0, h = 0;
        struct shm_buffer *b = s->buffer ? shm_buffer_from_resource(s->buffer) : NULL;
        if (b) {
            w = b->width / s->scale;
            h = b->height / s->scale;
            if (s->viewport.dst_w > 0) {
                w = s->viewport.dst_w;
                h = s->viewport.dst_h;
            } else if (s->viewport.src_w > 0) {
                w = (int32_t) s->viewport.src_w;
                h = (int32_t) s->viewport.src_h;
            }
        }
        resized = rescaled || w != s->width || h != s->height;
        s->width = w;
        s->height = h;
    }
    wl_list_insert_list(s->frame_callbacks.prev, &st->frame_callbacks);
    wl_list_init(&st->frame_callbacks);

    int32_t vx, vy;
    struct view *v = surface_view(s, &vx, &vy);
    if (v) {
        surface_enter_outputs(s);
        struct box damage = FULL_DAMAGE;
        if (!resized && !(st->has_buffer && !st->buffer)) {
            damage = box_union(st->damage, buffer_to_surface(st->buffer_damage, s->scale));
            damage = box_intersect(damage, (struct box) {0, 0, s->width, s->height});
            damage.x += vx;
            damage.y += vy;
        }
        view_damage(v, damage);
    }
    wl_list_remove(&st->buffer_destroy.link);
    state_init(st);
}

static bool surface_is_synchronized(struct surface *s) {
    while (s->role == ROLE_SUBSURFACE && s->subsurface) {
        if (s->subsurface->synchronized)
            return true;
        if (!s->subsurface->parent)
            return false;
        s = s->subsurface->parent;
    }
    return false;
}

static void surface_role_committed(struct surface *s);

/* A parent commit is what makes synchronized children's cached state current. */
static void surface_apply_children(struct surface *s) {
    struct subsurface *sub;
    wl_list_for_each(sub, &s->children, link) {
        if (sub->x != sub->pending_x || sub->y != sub->pending_y) {
            sub->x = sub->pending_x;
            sub->y = sub->pending_y;
            int32_t vx, vy;
            struct view *v = surface_view(s, &vx, &vy);
            if (v)
                view_damage(v, FULL_DAMAGE);
        }
        if (sub->surface->has_cached && surface_is_synchronized(sub->surface)) {
            surface_apply(sub->surface, &sub->surface->cached);
            sub->surface->has_cached = false;
            surface_apply_children(sub->surface);
        }
    }
}

static void surface_role_committed(struct surface *s) {
    if (s->role == ROLE_XDG && s->xdg) {
        xdg_surface_committed(s->xdg);
        return;
    }
    int32_t vx, vy;
    struct view *v = surface_view(s, &vx, &vy);
    if (v) {
        if (!wl_list_empty(&s->frame_callbacks))
            view_schedule(v);
    } else {
        /* Cursors and unmapped subsurface trees are never displayed; answer their
         * frame callbacks on the next tick so animations neither stall nor spin. */
        wl_list_insert_list(s->server->orphan_callbacks.prev, &s->frame_callbacks);
        wl_list_init(&s->frame_callbacks);
    }
}

static void surface_handle_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void surface_handle_attach(struct wl_client *client, struct wl_resource *resource,
                                  struct wl_resource *buffer, int32_t x, int32_t y) {
    struct surface *s = surface_from_resource(resource);
    state_set_buffer(&s->pending, buffer);
    if (wl_resource_get_version(resource) < WL_SURFACE_OFFSET_SINCE_VERSION) {
        s->pending.dx = x;
        s->pending.dy = y;
    }
}

static void surface_handle_damage(struct wl_client *client, struct wl_resource *resource,
                                  int32_t x, int32_t y, int32_t w, int32_t h) {
    struct surface *s = surface_from_resource(resource);
    s->pending.damage = box_union(s->pending.damage, clamp_damage(x, y, w, h));
}

static void surface_handle_frame(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct surface *s = surface_from_resource(resource);
    struct wl_resource *cb = wl_resource_create(client, &wl_callback_interface, 1, id);
    if (!cb) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(cb, NULL, NULL, callback_resource_destroy);
    wl_list_insert(s->pending.frame_callbacks.prev, wl_resource_get_link(cb));
}

static void surface_handle_set_opaque_region(struct wl_client *client, struct wl_resource *resource,
                                             struct wl_resource *region) {
}

/* Firefox gives its content subsurface an empty input region so that pointer
 * events reach the GTK surface below it; GTK ignores events on surfaces it did
 * not create. */
static void surface_handle_set_input_region(struct wl_client *client, struct wl_resource *resource,
                                            struct wl_resource *region) {
    struct surface *s = surface_from_resource(resource);
    struct region *input = NULL;
    if (region && !(input = region_copy(wl_resource_get_user_data(region)))) {
        wl_client_post_no_memory(client);
        return;
    }
    region_free(s->pending.input);
    s->pending.input = input;
    s->pending.has_input = true;
}

static void surface_handle_commit(struct wl_client *client, struct wl_resource *resource) {
    struct surface *s = surface_from_resource(resource);
    if (s->role == ROLE_SUBSURFACE && surface_is_synchronized(s)) {
        state_merge(&s->cached, &s->pending);
        s->has_cached = true;
        return;
    }
    if (s->has_cached) {
        state_merge(&s->cached, &s->pending);
        surface_apply(s, &s->cached);
        s->has_cached = false;
    } else {
        surface_apply(s, &s->pending);
    }
    surface_apply_children(s);
    surface_role_committed(s);
}

static void surface_handle_set_buffer_transform(struct wl_client *client, struct wl_resource *resource,
                                                int32_t transform) {
}

static void surface_handle_set_buffer_scale(struct wl_client *client, struct wl_resource *resource,
                                            int32_t scale) {
    if (scale < 1) {
        wl_resource_post_error(resource, WL_SURFACE_ERROR_INVALID_SCALE, "scale %d", scale);
        return;
    }
    struct surface *s = surface_from_resource(resource);
    s->pending.scale = scale;
    s->pending.has_scale = true;
}

static void surface_handle_damage_buffer(struct wl_client *client, struct wl_resource *resource,
                                         int32_t x, int32_t y, int32_t w, int32_t h) {
    struct surface *s = surface_from_resource(resource);
    s->pending.buffer_damage = box_union(s->pending.buffer_damage, clamp_damage(x, y, w, h));
}

static void surface_handle_offset(struct wl_client *client, struct wl_resource *resource,
                                  int32_t x, int32_t y) {
    struct surface *s = surface_from_resource(resource);
    s->pending.dx = x;
    s->pending.dy = y;
}

static const struct wl_surface_interface surface_impl = {
    .destroy = surface_handle_destroy,
    .attach = surface_handle_attach,
    .damage = surface_handle_damage,
    .frame = surface_handle_frame,
    .set_opaque_region = surface_handle_set_opaque_region,
    .set_input_region = surface_handle_set_input_region,
    .commit = surface_handle_commit,
    .set_buffer_transform = surface_handle_set_buffer_transform,
    .set_buffer_scale = surface_handle_set_buffer_scale,
    .damage_buffer = surface_handle_damage_buffer,
    .offset = surface_handle_offset,
};

struct surface *surface_from_resource(struct wl_resource *resource) {
    return wl_resource_get_user_data(resource);
}

static void surface_resource_destroy(struct wl_resource *resource) {
    struct surface *s = surface_from_resource(resource);
    wl_signal_emit(&s->destroy_signal, s);
    if (s->viewport_resource)
        wl_resource_set_user_data(s->viewport_resource, NULL);

    int32_t vx, vy;
    struct view *v = surface_view(s, &vx, &vy);
    if (v && s->role == ROLE_SUBSURFACE)
        view_damage(v, FULL_DAMAGE);

    struct subsurface *sub, *tmp;
    wl_list_for_each_safe(sub, tmp, &s->children, link) {
        wl_list_remove(&sub->link);
        wl_list_init(&sub->link);
        sub->parent = NULL;
    }
    if (s->subsurface) {
        wl_list_remove(&s->subsurface->link);
        wl_list_init(&s->subsurface->link);
        s->subsurface->surface = NULL;
    }
    state_finish(&s->pending);
    state_finish(&s->cached);
    region_free(s->input);
    struct wl_resource *cb, *cbtmp;
    wl_resource_for_each_safe(cb, cbtmp, &s->frame_callbacks)
        wl_resource_destroy(cb);
    wl_list_remove(&s->buffer_destroy.link);
    free(s);
}

static void compositor_create_surface(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct server *server = wl_resource_get_user_data(resource);
    struct surface *s = calloc(1, sizeof(*s));
    if (!s) {
        wl_client_post_no_memory(client);
        return;
    }
    s->resource = wl_resource_create(client, &wl_surface_interface, wl_resource_get_version(resource), id);
    if (!s->resource) {
        free(s);
        wl_client_post_no_memory(client);
        return;
    }
    s->server = server;
    s->scale = 1;
    s->viewport = (struct viewport_state) {-1, -1, -1, -1, -1, -1};
    state_init(&s->pending);
    state_init(&s->cached);
    wl_list_init(&s->frame_callbacks);
    wl_list_init(&s->children);
    wl_list_init(&s->buffer_destroy.link);
    s->buffer_destroy.notify = surface_buffer_destroyed;
    wl_signal_init(&s->destroy_signal);
    wl_resource_set_implementation(s->resource, &surface_impl, s, surface_resource_destroy);
}

/* Regions are kept for input; opaque regions are only a hint and are ignored. */
static void region_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void region_resource_destroy(struct wl_resource *resource) {
    region_free(wl_resource_get_user_data(resource));
}

static void region_push(struct wl_resource *resource, bool add, int32_t x, int32_t y, int32_t w, int32_t h) {
    struct region *r = wl_resource_get_user_data(resource);
    if (w <= 0 || h <= 0) return;
    if (r->count == r->capacity) {
        int capacity = r->capacity ? r->capacity * 2 : 4;
        struct region_op *ops = realloc(r->ops, sizeof(*ops) * (size_t) capacity);
        if (!ops) {
            wl_resource_post_no_memory(resource);
            return;
        }
        r->ops = ops;
        r->capacity = capacity;
    }
    r->ops[r->count++] = (struct region_op) {add, {x, y, w, h}};
}

static void region_add(struct wl_client *client, struct wl_resource *resource,
                       int32_t x, int32_t y, int32_t w, int32_t h) {
    region_push(resource, true, x, y, w, h);
}

static void region_subtract(struct wl_client *client, struct wl_resource *resource,
                            int32_t x, int32_t y, int32_t w, int32_t h) {
    region_push(resource, false, x, y, w, h);
}

static const struct wl_region_interface region_impl = {
    .destroy = region_destroy,
    .add = region_add,
    .subtract = region_subtract,
};

static void compositor_create_region(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct wl_resource *region = wl_resource_create(client, &wl_region_interface, 1, id);
    if (!region) {
        wl_client_post_no_memory(client);
        return;
    }
    struct region *r = calloc(1, sizeof(*r));
    if (!r) {
        wl_resource_destroy(region);
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(region, &region_impl, r, region_resource_destroy);
}

static const struct wl_compositor_interface compositor_impl = {
    .create_surface = compositor_create_surface,
    .create_region = compositor_create_region,
};

static void compositor_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &wl_compositor_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &compositor_impl, data, NULL);
}

/* ---- subsurfaces ---- */

static void subsurface_handle_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void subsurface_set_position(struct wl_client *client, struct wl_resource *resource, int32_t x, int32_t y) {
    struct subsurface *sub = wl_resource_get_user_data(resource);
    if (!sub) return;
    sub->pending_x = x;
    sub->pending_y = y;
}

static void subsurface_restack(struct wl_resource *resource, struct wl_resource *sibling_resource, bool above) {
    struct subsurface *sub = wl_resource_get_user_data(resource);
    if (!sub || !sub->parent) return;
    struct surface *sibling = surface_from_resource(sibling_resource);
    if (sibling == sub->parent) {
        sub->below_parent = !above;
        return;
    }
    if (sibling->role != ROLE_SUBSURFACE || !sibling->subsurface || sibling->subsurface->parent != sub->parent)
        return;
    wl_list_remove(&sub->link);
    if (above)
        wl_list_insert(&sibling->subsurface->link, &sub->link);
    else
        wl_list_insert(sibling->subsurface->link.prev, &sub->link);
    sub->below_parent = sibling->subsurface->below_parent;
}

static void subsurface_place_above(struct wl_client *client, struct wl_resource *resource, struct wl_resource *sibling) {
    subsurface_restack(resource, sibling, true);
}

static void subsurface_place_below(struct wl_client *client, struct wl_resource *resource, struct wl_resource *sibling) {
    subsurface_restack(resource, sibling, false);
}

static void subsurface_set_sync(struct wl_client *client, struct wl_resource *resource) {
    struct subsurface *sub = wl_resource_get_user_data(resource);
    if (sub) sub->synchronized = true;
}

static void subsurface_set_desync(struct wl_client *client, struct wl_resource *resource) {
    struct subsurface *sub = wl_resource_get_user_data(resource);
    if (!sub) return;
    sub->synchronized = false;
    if (sub->surface && sub->surface->has_cached && !surface_is_synchronized(sub->surface)) {
        surface_apply(sub->surface, &sub->surface->cached);
        sub->surface->has_cached = false;
        surface_apply_children(sub->surface);
        surface_role_committed(sub->surface);
    }
}

static const struct wl_subsurface_interface subsurface_impl = {
    .destroy = subsurface_handle_destroy,
    .set_position = subsurface_set_position,
    .place_above = subsurface_place_above,
    .place_below = subsurface_place_below,
    .set_sync = subsurface_set_sync,
    .set_desync = subsurface_set_desync,
};

static void subsurface_resource_destroy(struct wl_resource *resource) {
    struct subsurface *sub = wl_resource_get_user_data(resource);
    if (!sub) return;
    if (sub->surface) {
        int32_t vx, vy;
        struct view *v = surface_view(sub->surface, &vx, &vy);
        if (v)
            view_damage(v, FULL_DAMAGE);
        sub->surface->subsurface = NULL;
        sub->surface->role = ROLE_NONE;
    }
    wl_list_remove(&sub->link);
    free(sub);
}

static void subcompositor_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void subcompositor_get_subsurface(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                                         struct wl_resource *surface_resource, struct wl_resource *parent_resource) {
    struct surface *surface = surface_from_resource(surface_resource);
    struct surface *parent = surface_from_resource(parent_resource);
    if (surface->role != ROLE_NONE && surface->role != ROLE_SUBSURFACE) {
        wl_resource_post_error(resource, WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE, "surface already has a role");
        return;
    }
    struct subsurface *sub = calloc(1, sizeof(*sub));
    if (!sub) {
        wl_client_post_no_memory(client);
        return;
    }
    sub->resource = wl_resource_create(client, &wl_subsurface_interface, 1, id);
    if (!sub->resource) {
        free(sub);
        wl_client_post_no_memory(client);
        return;
    }
    sub->surface = surface;
    sub->parent = parent;
    sub->synchronized = true;
    surface->role = ROLE_SUBSURFACE;
    surface->subsurface = sub;
    wl_list_insert(parent->children.prev, &sub->link);
    wl_resource_set_implementation(sub->resource, &subsurface_impl, sub, subsurface_resource_destroy);
}

static const struct wl_subcompositor_interface subcompositor_impl = {
    .destroy = subcompositor_destroy,
    .get_subsurface = subcompositor_get_subsurface,
};

static void subcompositor_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &wl_subcompositor_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &subcompositor_impl, data, NULL);
}

/* ---- tree walks ---- */

void surface_for_each(struct surface *s, int32_t x, int32_t y,
                      void (*fn)(struct surface *, int32_t, int32_t, void *), void *data) {
    struct subsurface *sub;
    wl_list_for_each(sub, &s->children, link)
        if (sub->below_parent && sub->surface)
            surface_for_each(sub->surface, x + sub->x, y + sub->y, fn, data);
    fn(s, x, y, data);
    wl_list_for_each(sub, &s->children, link)
        if (!sub->below_parent && sub->surface)
            surface_for_each(sub->surface, x + sub->x, y + sub->y, fn, data);
}

struct surface *surface_at(struct surface *s, double x, double y, double *sx, double *sy) {
    struct subsurface *sub;
    wl_list_for_each_reverse(sub, &s->children, link) {
        if (sub->below_parent || !sub->surface) continue;
        struct surface *hit = surface_at(sub->surface, x - sub->x, y - sub->y, sx, sy);
        if (hit) return hit;
    }
    if (s->buffer && x >= 0 && y >= 0 && x < s->width && y < s->height && region_contains(s->input, x, y)) {
        *sx = x;
        *sy = y;
        return s;
    }
    wl_list_for_each_reverse(sub, &s->children, link) {
        if (!sub->below_parent || !sub->surface) continue;
        struct surface *hit = surface_at(sub->surface, x - sub->x, y - sub->y, sx, sy);
        if (hit) return hit;
    }
    return NULL;
}

/* ---- wp_viewporter ---- */

static void viewport_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

/* Changes go to the pending state; the base state is copied in first so a request
 * that sets only the source keeps the destination and vice versa. */
static struct viewport_state *viewport_pending(struct surface *s) {
    if (!s->pending.has_viewport) {
        s->pending.viewport = s->viewport;
        s->pending.has_viewport = true;
    }
    return &s->pending.viewport;
}

static void viewport_set_source(struct wl_client *client, struct wl_resource *resource,
                                wl_fixed_t x, wl_fixed_t y, wl_fixed_t w, wl_fixed_t h) {
    struct surface *s = wl_resource_get_user_data(resource);
    if (!s) return;
    struct viewport_state *vp = viewport_pending(s);
    bool unset = x == wl_fixed_from_int(-1) && y == wl_fixed_from_int(-1) &&
                 w == wl_fixed_from_int(-1) && h == wl_fixed_from_int(-1);
    vp->src_x = unset ? -1 : wl_fixed_to_double(x);
    vp->src_y = unset ? -1 : wl_fixed_to_double(y);
    vp->src_w = unset ? -1 : wl_fixed_to_double(w);
    vp->src_h = unset ? -1 : wl_fixed_to_double(h);
}

static void viewport_set_destination(struct wl_client *client, struct wl_resource *resource, int32_t w, int32_t h) {
    struct surface *s = wl_resource_get_user_data(resource);
    if (!s) return;
    struct viewport_state *vp = viewport_pending(s);
    vp->dst_w = w > 0 ? w : -1;
    vp->dst_h = h > 0 ? h : -1;
}

static const struct wp_viewport_interface viewport_impl = {
    .destroy = viewport_destroy,
    .set_source = viewport_set_source,
    .set_destination = viewport_set_destination,
};

static void viewport_resource_destroy(struct wl_resource *resource) {
    struct surface *s = wl_resource_get_user_data(resource);
    if (!s) return;
    s->viewport_resource = NULL;
    struct viewport_state *vp = viewport_pending(s);
    *vp = (struct viewport_state) {-1, -1, -1, -1, -1, -1};
}

static void viewporter_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void viewporter_get_viewport(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                                    struct wl_resource *surface_resource) {
    struct surface *s = surface_from_resource(surface_resource);
    if (s->viewport_resource) {
        wl_resource_post_error(resource, WP_VIEWPORTER_ERROR_VIEWPORT_EXISTS, "surface already has a viewport");
        return;
    }
    struct wl_resource *vp = wl_resource_create(client, &wp_viewport_interface, 1, id);
    if (!vp) {
        wl_client_post_no_memory(client);
        return;
    }
    s->viewport_resource = vp;
    wl_resource_set_implementation(vp, &viewport_impl, s, viewport_resource_destroy);
}

static const struct wp_viewporter_interface viewporter_impl = {
    .destroy = viewporter_destroy,
    .get_viewport = viewporter_get_viewport,
};

static void viewporter_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &wp_viewporter_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &viewporter_impl, data, NULL);
}

void compositor_init(struct server *s) {
    wl_global_create(s->display, &wl_compositor_interface, 5, s, compositor_bind);
    wl_global_create(s->display, &wl_subcompositor_interface, 1, s, subcompositor_bind);
    wl_global_create(s->display, &wp_viewporter_interface, 1, s, viewporter_bind);
}
