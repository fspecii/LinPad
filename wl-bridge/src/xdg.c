#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ishwl.h"
#include "xdg-shell-protocol.h"

/* ---- positioner ---- */

static void positioner_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void positioner_set_size(struct wl_client *client, struct wl_resource *resource, int32_t w, int32_t h) {
    struct positioner *p = wl_resource_get_user_data(resource);
    p->width = w;
    p->height = h;
}

static void positioner_set_anchor_rect(struct wl_client *client, struct wl_resource *resource,
                                       int32_t x, int32_t y, int32_t w, int32_t h) {
    struct positioner *p = wl_resource_get_user_data(resource);
    p->anchor_rect = (struct box) {x, y, w, h};
}

static void positioner_set_anchor(struct wl_client *client, struct wl_resource *resource, uint32_t anchor) {
    struct positioner *p = wl_resource_get_user_data(resource);
    p->anchor = anchor;
}

static void positioner_set_gravity(struct wl_client *client, struct wl_resource *resource, uint32_t gravity) {
    struct positioner *p = wl_resource_get_user_data(resource);
    p->gravity = gravity;
}

static void positioner_set_constraint_adjustment(struct wl_client *client, struct wl_resource *resource,
                                                 uint32_t adjustment) {
    struct positioner *p = wl_resource_get_user_data(resource);
    p->constraint = adjustment;
}

static void positioner_set_offset(struct wl_client *client, struct wl_resource *resource, int32_t x, int32_t y) {
    struct positioner *p = wl_resource_get_user_data(resource);
    p->offset_x = x;
    p->offset_y = y;
}

static void positioner_noop(struct wl_client *client, struct wl_resource *resource) {
}

static void positioner_set_parent_size(struct wl_client *client, struct wl_resource *resource, int32_t w, int32_t h) {
}

static void positioner_set_parent_configure(struct wl_client *client, struct wl_resource *resource, uint32_t serial) {
}

static const struct xdg_positioner_interface positioner_impl = {
    .destroy = positioner_destroy,
    .set_size = positioner_set_size,
    .set_anchor_rect = positioner_set_anchor_rect,
    .set_anchor = positioner_set_anchor,
    .set_gravity = positioner_set_gravity,
    .set_constraint_adjustment = positioner_set_constraint_adjustment,
    .set_offset = positioner_set_offset,
    .set_reactive = positioner_noop,
    .set_parent_size = positioner_set_parent_size,
    .set_parent_configure = positioner_set_parent_configure,
};

static void positioner_resource_destroy(struct wl_resource *resource) {
    free(wl_resource_get_user_data(resource));
}

static bool edge_has(uint32_t edge, uint32_t a, uint32_t b, uint32_t c) {
    return edge == a || edge == b || edge == c;
}

/* The unconstrained placement from xdg_positioner's anchor/gravity rules. The
 * compositor does not know where the host put the parent window on screen, so
 * flip/slide adjustments are left to the host side. */
static void positioner_place(const struct positioner *p, int32_t *x, int32_t *y) {
    const struct box r = p->anchor_rect;
    int32_t ax = r.x + r.w / 2, ay = r.y + r.h / 2;
    if (edge_has(p->anchor, XDG_POSITIONER_ANCHOR_LEFT, XDG_POSITIONER_ANCHOR_TOP_LEFT, XDG_POSITIONER_ANCHOR_BOTTOM_LEFT))
        ax = r.x;
    else if (edge_has(p->anchor, XDG_POSITIONER_ANCHOR_RIGHT, XDG_POSITIONER_ANCHOR_TOP_RIGHT, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT))
        ax = r.x + r.w;
    if (edge_has(p->anchor, XDG_POSITIONER_ANCHOR_TOP, XDG_POSITIONER_ANCHOR_TOP_LEFT, XDG_POSITIONER_ANCHOR_TOP_RIGHT))
        ay = r.y;
    else if (edge_has(p->anchor, XDG_POSITIONER_ANCHOR_BOTTOM, XDG_POSITIONER_ANCHOR_BOTTOM_LEFT, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT))
        ay = r.y + r.h;

    int32_t px = ax - p->width / 2, py = ay - p->height / 2;
    if (edge_has(p->gravity, XDG_POSITIONER_GRAVITY_LEFT, XDG_POSITIONER_GRAVITY_TOP_LEFT, XDG_POSITIONER_GRAVITY_BOTTOM_LEFT))
        px = ax - p->width;
    else if (edge_has(p->gravity, XDG_POSITIONER_GRAVITY_RIGHT, XDG_POSITIONER_GRAVITY_TOP_RIGHT, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT))
        px = ax;
    if (edge_has(p->gravity, XDG_POSITIONER_GRAVITY_TOP, XDG_POSITIONER_GRAVITY_TOP_LEFT, XDG_POSITIONER_GRAVITY_TOP_RIGHT))
        py = ay - p->height;
    else if (edge_has(p->gravity, XDG_POSITIONER_GRAVITY_BOTTOM, XDG_POSITIONER_GRAVITY_BOTTOM_LEFT, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT))
        py = ay;
    *x = px + p->offset_x;
    *y = py + p->offset_y;
}

