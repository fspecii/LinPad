/**
 * @file xdg-wm-base.c
 * @brief Stable xdg-shell (xdg_wm_base) window provider for VLC 3.0
 *
 * VLC 3.0 only ships an xdg-shell *unstable v5* window provider, which no current
 * compositor (ishwl included) offers, so distributions build VLC without Wayland.
 * This is VLC 3.0.21's modules/video_output/wayland/xdg-shell.c ported to
 * xdg_wm_base / xdg_toplevel; the Wayland video output itself (wl_shm) is VLC's own
 * shm.c, built unchanged next to it (see build-vlc-wayland.sh).
 */
/*****************************************************************************
 * Copyright © 2014, 2017 Rémi Denis-Courmont
 * Port to xdg_wm_base: 2026, iSH-ARM64 desktop
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *****************************************************************************/

#include <assert.h>
#include <inttypes.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "server-decoration-client-protocol.h"

#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_vout_window.h>

struct vout_window_sys_t
{
    struct wl_compositor *compositor;
    struct xdg_wm_base *wm_base;
    struct xdg_surface *surface;
    struct xdg_toplevel *toplevel;
    struct org_kde_kwin_server_decoration_manager *deco_manager;
    struct org_kde_kwin_server_decoration *deco;
    int32_t pending_width, pending_height;

    vlc_thread_t thread;
};

static void cleanup_wl_display_read(void *data)
{
    wl_display_cancel_read(data);
}

static void *Thread(void *data)
{
    vout_window_t *wnd = data;
    struct wl_display *display = wnd->display.wl;
    struct pollfd ufd[1];

    int canc = vlc_savecancel();
    vlc_cleanup_push(cleanup_wl_display_read, display);

    ufd[0].fd = wl_display_get_fd(display);
    ufd[0].events = POLLIN;

    for (;;)
    {
        while (wl_display_prepare_read(display) != 0)
            wl_display_dispatch_pending(display);

        wl_display_flush(display);
        vlc_restorecancel(canc);

        while (poll(ufd, 1, -1) < 0);

        canc = vlc_savecancel();
        wl_display_read_events(display);
        wl_display_dispatch_pending(display);
    }
    vlc_assert_unreachable();
    vlc_cleanup_pop();
}

static int Control(vout_window_t *wnd, int cmd, va_list ap)
{
    vout_window_sys_t *sys = wnd->sys;
    struct wl_display *display = wnd->display.wl;

    switch (cmd)
    {
        case VOUT_WINDOW_SET_STATE:
            return VLC_EGENERIC;

        case VOUT_WINDOW_SET_SIZE:
        {
            unsigned width = va_arg(ap, unsigned);
            unsigned height = va_arg(ap, unsigned);

            /* The client chooses its size (the buffer size); see the upstream file. */
            vout_window_ReportSize(wnd, width, height);
            xdg_surface_set_window_geometry(sys->surface, 0, 0, width, height);
            break;
        }

        case VOUT_WINDOW_SET_FULLSCREEN:
        {
            bool fs = va_arg(ap, int);

            if (fs)
                xdg_toplevel_set_fullscreen(sys->toplevel, NULL);
            else
                xdg_toplevel_unset_fullscreen(sys->toplevel);
            break;
        }

        default:
            msg_Err(wnd, "request %d not implemented", cmd);
            return VLC_EGENERIC;
    }

    wl_display_flush(display);
    return VLC_SUCCESS;
}

static void toplevel_configure_cb(void *data, struct xdg_toplevel *toplevel,
                                  int32_t width, int32_t height,
                                  struct wl_array *states)
{
    vout_window_t *wnd = data;
    vout_window_sys_t *sys = wnd->sys;

    msg_Dbg(wnd, "new configuration: %"PRId32"x%"PRId32, width, height);
    sys->pending_width = width;
    sys->pending_height = height;
    (void) toplevel; (void) states;
}

static void toplevel_close_cb(void *data, struct xdg_toplevel *toplevel)
{
    vout_window_ReportClose((vout_window_t *)data);
    (void) toplevel;
}

