/* zwp_linux_dmabuf_v1, feedback only.
 *
 * Mesa's Wayland EGL platform takes its render node from the compositor's
 * default dma-buf feedback. With the emulated virtio-gpu node present
 * (gpu/DESIGN.md), advertising that node is what lets EGL load zink on top of
 * Venus. Buffers still arrive as wl_shm (Vulkan WSI with MESA_VK_WSI_DEBUG=sw),
 * so importing dma-bufs is refused. Firefox's GPU WebRender draws nothing
 * through this path yet (gpu/DESIGN.md), so the global is opt-in per client.
 */
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include "ishwl.h"
#include "linux-dmabuf-v1-protocol.h"

#define RENDER_NODE "/dev/dri/renderD128"
#define DRM_FORMAT_ARGB8888 0x34325241
#define DRM_FORMAT_XRGB8888 0x34325258
#define DRM_FORMAT_MOD_LINEAR 0

static dev_t render_dev;

struct format_entry {
    uint32_t format;
    uint32_t pad;
    uint64_t modifier;
};

static const struct format_entry format_table[] = {
    {DRM_FORMAT_ARGB8888, 0, DRM_FORMAT_MOD_LINEAR},
    {DRM_FORMAT_XRGB8888, 0, DRM_FORMAT_MOD_LINEAR},
};

static void resource_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void params_add(struct wl_client *client, struct wl_resource *resource, int32_t fd,
                       uint32_t plane_idx, uint32_t offset, uint32_t stride,
                       uint32_t modifier_hi, uint32_t modifier_lo) {
    close(fd);
}

static void params_create(struct wl_client *client, struct wl_resource *resource,
                          int32_t width, int32_t height, uint32_t format, uint32_t flags) {
    zwp_linux_buffer_params_v1_send_failed(resource);
}

static void params_create_immed(struct wl_client *client, struct wl_resource *resource,
                                uint32_t buffer_id, int32_t width, int32_t height,
                                uint32_t format, uint32_t flags) {
    wl_resource_post_error(resource, ZWP_LINUX_BUFFER_PARAMS_V1_ERROR_INVALID_WL_BUFFER,
                           "dma-buf import is not supported");
}

static const struct zwp_linux_buffer_params_v1_interface params_impl = {
    .destroy = resource_destroy,
    .add = params_add,
    .create = params_create,
    .create_immed = params_create_immed,
};

static const struct zwp_linux_dmabuf_feedback_v1_interface feedback_impl = {
    .destroy = resource_destroy,
};

static void send_feedback(struct wl_client *client, struct wl_resource *dmabuf, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &zwp_linux_dmabuf_feedback_v1_interface,
                                                      wl_resource_get_version(dmabuf), id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &feedback_impl, NULL, NULL);

    int fd = memfd_create("ishwl-dmabuf-formats", MFD_CLOEXEC);
    if (fd >= 0 && write(fd, format_table, sizeof(format_table)) == (ssize_t) sizeof(format_table)) {
        zwp_linux_dmabuf_feedback_v1_send_format_table(resource, fd, sizeof(format_table));
    }
    if (fd >= 0)
        close(fd);

    struct wl_array device;
    wl_array_init(&device);
    dev_t *dev = wl_array_add(&device, sizeof(*dev));
    if (dev)
        *dev = render_dev;
    zwp_linux_dmabuf_feedback_v1_send_main_device(resource, &device);
    zwp_linux_dmabuf_feedback_v1_send_tranche_target_device(resource, &device);
    wl_array_release(&device);

    struct wl_array indices;
    wl_array_init(&indices);
    for (uint16_t i = 0; i < sizeof(format_table) / sizeof(format_table[0]); i++) {
        uint16_t *index = wl_array_add(&indices, sizeof(*index));
        if (index)
            *index = i;
    }
    zwp_linux_dmabuf_feedback_v1_send_tranche_flags(resource, 0);
    zwp_linux_dmabuf_feedback_v1_send_tranche_formats(resource, &indices);
    zwp_linux_dmabuf_feedback_v1_send_tranche_done(resource);
    wl_array_release(&indices);
    zwp_linux_dmabuf_feedback_v1_send_done(resource);
}

