/* Globals that need little more than a correct answer: the output and
 * server-side decoration negotiation. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "ishwl.h"
#include "server-decoration-protocol.h"
#include "xdg-decoration-unstable-v1-protocol.h"
#include "xdg-activation-v1-protocol.h"
#include "xdg-shell-protocol.h"

static void destroy_request(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

/* ---- wl_output ---- */

static const struct wl_output_interface output_impl = {
    .release = destroy_request,
};

static void output_resource_destroy(struct wl_resource *resource) {
    wl_list_remove(wl_resource_get_link(resource));
}

/* Per-app output scale: /etc/ishwl/app-scale lines "PROGRAM SCALE", PROGRAM being the
 * basename of the client's executable (e.g. "firefox-esr 1"). Heavy software-rendered
 * apps draw a quarter of the pixels at scale 1; the host scales the frame up. Read at
 * every bind, so a change applies to apps started afterwards. */
static int32_t client_output_scale(struct server *s, struct wl_client *client) {
    pid_t pid;
    wl_client_get_credentials(client, &pid, NULL, NULL);
    FILE *f = pid > 0 ? fopen("/etc/ishwl/app-scale", "r") : NULL;
    if (!f)
        return s->output_scale;
    char link[64], exe[256];
    snprintf(link, sizeof(link), "/proc/%d/exe", (int) pid);
    ssize_t n = readlink(link, exe, sizeof(exe) - 1);
    exe[n > 0 ? n : 0] = '\0';
    const char *base = strrchr(exe, '/') ? strrchr(exe, '/') + 1 : exe;
    char line[300], name[256];
    int scale, result = s->output_scale;
    while (n > 0 && fgets(line, sizeof(line), f))
        if (sscanf(line, "%255s %d", name, &scale) == 2 && name[0] != '#' && strcmp(name, base) == 0 &&
            scale >= 1 && scale <= 3)
            result = scale;
    fclose(f);
    return result;
}

static void output_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct server *s = data;
    int32_t scale = client_output_scale(s, client);
    struct wl_resource *resource = wl_resource_create(client, &wl_output_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &output_impl, s, output_resource_destroy);
    wl_list_insert(&s->output_resources, wl_resource_get_link(resource));
    wl_output_send_geometry(resource, 0, 0, 0, 0, WL_OUTPUT_SUBPIXEL_UNKNOWN, "iSH", "DesktopKit",
                            WL_OUTPUT_TRANSFORM_NORMAL);
    wl_output_send_mode(resource, WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
                        s->output_width * scale, s->output_height * scale, 60000);
    if (version >= WL_OUTPUT_SCALE_SINCE_VERSION)
        wl_output_send_scale(resource, scale);
    if (version >= WL_OUTPUT_NAME_SINCE_VERSION)
        wl_output_send_name(resource, "DESKTOP-1");
    if (version >= WL_OUTPUT_DONE_SINCE_VERSION)
        wl_output_send_done(resource);
}

/* ---- zxdg_decoration_manager_v1 ---- */