/* ---- views ---- */

struct view *view_by_id(struct server *s, uint32_t id) {
    struct view *v;
    wl_list_for_each(v, &s->views, link)
        if (v->id == id) return v;
    return NULL;
}

struct view *view_toplevel(struct view *v) {
    while (v && v->kind == VIEW_POPUP && v->parent)
        v = v->parent;
    return v;
}

static bool view_is_ancestor(struct view *ancestor, struct view *v) {
    for (; v; v = v->parent)
        if (v == ancestor) return true;
    return false;
}

void view_dismiss_popups(struct server *s, struct view *keep) {
    struct view *v;
    wl_list_for_each_reverse(v, &s->views, link) {
        if (v->kind != VIEW_POPUP || !v->role_resource) continue;
        if (v->dismissed || (keep && view_is_ancestor(v, keep))) continue;
        v->dismissed = true;
        xdg_popup_send_popup_done(v->role_resource);
    }
}

static struct view *view_create(struct xdg_surface *xdg, enum view_kind kind, struct wl_resource *role) {
    struct server *s = xdg->surface->server;
    struct view *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->server = s;
    v->id = s->next_view_id++;
    v->kind = kind;
    v->xdg = xdg;
    v->role_resource = role;
    v->out.fd = -1;
    wl_list_init(&v->presented_callbacks);
    xdg->view = v;
    wl_list_insert(s->views.prev, &v->link);
    return v;
}

void view_configure(struct view *v) {
    struct xdg_surface *xdg = v->xdg;
    if (!xdg || !v->role_resource) return;
    if (v->kind == VIEW_TOPLEVEL) {
        struct wl_array states;
        wl_array_init(&states);
        uint32_t *state;
        if (v->activated && (state = wl_array_add(&states, sizeof(*state))))
            *state = XDG_TOPLEVEL_STATE_ACTIVATED;
        if (v->maximized && (state = wl_array_add(&states, sizeof(*state))))
            *state = XDG_TOPLEVEL_STATE_MAXIMIZED;
        if (v->fullscreen && (state = wl_array_add(&states, sizeof(*state))))
            *state = XDG_TOPLEVEL_STATE_FULLSCREEN;
        xdg_toplevel_send_configure(v->role_resource, v->host_width, v->host_height, &states);
        wl_array_release(&states);
    } else {
        xdg_popup_send_configure(v->role_resource, v->popup_x, v->popup_y,
                                 v->positioner.width, v->positioner.height);
    }
    xdg->configure_serial = wl_display_next_serial(v->server->display);
    xdg_surface_send_configure(xdg->resource, xdg->configure_serial);
    xdg->configured = true;
}

void view_send_close(struct view *v) {
    if (v->kind == VIEW_TOPLEVEL && v->role_resource)
        xdg_toplevel_send_close(v->role_resource);
    else if (v->kind == VIEW_POPUP && v->role_resource && !v->dismissed) {
        v->dismissed = true;
        xdg_popup_send_popup_done(v->role_resource);
    }
}