static void toplevel_configure_bounds_cb(void *data, struct xdg_toplevel *toplevel,
                                         int32_t width, int32_t height)
{
    (void) data; (void) toplevel; (void) width; (void) height;
}

static void toplevel_wm_capabilities_cb(void *data, struct xdg_toplevel *toplevel,
                                        struct wl_array *caps)
{
    (void) data; (void) toplevel; (void) caps;
}

static const struct xdg_toplevel_listener toplevel_cbs =
{
    .configure = toplevel_configure_cb,
    .close = toplevel_close_cb,
    .configure_bounds = toplevel_configure_bounds_cb,
    .wm_capabilities = toplevel_wm_capabilities_cb,
};

static void xdg_surface_configure_cb(void *data, struct xdg_surface *surface,
                                     uint32_t serial)
{
    vout_window_t *wnd = data;
    vout_window_sys_t *sys = wnd->sys;

    /* Zero means the client chooses: never report that to the video output. */
    if (sys->pending_width != 0 && sys->pending_height != 0)
        vout_window_ReportSize(wnd, sys->pending_width, sys->pending_height);
    xdg_surface_ack_configure(surface, serial);
}

static const struct xdg_surface_listener xdg_surface_cbs =
{
    .configure = xdg_surface_configure_cb,
};

static void wm_base_ping_cb(void *data, struct xdg_wm_base *wm_base, uint32_t serial)
{
    xdg_wm_base_pong(wm_base, serial);
    (void) data;
}

static const struct xdg_wm_base_listener wm_base_cbs =
{
    .ping = wm_base_ping_cb,
};

static void registry_global_cb(void *data, struct wl_registry *registry,
                               uint32_t name, const char *iface, uint32_t vers)
{
    vout_window_t *wnd = data;
    vout_window_sys_t *sys = wnd->sys;

    if (!strcmp(iface, "wl_compositor"))
        sys->compositor = wl_registry_bind(registry, name, &wl_compositor_interface,
                                           (vers < 2) ? vers : 2);
    else if (!strcmp(iface, "xdg_wm_base"))
        sys->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
    else if (!strcmp(iface, "org_kde_kwin_server_decoration_manager"))
        sys->deco_manager = wl_registry_bind(registry, name,
                         &org_kde_kwin_server_decoration_manager_interface, 1);
}

static void registry_global_remove_cb(void *data, struct wl_registry *registry,
                                      uint32_t name)
{
    (void) data; (void) registry; (void) name;
}

static const struct wl_registry_listener registry_cbs =
{
    registry_global_cb,
    registry_global_remove_cb,
};

static void Destroy(vout_window_sys_t *sys, struct wl_surface *surface,
                    struct wl_display *display)
{
    if (sys->deco != NULL)
        org_kde_kwin_server_decoration_destroy(sys->deco);
    if (sys->deco_manager != NULL)
        org_kde_kwin_server_decoration_manager_destroy(sys->deco_manager);
    if (sys->toplevel != NULL)
        xdg_toplevel_destroy(sys->toplevel);
    if (sys->surface != NULL)
        xdg_surface_destroy(sys->surface);
    if (surface != NULL)
        wl_surface_destroy(surface);
    if (sys->wm_base != NULL)
        xdg_wm_base_destroy(sys->wm_base);
    if (sys->compositor != NULL)
        wl_compositor_destroy(sys->compositor);
    wl_display_disconnect(display);
    free(sys);
}