static void xdg_decoration_set_mode(struct wl_client *client, struct wl_resource *resource, uint32_t mode) {
    zxdg_toplevel_decoration_v1_send_configure(resource, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

static void xdg_decoration_unset_mode(struct wl_client *client, struct wl_resource *resource) {
    zxdg_toplevel_decoration_v1_send_configure(resource, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

static const struct zxdg_toplevel_decoration_v1_interface xdg_decoration_impl = {
    .destroy = destroy_request,
    .set_mode = xdg_decoration_set_mode,
    .unset_mode = xdg_decoration_unset_mode,
};

static void xdg_decoration_manager_get(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                                       struct wl_resource *toplevel) {
    struct wl_resource *deco = wl_resource_create(client, &zxdg_toplevel_decoration_v1_interface,
                                                  wl_resource_get_version(resource), id);
    if (!deco) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(deco, &xdg_decoration_impl, NULL, NULL);
    zxdg_toplevel_decoration_v1_send_configure(deco, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    struct view *v = wl_resource_get_user_data(toplevel);
    if (v && v->xdg && v->xdg->configured)
        view_configure(v);
}

static const struct zxdg_decoration_manager_v1_interface xdg_decoration_manager_impl = {
    .destroy = destroy_request,
    .get_toplevel_decoration = xdg_decoration_manager_get,
};

static void xdg_decoration_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &zxdg_decoration_manager_v1_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &xdg_decoration_manager_impl, data, NULL);
}

/* ---- org_kde_kwin_server_decoration_manager (what GTK actually checks) ---- */

/* GTK re-requests until the answer matches, so a client that insists on drawing
 * its own decorations (a GtkHeaderBar window) gets them. */
static void kde_decoration_request_mode(struct wl_client *client, struct wl_resource *resource, uint32_t mode) {
    org_kde_kwin_server_decoration_send_mode(resource, mode);
}

static const struct org_kde_kwin_server_decoration_interface kde_decoration_impl = {
    .release = destroy_request,
    .request_mode = kde_decoration_request_mode,
};

static void kde_decoration_manager_create(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                                          struct wl_resource *surface) {
    struct wl_resource *deco = wl_resource_create(client, &org_kde_kwin_server_decoration_interface, 1, id);
    if (!deco) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(deco, &kde_decoration_impl, NULL, NULL);
    org_kde_kwin_server_decoration_send_mode(deco, ORG_KDE_KWIN_SERVER_DECORATION_MODE_SERVER);
}

static const struct org_kde_kwin_server_decoration_manager_interface kde_decoration_manager_impl = {
    .create = kde_decoration_manager_create,
};

static void kde_decoration_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &org_kde_kwin_server_decoration_manager_interface,
                                                      version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &kde_decoration_manager_impl, data, NULL);
    org_kde_kwin_server_decoration_manager_send_default_mode(resource, ORG_KDE_KWIN_SERVER_DECORATION_MODE_SERVER);
}

/* ---- xdg_activation_v1: apps raising their own (or a new) window ---- */

static void token_noop_serial(struct wl_client *client, struct wl_resource *resource,
                              uint32_t serial, struct wl_resource *seat) {
}

static void token_noop_string(struct wl_client *client, struct wl_resource *resource, const char *app_id) {
}

static void token_noop_surface(struct wl_client *client, struct wl_resource *resource, struct wl_resource *surface) {
}

/* Every token is granted: the host decides whether raising is appropriate. */
static void token_commit(struct wl_client *client, struct wl_resource *resource) {
    static uint32_t next_token;
    char token[32];
    snprintf(token, sizeof(token), "ishwl-%u", ++next_token);
    xdg_activation_token_v1_send_done(resource, token);
}

static const struct xdg_activation_token_v1_interface token_impl = {
    .set_serial = token_noop_serial,
    .set_app_id = token_noop_string,
    .set_surface = token_noop_surface,
    .commit = token_commit,
    .destroy = destroy_request,
};

static void activation_get_token(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct wl_resource *token = wl_resource_create(client, &xdg_activation_token_v1_interface, 1, id);
    if (!token) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(token, &token_impl, NULL, NULL);
}

static void activation_activate(struct wl_client *client, struct wl_resource *resource,
                                const char *token, struct wl_resource *surface_resource) {
    struct surface *surface = surface_from_resource(surface_resource);
    struct server *s = wl_resource_get_user_data(resource);
    int32_t x, y;
    struct view *v = surface_view(surface, &x, &y);
    if (v && v->announced)
        bridge_send(s, "activate %u\n", view_toplevel(v)->id);
}

static const struct xdg_activation_v1_interface activation_impl = {
    .destroy = destroy_request,
    .get_activation_token = activation_get_token,
    .activate = activation_activate,
};

static void activation_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &xdg_activation_v1_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &activation_impl, data, NULL);
}

void misc_globals_init(struct server *s) {
    wl_global_create(s->display, &wl_output_interface, 4, s, output_bind);
    wl_global_create(s->display, &zxdg_decoration_manager_v1_interface, 1, s, xdg_decoration_bind);
    wl_global_create(s->display, &org_kde_kwin_server_decoration_manager_interface, 1, s, kde_decoration_bind);
    wl_global_create(s->display, &xdg_activation_v1_interface, 1, s, activation_bind);
}