void xdg_surface_committed(struct xdg_surface *xdg) {
    struct view *v = xdg->view;
    if (!v) return;
    if (!xdg->configured) {
        view_configure(v);
        return;
    }
    if (xdg->pending_has_geometry) {
        struct box g = xdg->pending_geometry;
        if (!xdg->has_geometry || memcmp(&g, &xdg->geometry, sizeof(g)) != 0) {
            xdg->geometry = g;
            xdg->has_geometry = true;
            view_damage(v, FULL_DAMAGE);
        }
    }
    struct surface *surface = xdg->surface;
    if (!xdg->has_geometry || xdg->geometry.w <= 0 || xdg->geometry.h <= 0) {
        struct box g = {0, 0, surface->width, surface->height};
        if (memcmp(&g, &xdg->geometry, sizeof(g)) != 0) {
            xdg->geometry = g;
            view_damage(v, FULL_DAMAGE);
        }
    }

    if (surface->buffer && !v->mapped) {
        v->mapped = true;
        view_damage(v, FULL_DAMAGE);
        view_announce(v);
    } else if (!surface->buffer && v->mapped) {
        view_unmap(v);
        xdg->configured = false;
        return;
    }
    view_schedule(v);
}

/* ---- toplevel ---- */

static void toplevel_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void toplevel_set_parent(struct wl_client *client, struct wl_resource *resource, struct wl_resource *parent) {
    struct view *v = wl_resource_get_user_data(resource);
    if (!v) return;
    v->parent = parent ? wl_resource_get_user_data(parent) : NULL;
}

/* A rootful Xwayland names its window "Xwayland on :N"; ishwl-x11 records which
 * app it runs (ISHWL_X11_APPS/<Xwayland pid>), so the host can show that app's
 * name and icon instead. */
static char *x11_app_name(struct wl_client *client) {
    pid_t pid;
    wl_client_get_credentials(client, &pid, NULL, NULL);
    char path[64], name[128] = "";
    snprintf(path, sizeof(path), ISHWL_X11_APPS "/%d", (int) pid);
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    char *line = fgets(name, sizeof(name), f);
    fclose(f);
    if (!line) return NULL;
    name[strcspn(name, "\n")] = '\0';
    return name[0] ? strdup(name) : NULL;
}

static void toplevel_set_title(struct wl_client *client, struct wl_resource *resource, const char *title) {
    struct view *v = wl_resource_get_user_data(resource);
    if (!v || v->x11_app) return;
    free(v->title);
    v->title = strdup(title);
    view_notify_title(v);
}

static void toplevel_set_app_id(struct wl_client *client, struct wl_resource *resource, const char *app_id) {
    struct view *v = wl_resource_get_user_data(resource);
    if (!v) return;
    char *x11_app = strcmp(app_id, "org.freedesktop.Xwayland") == 0 ? x11_app_name(client) : NULL;
    free(v->app_id);
    v->app_id = x11_app ? x11_app : strdup(app_id);
    if (x11_app) {
        v->x11_app = true;
        free(v->title);
        v->title = strdup("");
    }
    view_notify_title(v);
}

static void toplevel_show_window_menu(struct wl_client *client, struct wl_resource *resource,
                                      struct wl_resource *seat, uint32_t serial, int32_t x, int32_t y) {
}

static void toplevel_move(struct wl_client *client, struct wl_resource *resource,
                          struct wl_resource *seat, uint32_t serial) {
}

static void toplevel_resize(struct wl_client *client, struct wl_resource *resource,
                            struct wl_resource *seat, uint32_t serial, uint32_t edges) {
}

static void toplevel_set_max_size(struct wl_client *client, struct wl_resource *resource, int32_t w, int32_t h) {
    struct view *v = wl_resource_get_user_data(resource);
    if (!v) return;
    v->max_w = w;
    v->max_h = h;
}

static void toplevel_set_min_size(struct wl_client *client, struct wl_resource *resource, int32_t w, int32_t h) {
    struct view *v = wl_resource_get_user_data(resource);
    if (!v) return;
    v->min_w = w;
    v->min_h = h;
}

static void toplevel_set_maximized(struct wl_client *client, struct wl_resource *resource) {
    struct view *v = wl_resource_get_user_data(resource);
    if (v) bridge_send(v->server, "state %u maximize\n", v->id);
}

static void toplevel_unset_maximized(struct wl_client *client, struct wl_resource *resource) {
    struct view *v = wl_resource_get_user_data(resource);
    if (v) bridge_send(v->server, "state %u unmaximize\n", v->id);
}