static void dmabuf_create_params(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    struct wl_resource *params = wl_resource_create(client, &zwp_linux_buffer_params_v1_interface,
                                                    wl_resource_get_version(resource), id);
    if (!params) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(params, &params_impl, NULL, NULL);
}

static void dmabuf_get_default_feedback(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
    send_feedback(client, resource, id);
}

static void dmabuf_get_surface_feedback(struct wl_client *client, struct wl_resource *resource,
                                        uint32_t id, struct wl_resource *surface) {
    send_feedback(client, resource, id);
}

static const struct zwp_linux_dmabuf_v1_interface dmabuf_impl = {
    .destroy = resource_destroy,
    .create_params = dmabuf_create_params,
    .get_default_feedback = dmabuf_get_default_feedback,
    .get_surface_feedback = dmabuf_get_surface_feedback,
};

static void dmabuf_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client, &zwp_linux_dmabuf_v1_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &dmabuf_impl, data, NULL);
}

/* Clients that connected through the "<socket>-gpu" socket. Only they (or every
 * client, with ISHWL_DMABUF=1) see zwp_linux_dmabuf_v1, so an app opts in to EGL
 * on the GPU with WAYLAND_DISPLAY=wayland-0-gpu while everything else keeps the
 * plain wl_shm-only view of the compositor. */
struct gpu_client {
    struct wl_client *client;
    struct wl_listener destroy;
    struct wl_list link;
};
static struct wl_list gpu_clients;
static bool dmabuf_for_all;
static const struct wl_global *dmabuf_global;

static void gpu_client_destroyed(struct wl_listener *listener, void *data) {
    struct gpu_client *gc = wl_container_of(listener, gc, destroy);
    wl_list_remove(&gc->link);
    free(gc);
}

static bool is_gpu_client(const struct wl_client *client) {
    struct gpu_client *gc;
    wl_list_for_each(gc, &gpu_clients, link)
        if (gc->client == client)
            return true;
    return false;
}

static bool global_filter(const struct wl_client *client, const struct wl_global *global, void *data) {
    return global != dmabuf_global || dmabuf_for_all || is_gpu_client(client);
}

static int gpu_socket_accept(int fd, uint32_t mask, void *data) {
    struct server *s = data;
    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0)
        return 0;
    fcntl(cfd, F_SETFD, FD_CLOEXEC);
    struct wl_client *client = wl_client_create(s->display, cfd);
    if (!client)
        return 0;
    struct gpu_client *gc = calloc(1, sizeof(*gc));
    if (!gc)
        return 0;
    gc->client = client;
    gc->destroy.notify = gpu_client_destroyed;
    wl_client_add_destroy_listener(client, &gc->destroy);
    wl_list_insert(&gpu_clients, &gc->link);
    return 0;
}

static void open_gpu_socket(struct server *s) {
    const char *dir = getenv("XDG_RUNTIME_DIR");
    if (!dir)
        return;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/%s-gpu", dir, s->socket_name) >= (int) sizeof(addr.sun_path))
        return;
    unlink(addr.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return;
    if (bind(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0 || listen(fd, 16) < 0) {
        close(fd);
        return;
    }
    wl_event_loop_add_fd(s->loop, fd, WL_EVENT_READABLE, gpu_socket_accept, s);
    log_msg(s, "GPU clients: WAYLAND_DISPLAY=%s-gpu", s->socket_name);
}

void dmabuf_init(struct server *s) {
    /* The node can outlive the emulator build that created it; only an open
     * that succeeds means the device is really there. */
    int fd = open(RENDER_NODE, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return;
    struct stat st;
    int err = fstat(fd, &st);
    close(fd);
    if (err != 0 || !S_ISCHR(st.st_mode))
        return;
    render_dev = st.st_rdev;
    const char *all = getenv("ISHWL_DMABUF");
    dmabuf_for_all = all != NULL && strcmp(all, "1") == 0;
    wl_list_init(&gpu_clients);
    dmabuf_global = wl_global_create(s->display, &zwp_linux_dmabuf_v1_interface, 4, s, dmabuf_bind);
    wl_display_set_global_filter(s->display, global_filter, NULL);
    open_gpu_socket(s);
}