static int Open(vout_window_t *wnd, const vout_window_cfg_t *cfg)
{
    if (cfg->type != VOUT_WINDOW_TYPE_INVALID
     && cfg->type != VOUT_WINDOW_TYPE_WAYLAND)
        return VLC_EGENERIC;

    vout_window_sys_t *sys = calloc(1, sizeof (*sys));
    if (unlikely(sys == NULL))
        return VLC_ENOMEM;
    wnd->sys = sys;

    char *dpy_name = var_InheritString(wnd, "wl-display");
    struct wl_display *display = wl_display_connect(dpy_name);
    free(dpy_name);
    if (display == NULL)
    {
        free(sys);
        return VLC_EGENERIC;
    }

    struct wl_surface *surface = NULL;
    struct wl_registry *registry = wl_display_get_registry(display);
    if (registry == NULL)
        goto error;

    wl_registry_add_listener(registry, &registry_cbs, wnd);
    wl_display_roundtrip(display);
    wl_registry_destroy(registry);

    if (sys->compositor == NULL || sys->wm_base == NULL)
        goto error;

    xdg_wm_base_add_listener(sys->wm_base, &wm_base_cbs, NULL);

    surface = wl_compositor_create_surface(sys->compositor);
    if (surface == NULL)
        goto error;

    sys->surface = xdg_wm_base_get_xdg_surface(sys->wm_base, surface);
    if (sys->surface == NULL)
        goto error;
    xdg_surface_add_listener(sys->surface, &xdg_surface_cbs, wnd);

    sys->toplevel = xdg_surface_get_toplevel(sys->surface);
    if (sys->toplevel == NULL)
        goto error;
    xdg_toplevel_add_listener(sys->toplevel, &toplevel_cbs, wnd);

    char *title = var_InheritString(wnd, "video-title");
    xdg_toplevel_set_title(sys->toplevel, (title != NULL) ? title : "VLC media player");
    free(title);

    char *app_id = var_InheritString(wnd, "app-id");
    xdg_toplevel_set_app_id(sys->toplevel, (app_id != NULL) ? app_id : "vlc");
    free(app_id);

    xdg_surface_set_window_geometry(sys->surface, 0, 0, cfg->width, cfg->height);
    vout_window_ReportSize(wnd, cfg->width, cfg->height);

    const uint_fast32_t deco_mode =
        var_InheritBool(wnd, "video-deco")
            ? ORG_KDE_KWIN_SERVER_DECORATION_MODE_SERVER
            : ORG_KDE_KWIN_SERVER_DECORATION_MODE_CLIENT;

    if (sys->deco_manager != NULL)
        sys->deco = org_kde_kwin_server_decoration_manager_create(sys->deco_manager, surface);
    if (sys->deco != NULL)
        org_kde_kwin_server_decoration_request_mode(sys->deco, deco_mode);

    /* xdg-shell: the first commit carries no buffer; the compositor answers with the
     * initial configure, which must be acked before the video output attaches one. */
    wl_surface_commit(surface);
    wl_display_roundtrip(display);

    wnd->type = VOUT_WINDOW_TYPE_WAYLAND;
    wnd->handle.wl = surface;
    wnd->display.wl = display;
    wnd->control = Control;

    vout_window_SetFullScreen(wnd, cfg->is_fullscreen);

    if (vlc_clone(&sys->thread, Thread, wnd, VLC_THREAD_PRIORITY_LOW))
        goto error;

    return VLC_SUCCESS;

error:
    Destroy(sys, surface, display);
    return VLC_EGENERIC;
}

static void Close(vout_window_t *wnd)
{
    vout_window_sys_t *sys = wnd->sys;

    vlc_cancel(sys->thread);
    vlc_join(sys->thread, NULL);
    Destroy(sys, wnd->handle.wl, wnd->display.wl);
}

#define DISPLAY_TEXT N_("Wayland display")
#define DISPLAY_LONGTEXT N_( \
    "Video will be rendered with this Wayland display. " \
    "If empty, the default display will be used.")

vlc_module_begin()
    set_shortname(N_("XDG shell"))
    set_description(N_("XDG shell surface (xdg_wm_base)"))
    set_category(CAT_VIDEO)
    set_subcategory(SUBCAT_VIDEO_VOUT)
    set_capability("vout window", 20)
    set_callbacks(Open, Close)

    add_string("wl-display", NULL, DISPLAY_TEXT, DISPLAY_LONGTEXT, true)
vlc_module_end()