static void toplevel_set_fullscreen(struct wl_client *client, struct wl_resource *resource, struct wl_resource *output) {
    struct view *v = wl_resource_get_user_data(resource);
    toplevel_set_maximized(client, resource);
    if (v && !v->fullscreen) {
        v->fullscreen = true;
        output_client_fullscreen(v->server, client, true);
        /* Clients finish entering fullscreen (Firefox resolves requestFullscreen) on a
         * configure with the fullscreen state; the host's maximize configure follows. */
        view_configure(v);
    }
}

static void toplevel_unset_fullscreen(struct wl_client *client, struct wl_resource *resource) {
    struct view *v = wl_resource_get_user_data(resource);
    toplevel_unset_maximized(client, resource);
    if (v && v->fullscreen) {
        v->fullscreen = false;
        output_client_fullscreen(v->server, client, false);
        view_configure(v);
    }
}

static void toplevel_set_minimized(struct wl_client *client, struct wl_resource *resource) {
    struct view *v = wl_resource_get_user_data(resource);
    if (v) bridge_send(v->server, "state %u minimize\n", v->id);
}

static const struct xdg_toplevel_interface toplevel_impl = {
    .destroy = toplevel_destroy,
    .set_parent = toplevel_set_parent,
    .set_title = toplevel_set_title,
    .set_app_id = toplevel_set_app_id,
    .show_window_menu = toplevel_show_window_menu,
    .move = toplevel_move,
    .resize = toplevel_resize,
    .set_max_size = toplevel_set_max_size,
    .set_min_size = toplevel_set_min_size,
    .set_maximized = toplevel_set_maximized,
    .unset_maximized = toplevel_unset_maximized,
    .set_fullscreen = toplevel_set_fullscreen,
    .unset_fullscreen = toplevel_unset_fullscreen,
    .set_minimized = toplevel_set_minimized,
};

static void role_resource_destroy(struct wl_resource *resource) {
    struct view *v = wl_resource_get_user_data(resource);
    if (!v) return;
    struct server *s = v->server;
    struct view *other;
    wl_list_for_each(other, &s->views, link) {
        if (other->parent == v)
            other->parent = NULL;
    }
    if (v->xdg)
        v->xdg->view = NULL;
    view_destroy(v);
}

/* ---- popup ---- */

static void popup_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void popup_grab(struct wl_client *client, struct wl_resource *resource, struct wl_resource *seat, uint32_t serial) {
    struct view *v = wl_resource_get_user_data(resource);
    if (v) v->grabbing = true;
}

static void popup_reposition(struct wl_client *client, struct wl_resource *resource,
                             struct wl_resource *positioner, uint32_t token) {
    struct view *v = wl_resource_get_user_data(resource);
    if (!v) return;
    v->positioner = *(struct positioner *) wl_resource_get_user_data(positioner);
    positioner_place(&v->positioner, &v->popup_x, &v->popup_y);
    xdg_popup_send_repositioned(resource, token);
    view_configure(v);
    if (v->announced)
        bridge_send(v->server, "move %u %d %d\n", v->id, v->popup_x, v->popup_y);
}

static const struct xdg_popup_interface popup_impl = {
    .destroy = popup_destroy,
    .grab = popup_grab,
    .reposition = popup_reposition,
};

/* ---- xdg_surface ---- */

static void xdg_surface_handle_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void xdg_surface_get_toplevel(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct xdg_surface *xdg = wl_resource_get_user_data(resource);
    struct wl_resource *role = wl_resource_create(client, &xdg_toplevel_interface,
                                                  wl_resource_get_version(resource), id);
    if (!role) {
        wl_client_post_no_memory(client);
        return;
    }
    struct view *v = view_create(xdg, VIEW_TOPLEVEL, role);
    wl_resource_set_implementation(role, &toplevel_impl, v, role_resource_destroy);
}

static void xdg_surface_get_popup(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                                  struct wl_resource *parent, struct wl_resource *positioner) {
    struct xdg_surface *xdg = wl_resource_get_user_data(resource);
    struct wl_resource *role = wl_resource_create(client, &xdg_popup_interface,
                                                  wl_resource_get_version(resource), id);
    if (!role) {
        wl_client_post_no_memory(client);
        return;
    }
    struct view *v = view_create(xdg, VIEW_POPUP, role);
    if (parent) {
        struct xdg_surface *parent_xdg = wl_resource_get_user_data(parent);
        v->parent = parent_xdg ? parent_xdg->view : NULL;
    }
    v->positioner = *(struct positioner *) wl_resource_get_user_data(positioner);
    positioner_place(&v->positioner, &v->popup_x, &v->popup_y);
    wl_resource_set_implementation(role, &popup_impl, v, role_resource_destroy);
}

static void xdg_surface_set_window_geometry(struct wl_client *client, struct wl_resource *resource,
                                            int32_t x, int32_t y, int32_t w, int32_t h) {
    struct xdg_surface *xdg = wl_resource_get_user_data(resource);
    xdg->pending_geometry = (struct box) {x, y, w, h};
    xdg->pending_has_geometry = w > 0 && h > 0;
}

static void xdg_surface_ack_configure(struct wl_client *client, struct wl_resource *resource, uint32_t serial) {
    struct xdg_surface *xdg = wl_resource_get_user_data(resource);
    xdg->acked = true;
}

static const struct xdg_surface_interface xdg_surface_impl = {
    .destroy = xdg_surface_handle_destroy,
    .get_toplevel = xdg_surface_get_toplevel,
    .get_popup = xdg_surface_get_popup,
    .set_window_geometry = xdg_surface_set_window_geometry,
    .ack_configure = xdg_surface_ack_configure,
};

static void xdg_surface_resource_destroy(struct wl_resource *resource) {
    struct xdg_surface *xdg = wl_resource_get_user_data(resource);
    if (xdg->view) {
        xdg->view->xdg = NULL;
        view_unmap(xdg->view);
    }
    if (xdg->surface) {
        xdg->surface->xdg = NULL;
        wl_list_remove(&xdg->surface_destroy.link);
    }
    free(xdg);
}

static void xdg_surface_surface_destroyed(struct wl_listener *listener, void *data) {
    struct xdg_surface *xdg = wl_container_of(listener, xdg, surface_destroy);
    wl_list_remove(&xdg->surface_destroy.link);
    wl_list_init(&xdg->surface_destroy.link);
    if (xdg->view) {
        view_unmap(xdg->view);
        xdg->view->xdg = NULL;
        xdg->view = NULL;
    }
    xdg->surface = NULL;
}

static void wm_base_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void wm_base_create_positioner(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct positioner *p = calloc(1, sizeof(*p));
    struct wl_resource *r = p ? wl_resource_create(client, &xdg_positioner_interface,
                                                    wl_resource_get_version(resource), id) : NULL;
    if (!r) {
        free(p);
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(r, &positioner_impl, p, positioner_resource_destroy);
}

static void wm_base_get_xdg_surface(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                                    struct wl_resource *surface_resource) {
    struct surface *surface = surface_from_resource(surface_resource);
    if (surface->role != ROLE_NONE && surface->role != ROLE_XDG) {
        wl_resource_post_error(resource, XDG_WM_BASE_ERROR_ROLE, "surface already has a role");
        return;
    }
    struct xdg_surface *xdg = calloc(1, sizeof(*xdg));
    if (!xdg) {
        wl_client_post_no_memory(client);
        return;
    }
    xdg->resource = wl_resource_create(client, &xdg_surface_interface, wl_resource_get_version(resource), id);
    if (!xdg->resource) {
        free(xdg);
        wl_client_post_no_memory(client);
        return;
    }
    xdg->surface = surface;
    surface->role = ROLE_XDG;
    surface->xdg = xdg;
    xdg->surface_destroy.notify = xdg_surface_surface_destroyed;
    wl_signal_add(&surface->destroy_signal, &xdg->surface_destroy);
    wl_resource_set_implementation(xdg->resource, &xdg_surface_impl, xdg, xdg_surface_resource_destroy);
}

static void wm_base_pong(struct wl_client *client, struct wl_resource *resource, uint32_t serial) {
}

static const struct xdg_wm_base_interface wm_base_impl = {
    .destroy = wm_base_destroy,
    .create_positioner = wm_base_create_positioner,
    .get_xdg_surface = wm_base_get_xdg_surface,
    .pong = wm_base_pong,
};

static void wm_base_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &xdg_wm_base_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &wm_base_impl, data, NULL);
}

void xdg_init(struct server *s) {
    wl_global_create(s->display, &xdg_wm_base_interface, 3, s, wm_base_bind);
}
