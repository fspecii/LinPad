// Emulated virtio-gpu DRM render node (/dev/dri/renderD128) backed by an
// in-process virglrenderer. Only the Venus (Vulkan) capset is offered; that is
// what Mesa's virtio Vulkan driver needs, and GL goes through zink on top.
//
// Guest memory never crosses a copy for blob resources: virglrenderer exports
// host-visible memory as a shm fd (on Apple: the same pages MoltenVK wraps in
// an MTLBuffer), and the guest mapping is a host mmap of that fd installed
// straight into the guest page table.

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <virglrenderer.h>

#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/dev_virtgpu.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/poll.h"
#include "util/list.h"

// --- uAPI (include/uapi/drm/drm.h, virtgpu_drm.h), aarch64 layout ---

#define DRM_IOCTL_TYPE 'd'
#define DRM_COMMAND_BASE 0x40
#define IOC_NR(cmd) ((cmd) & 0xff)
#define IOC_TYPE(cmd) (((cmd) >> 8) & 0xff)
#define IOC_SIZE(cmd) (((cmd) >> 16) & 0x3fff)

#define DRM_NR_VERSION 0x00
#define DRM_NR_GEM_CLOSE 0x09
#define DRM_NR_GET_CAP 0x0c
#define DRM_NR_SET_CLIENT_CAP 0x0d
#define DRM_NR_PRIME_HANDLE_TO_FD 0x2d
#define DRM_NR_PRIME_FD_TO_HANDLE 0x2e

#define VIRTGPU_NR_MAP 0x01
#define VIRTGPU_NR_EXECBUFFER 0x02
#define VIRTGPU_NR_GETPARAM 0x03
#define VIRTGPU_NR_RESOURCE_INFO 0x05
#define VIRTGPU_NR_WAIT 0x08
#define VIRTGPU_NR_GET_CAPS 0x09
#define VIRTGPU_NR_RESOURCE_CREATE_BLOB 0x0a
#define VIRTGPU_NR_CONTEXT_INIT 0x0b

struct drm_version_ {
    int32_t version_major;
    int32_t version_minor;
    int32_t version_patchlevel;
    uint32_t pad;
    uint64_t name_len;
    uint64_t name;
    uint64_t date_len;
    uint64_t date;
    uint64_t desc_len;
    uint64_t desc;
};

struct drm_gem_close_ {
    uint32_t handle;
    uint32_t pad;
};

struct drm_get_cap_ {
    uint64_t capability;
    uint64_t value;
};
#define DRM_CAP_PRIME_ 0x5
#define DRM_PRIME_CAP_IMPORT_ 0x1
#define DRM_PRIME_CAP_EXPORT_ 0x2

struct drm_prime_handle_ {
    uint32_t handle;
    uint32_t flags;
    int32_t fd;
};
#define DRM_CLOEXEC_ O_CLOEXEC_

struct drm_virtgpu_map_ {
    uint64_t offset;
    uint32_t handle;
    uint32_t pad;
};

struct drm_virtgpu_execbuffer_ {
    uint32_t flags;
    uint32_t size;
    uint64_t command;
    uint64_t bo_handles;
    uint32_t num_bo_handles;
    int32_t fence_fd;
    uint32_t ring_idx;
    uint32_t syncobj_stride;
    uint32_t num_in_syncobjs;
    uint32_t num_out_syncobjs;
    uint64_t in_syncobjs;
    uint64_t out_syncobjs;
};
#define VIRTGPU_EXECBUF_FENCE_FD_IN_ 0x01
#define VIRTGPU_EXECBUF_FENCE_FD_OUT_ 0x02
#define VIRTGPU_EXECBUF_RING_IDX_ 0x04

struct drm_virtgpu_getparam_ {
    uint64_t param;
    uint64_t value;
};
#define VIRTGPU_PARAM_3D_FEATURES_ 1
#define VIRTGPU_PARAM_CAPSET_QUERY_FIX_ 2
#define VIRTGPU_PARAM_RESOURCE_BLOB_ 3
#define VIRTGPU_PARAM_HOST_VISIBLE_ 4
#define VIRTGPU_PARAM_CROSS_DEVICE_ 5
#define VIRTGPU_PARAM_CONTEXT_INIT_ 6
#define VIRTGPU_PARAM_SUPPORTED_CAPSET_IDS_ 7

struct drm_virtgpu_resource_info_ {
    uint32_t bo_handle;
    uint32_t res_handle;
    uint32_t size;
    uint32_t blob_mem;
};

struct drm_virtgpu_get_caps_ {
    uint32_t cap_set_id;
    uint32_t cap_set_ver;
    uint64_t addr;
    uint32_t size;
    uint32_t pad;
};
#define VIRTGPU_CAPSET_VENUS_ 4

struct drm_virtgpu_resource_create_blob_ {
    uint32_t blob_mem;
    uint32_t blob_flags;
    uint32_t bo_handle;
    uint32_t res_handle;
    uint64_t size;
    uint32_t pad;
    uint32_t cmd_size;
    uint64_t cmd;
    uint64_t blob_id;
    uint32_t blob_hints;
    uint32_t pad2;
};
#define VIRTGPU_BLOB_MEM_HOST3D_ 2

struct drm_virtgpu_context_set_param_ {
    uint64_t param;
    uint64_t value;
};
struct drm_virtgpu_context_init_ {
    uint32_t num_params;
    uint32_t pad;
    uint64_t ctx_set_params;
};
#define VIRTGPU_CONTEXT_PARAM_CAPSET_ID_ 1
#define VIRTGPU_CONTEXT_PARAM_NUM_RINGS_ 2
#define VIRTGPU_CONTEXT_PARAM_POLL_RINGS_MASK_ 3
#define VIRTGPU_CONTEXT_PARAM_DEBUG_NAME_ 4

#define MAX_RINGS 64
#define MAX_CTXS 1024
#define MAX_CMD_SIZE (64 << 20)

// --- state ---

static bool debug_enabled;
#define VGPU_DEBUG(...) do { if (debug_enabled) fprintf(stderr, "virtgpu: " __VA_ARGS__); } while (0)

// virglrenderer is not thread-safe; every call into it holds this lock.
static pthread_mutex_t renderer_lock = PTHREAD_MUTEX_INITIALIZER;
static bool renderer_ready;
static int renderer_init_err;

struct vgpu_res {
    uint32_t id;
    uint64_t size;
    uint32_t blob_mem;
    uint32_t blob_flags;
    atomic_uint refcount;
};

struct vgpu_ctx {
    uint32_t id;
    atomic_uint refcount;
    atomic_uint_fast64_t next_fence;
    // Guards signaled[] and fences; taken by the renderer's fence thread.
    pthread_mutex_t fence_lock;
    uint64_t signaled[MAX_RINGS];
    uint64_t submitted[MAX_RINGS];
    struct list fences;
};

struct vgpu_fence {
    struct vgpu_ctx *ctx;
    uint32_t ring;
    uint64_t id;
    struct fd *fd;
    struct list ctx_link;
};

struct vgpu_file {
    pthread_mutex_t lock;
    struct vgpu_ctx *ctx;
    struct vgpu_res **handles; // handle N lives at handles[N - 1]
    uint32_t handles_cap;
};

static pthread_mutex_t ctx_table_lock = PTHREAD_MUTEX_INITIALIZER;
static struct vgpu_ctx *ctx_table[MAX_CTXS];

// Without eventfd (macOS/iOS) virglrenderer cannot signal fences from its own
// thread, so this thread polls contexts while they have unsignaled fences.
static pthread_mutex_t poller_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t poller_cond = PTHREAD_COND_INITIALIZER;
static unsigned poller_pending;
#define POLLER_INTERVAL_US 200
static atomic_uint next_res_id = 1;

static const struct fd_ops virtgpu_fence_ops;
static const struct fd_ops virtgpu_prime_ops;

// --- renderer ---

static void ctx_release(struct vgpu_ctx *ctx);

static void write_context_fence(void *cookie, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id) {
    (void) cookie;
    if (ctx_id >= MAX_CTXS || ring_idx >= MAX_RINGS)
        return;
    pthread_mutex_lock(&ctx_table_lock);
    struct vgpu_ctx *ctx = ctx_table[ctx_id];
    if (ctx != NULL)
        ctx->refcount++;
    pthread_mutex_unlock(&ctx_table_lock);
    if (ctx == NULL)
        return;

    pthread_mutex_lock(&ctx->fence_lock);
    bool was_pending = ctx->signaled[ring_idx] < ctx->submitted[ring_idx];
    if (fence_id > ctx->signaled[ring_idx])
        ctx->signaled[ring_idx] = fence_id;
    bool done = was_pending && ctx->signaled[ring_idx] >= ctx->submitted[ring_idx];
    struct vgpu_fence *fence;
    list_for_each_entry(&ctx->fences, fence, ctx_link) {
        if (fence->ring == ring_idx && fence->id <= fence_id)
            poll_wakeup(fence->fd, POLL_READ);
    }
    pthread_mutex_unlock(&ctx->fence_lock);
    if (done) {
        pthread_mutex_lock(&poller_lock);
        poller_pending--;
        pthread_mutex_unlock(&poller_lock);
    }
    // The poller holds its own reference while this runs, so this never
    // drops the last one (which would re-enter the renderer).
    ctx_release(ctx);
}

static bool ctx_has_pending(struct vgpu_ctx *ctx) {
    bool pending = false;
    pthread_mutex_lock(&ctx->fence_lock);
    for (int i = 0; i < MAX_RINGS && !pending; i++)
        pending = ctx->signaled[i] < ctx->submitted[i];
    pthread_mutex_unlock(&ctx->fence_lock);
    return pending;
}

static void *poller_main(void *arg) {
    (void) arg;
    pthread_setname_np("virtgpu-fence");
    for (;;) {
        pthread_mutex_lock(&poller_lock);
        while (poller_pending == 0)
            pthread_cond_wait(&poller_cond, &poller_lock);
        pthread_mutex_unlock(&poller_lock);

        for (uint32_t id = 1; id < MAX_CTXS; id++) {
            pthread_mutex_lock(&ctx_table_lock);
            struct vgpu_ctx *ctx = ctx_table[id];
            if (ctx != NULL)
                ctx->refcount++;
            pthread_mutex_unlock(&ctx_table_lock);
            if (ctx == NULL)
                continue;
            if (ctx_has_pending(ctx)) {
                pthread_mutex_lock(&renderer_lock);
                virgl_renderer_context_poll(ctx->id);
                pthread_mutex_unlock(&renderer_lock);
            }
            ctx_release(ctx);
        }
        usleep(POLLER_INTERVAL_US);
    }
    return NULL;
}

static void renderer_log(enum virgl_log_level_flags level, const char *message, void *data) {
    (void) data;
    if (debug_enabled || level >= VIRGL_LOG_LEVEL_ERROR)
        fprintf(stderr, "virglrenderer: %s", message);
}

static struct virgl_renderer_callbacks renderer_callbacks = {
    .version = 3,
    .write_context_fence = write_context_fence,
};

static int renderer_init_locked(void) {
    if (renderer_ready)
        return 0;
    if (renderer_init_err)
        return renderer_init_err;
    virgl_set_log_callback(renderer_log, NULL, NULL);
    // Guest zink needs two things MoltenVK lacks (robustness2.nullDescriptor and
    // a dma-buf capable renderer); gpu/patches/virglrenderer-apple-zink-compat
    // advertises them to the guest when this is set.
    setenv("VKR_ZINK_COMPAT", "1", 0);
    // MoltenVK logs every instance and device creation at its default level.
    setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);
    int flags = VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL | VIRGL_RENDERER_RENDER_SERVER;
    int err = virgl_renderer_init(NULL, flags, &renderer_callbacks);
    if (err) {
        fprintf(stderr, "virtgpu: virgl_renderer_init failed: %d\n", err);
        renderer_init_err = _ENODEV;
        return renderer_init_err;
    }
    pthread_t poller;
    if (pthread_create(&poller, NULL, poller_main, NULL) == 0)
        pthread_detach(poller);
    renderer_ready = true;
    return 0;
}

// --- resources and handles ---

static void res_release(struct vgpu_res *res) {
    if (--res->refcount == 0) {
        pthread_mutex_lock(&renderer_lock);
        virgl_renderer_resource_unref(res->id);
        pthread_mutex_unlock(&renderer_lock);
        free(res);
    }
}

static uint32_t file_add_handle(struct vgpu_file *file, struct vgpu_res *res) {
    for (uint32_t i = 0; i < file->handles_cap; i++) {
        if (file->handles[i] == NULL) {
            file->handles[i] = res;
            return i + 1;
        }
    }
    uint32_t new_cap = file->handles_cap ? file->handles_cap * 2 : 64;
    struct vgpu_res **handles = realloc(file->handles, new_cap * sizeof(*handles));
    if (handles == NULL)
        return 0;
    memset(handles + file->handles_cap, 0, (new_cap - file->handles_cap) * sizeof(*handles));
    file->handles = handles;
    uint32_t handle = file->handles_cap + 1;
    file->handles_cap = new_cap;
    file->handles[handle - 1] = res;
    return handle;
}

static struct vgpu_res *file_get_res(struct vgpu_file *file, uint32_t handle) {
    if (handle == 0 || handle > file->handles_cap)
        return NULL;
    return file->handles[handle - 1];
}

// Maps a blob into guest memory: a fresh host mapping of the exported shm fd,
// owned (and eventually munmapped) by the guest page table.
static int map_res(struct vgpu_res *res, struct mem *mem, page_t start, pages_t pages, off_t offset, int prot) {
    if (offset < 0 || (uint64_t) offset + (uint64_t) pages * PAGE_SIZE > BYTES_ROUND_UP(res->size))
        return _EINVAL;
    uint32_t fd_type;
    int host_fd;
    pthread_mutex_lock(&renderer_lock);
    int err = virgl_renderer_resource_export_blob(res->id, &fd_type, &host_fd);
    pthread_mutex_unlock(&renderer_lock);
    if (err) {
        VGPU_DEBUG("export_blob(res %u) failed: %d\n", res->id, err);
        return _ENODEV;
    }
    if (fd_type != VIRGL_RENDERER_BLOB_FD_TYPE_SHM) {
        VGPU_DEBUG("res %u has unmappable fd type %u\n", res->id, fd_type);
        close(host_fd);
        return _ENODEV;
    }
    off_t real_offset = (offset / real_page_size) * real_page_size;
    size_t correction = offset - real_offset;
    void *memory = mmap(NULL, pages * PAGE_SIZE + correction, PROT_READ | PROT_WRITE,
            MAP_SHARED, host_fd, real_offset);
    close(host_fd);
    if (memory == MAP_FAILED)
        return errno_map();
    VGPU_DEBUG("map res %u: %lu pages at %#llx -> host %p\n", res->id, (unsigned long) pages,
            (unsigned long long) start << PAGE_BITS, memory);
    return pt_map(mem, start, pages, memory, correction, prot);
}

// --- contexts and fences ---

static void ctx_release(struct vgpu_ctx *ctx) {
    pthread_mutex_lock(&ctx_table_lock);
    bool last = --ctx->refcount == 0;
    if (last)
        ctx_table[ctx->id] = NULL;
    pthread_mutex_unlock(&ctx_table_lock);
    if (!last)
        return;
    unsigned pending_rings = 0;
    for (int i = 0; i < MAX_RINGS; i++)
        pending_rings += ctx->signaled[i] < ctx->submitted[i];
    if (pending_rings) {
        pthread_mutex_lock(&poller_lock);
        poller_pending -= pending_rings;
        pthread_mutex_unlock(&poller_lock);
    }
    VGPU_DEBUG("destroying context %u\n", ctx->id);
    pthread_mutex_lock(&renderer_lock);
    virgl_renderer_context_destroy(ctx->id);
    pthread_mutex_unlock(&renderer_lock);
    pthread_mutex_destroy(&ctx->fence_lock);
    free(ctx);
}

static struct vgpu_ctx *ctx_create(uint32_t capset_id, const char *name) {
    struct vgpu_ctx *ctx = calloc(1, sizeof(*ctx));
    if (ctx == NULL)
        return NULL;
    ctx->refcount = 1;
    ctx->next_fence = 1;
    pthread_mutex_init(&ctx->fence_lock, NULL);
    list_init(&ctx->fences);
    pthread_mutex_lock(&ctx_table_lock);
    for (uint32_t id = 1; id < MAX_CTXS; id++) {
        if (ctx_table[id] == NULL) {
            ctx->id = id;
            ctx_table[id] = ctx;
            break;
        }
    }
    pthread_mutex_unlock(&ctx_table_lock);
    if (ctx->id == 0) {
        free(ctx);
        return NULL;
    }
    pthread_mutex_lock(&renderer_lock);
    int err = virgl_renderer_context_create_with_flags(ctx->id, capset_id, strlen(name), name);
    pthread_mutex_unlock(&renderer_lock);
    if (err) {
        VGPU_DEBUG("context_create(%u, capset %u) failed: %d\n", ctx->id, capset_id, err);
        pthread_mutex_lock(&ctx_table_lock);
        ctx_table[ctx->id] = NULL;
        pthread_mutex_unlock(&ctx_table_lock);
        pthread_mutex_destroy(&ctx->fence_lock);
        free(ctx);
        return NULL;
    }
    return ctx;
}

static int fence_poll(struct fd *fd) {
    struct vgpu_fence *fence = fd->data;
    pthread_mutex_lock(&fence->ctx->fence_lock);
    bool signaled = fence->ctx->signaled[fence->ring] >= fence->id;
    pthread_mutex_unlock(&fence->ctx->fence_lock);
    return signaled ? POLL_READ : 0;
}

static int fence_close(struct fd *fd) {
    struct vgpu_fence *fence = fd->data;
    pthread_mutex_lock(&fence->ctx->fence_lock);
    list_remove(&fence->ctx_link);
    pthread_mutex_unlock(&fence->ctx->fence_lock);
    ctx_release(fence->ctx);
    free(fence);
    return 0;
}

static const struct fd_ops virtgpu_fence_ops = {
    .poll = fence_poll,
    .close = fence_close,
};

static int fence_fd_create(struct vgpu_ctx *ctx, uint32_t ring, uint64_t id) {
    struct vgpu_fence *fence = calloc(1, sizeof(*fence));
    if (fence == NULL)
        return _ENOMEM;
    struct fd *fd = adhoc_fd_create(&virtgpu_fence_ops);
    if (fd == NULL) {
        free(fence);
        return _ENOMEM;
    }
    pthread_mutex_lock(&ctx_table_lock);
    ctx->refcount++;
    pthread_mutex_unlock(&ctx_table_lock);
    *fence = (struct vgpu_fence) {.ctx = ctx, .ring = ring, .id = id, .fd = fd};
    fd->data = fence;
    pthread_mutex_lock(&ctx->fence_lock);
    list_add(&ctx->fences, &fence->ctx_link);
    pthread_mutex_unlock(&ctx->fence_lock);
    return f_install(fd, O_CLOEXEC_);
}

// --- prime (dma-buf) fds ---

struct vgpu_prime {
    struct vgpu_res *res;
};

static int prime_mmap(struct fd *fd, struct mem *mem, page_t start, pages_t pages, off_t offset, int prot, int flags) {
    (void) flags;
    struct vgpu_prime *prime = fd->data;
    return map_res(prime->res, mem, start, pages, offset, prot);
}

static off_t_ prime_lseek(struct fd *fd, off_t_ off, int whence) {
    struct vgpu_prime *prime = fd->data;
    // dma-buf only supports querying the size this way
    if (off != 0)
        return _EINVAL;
    if (whence == LSEEK_END)
        return prime->res->size;
    if (whence == LSEEK_SET)
        return 0;
    return _EINVAL;
}

static int prime_close(struct fd *fd) {
    struct vgpu_prime *prime = fd->data;
    res_release(prime->res);
    free(prime);
    return 0;
}

static const struct fd_ops virtgpu_prime_ops = {
    .mmap = prime_mmap,
    .lseek = prime_lseek,
    .close = prime_close,
};

// --- ioctls ---

static int ioctl_version(struct drm_version_ *v) {
    static const char name[] = "virtio_gpu";
    static const char date[] = "0";
    static const char desc[] = "virtio GPU (iSH virglrenderer)";
    v->version_major = 0;
    v->version_minor = 1;
    v->version_patchlevel = 0;
    struct { uint64_t *len; uint64_t addr; const char *str; } fields[] = {
        {&v->name_len, v->name, name},
        {&v->date_len, v->date, date},
        {&v->desc_len, v->desc, desc},
    };
    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        size_t len = strlen(fields[i].str);
        size_t copy = *fields[i].len < len ? *fields[i].len : len;
        if (copy && fields[i].addr && user_write(fields[i].addr, fields[i].str, copy))
            return _EFAULT;
        *fields[i].len = len;
    }
    return 0;
}

static int ioctl_getparam(struct drm_virtgpu_getparam_ *args) {
    uint64_t value;
    switch (args->param) {
        case VIRTGPU_PARAM_3D_FEATURES_:
        case VIRTGPU_PARAM_CAPSET_QUERY_FIX_:
        case VIRTGPU_PARAM_RESOURCE_BLOB_:
        case VIRTGPU_PARAM_HOST_VISIBLE_:
        case VIRTGPU_PARAM_CONTEXT_INIT_:
            value = 1;
            break;
        case VIRTGPU_PARAM_CROSS_DEVICE_:
            value = 0;
            break;
        case VIRTGPU_PARAM_SUPPORTED_CAPSET_IDS_:
            value = 1 << VIRTGPU_CAPSET_VENUS_;
            break;
        default:
            return _EINVAL;
    }
    // the kernel writes only the low 32 bits
    uint32_t value32 = value;
    if (user_write(args->value, &value32, sizeof(value32)))
        return _EFAULT;
    return 0;
}

static int ioctl_get_caps(struct drm_virtgpu_get_caps_ *args) {
    if (args->cap_set_id != VIRTGPU_CAPSET_VENUS_)
        return _EINVAL;
    uint32_t max_ver = 0, max_size = 0;
    pthread_mutex_lock(&renderer_lock);
    virgl_renderer_get_cap_set(args->cap_set_id, &max_ver, &max_size);
    if (max_size == 0 || args->cap_set_ver > max_ver) {
        pthread_mutex_unlock(&renderer_lock);
        return _EINVAL;
    }
    void *caps = calloc(1, max_size);
    if (caps == NULL) {
        pthread_mutex_unlock(&renderer_lock);
        return _ENOMEM;
    }
    virgl_renderer_fill_caps(args->cap_set_id, args->cap_set_ver, caps);
    pthread_mutex_unlock(&renderer_lock);
    size_t size = args->size < max_size ? args->size : max_size;
    int err = user_write(args->addr, caps, size) ? _EFAULT : 0;
    free(caps);
    return err;
}

static int ioctl_context_init(struct vgpu_file *file, struct drm_virtgpu_context_init_ *args) {
    if (file->ctx != NULL)
        return _EEXIST;
    if (args->num_params > 16)
        return _EINVAL;
    struct drm_virtgpu_context_set_param_ params[16];
    if (user_read(args->ctx_set_params, params, args->num_params * sizeof(params[0])))
        return _EFAULT;
    uint32_t capset_id = 0;
    for (uint32_t i = 0; i < args->num_params; i++) {
        switch (params[i].param) {
            case VIRTGPU_CONTEXT_PARAM_CAPSET_ID_:
                capset_id = params[i].value;
                break;
            case VIRTGPU_CONTEXT_PARAM_NUM_RINGS_:
                if (params[i].value > MAX_RINGS)
                    return _EINVAL;
                break;
            case VIRTGPU_CONTEXT_PARAM_POLL_RINGS_MASK_:
            case VIRTGPU_CONTEXT_PARAM_DEBUG_NAME_:
                break;
            default:
                return _EINVAL;
        }
    }
    if (capset_id != VIRTGPU_CAPSET_VENUS_)
        return _EINVAL;
    char name[sizeof(current->comm) + 1] = {};
    strncpy(name, current->comm, sizeof(current->comm));
    file->ctx = ctx_create(capset_id, name);
    return file->ctx ? 0 : _ENOMEM;
}

static int submit_guest_cmd(struct vgpu_ctx *ctx, addr_t addr, uint32_t size) {
    if (size == 0)
        return 0;
    if (size % 4 != 0 || size > MAX_CMD_SIZE)
        return _EINVAL;
    void *cmd = malloc(size);
    if (cmd == NULL)
        return _ENOMEM;
    if (user_read(addr, cmd, size)) {
        free(cmd);
        return _EFAULT;
    }
    pthread_mutex_lock(&renderer_lock);
    int err = virgl_renderer_submit_cmd(cmd, ctx->id, size / 4);
    pthread_mutex_unlock(&renderer_lock);
    free(cmd);
    if (err) {
        VGPU_DEBUG("submit_cmd(ctx %u, %u bytes) failed: %d\n", ctx->id, size, err);
        return _EINVAL;
    }
    return 0;
}

static int ioctl_execbuffer(struct vgpu_file *file, struct drm_virtgpu_execbuffer_ *args) {
    struct vgpu_ctx *ctx = file->ctx;
    if (ctx == NULL)
        return _EINVAL;
    uint32_t ring = (args->flags & VIRTGPU_EXECBUF_RING_IDX_) ? args->ring_idx : 0;
    if (ring >= MAX_RINGS)
        return _EINVAL;
    if (args->num_in_syncobjs || args->num_out_syncobjs)
        return _EINVAL;
    int err = submit_guest_cmd(ctx, args->command, args->size);
    if (err < 0)
        return err;
    if (args->flags & VIRTGPU_EXECBUF_FENCE_FD_OUT_) {
        uint64_t fence_id = ctx->next_fence++;
        pthread_mutex_lock(&ctx->fence_lock);
        bool was_idle = ctx->signaled[ring] >= ctx->submitted[ring];
        ctx->submitted[ring] = fence_id;
        pthread_mutex_unlock(&ctx->fence_lock);
        if (was_idle) {
            pthread_mutex_lock(&poller_lock);
            poller_pending++;
            pthread_cond_signal(&poller_cond);
            pthread_mutex_unlock(&poller_lock);
        }
        pthread_mutex_lock(&renderer_lock);
        err = virgl_renderer_context_create_fence(ctx->id, 0, ring, fence_id);
        pthread_mutex_unlock(&renderer_lock);
        if (err)
            return _EINVAL;
        int fd = fence_fd_create(ctx, ring, fence_id);
        if (fd < 0)
            return fd;
        args->fence_fd = fd;
    }
    return 0;
}

static int ioctl_create_blob(struct vgpu_file *file, struct drm_virtgpu_resource_create_blob_ *args) {
    struct vgpu_ctx *ctx = file->ctx;
    if (ctx == NULL)
        return _EINVAL;
    if (args->blob_mem != VIRTGPU_BLOB_MEM_HOST3D_ || args->size == 0)
        return _EINVAL;
    int err = submit_guest_cmd(ctx, args->cmd, args->cmd_size);
    if (err < 0)
        return err;

    struct vgpu_res *res = calloc(1, sizeof(*res));
    if (res == NULL)
        return _ENOMEM;
    *res = (struct vgpu_res) {
        .id = next_res_id++,
        .size = args->size,
        .blob_mem = args->blob_mem,
        .blob_flags = args->blob_flags,
        .refcount = 1,
    };
    struct virgl_renderer_resource_create_blob_args blob_args = {
        .res_handle = res->id,
        .ctx_id = ctx->id,
        .blob_mem = args->blob_mem,
        .blob_flags = args->blob_flags,
        .blob_id = args->blob_id,
        .size = args->size,
    };
    pthread_mutex_lock(&renderer_lock);
    err = virgl_renderer_resource_create_blob(&blob_args);
    if (!err)
        virgl_renderer_ctx_attach_resource(ctx->id, res->id);
    pthread_mutex_unlock(&renderer_lock);
    if (err) {
        VGPU_DEBUG("create_blob(size %llu, flags %#x, id %llu) failed: %d\n",
                (unsigned long long) args->size, args->blob_flags,
                (unsigned long long) args->blob_id, err);
        free(res);
        return _EINVAL;
    }
    uint32_t handle = file_add_handle(file, res);
    if (handle == 0) {
        res_release(res);
        return _ENOMEM;
    }
    VGPU_DEBUG("blob res %u handle %u size %llu flags %#x id %llu cmd %u\n", res->id, handle,
            (unsigned long long) args->size, args->blob_flags, (unsigned long long) args->blob_id, args->cmd_size);
    args->bo_handle = handle;
    args->res_handle = res->id;
    return 0;
}

static int ioctl_gem_close(struct vgpu_file *file, struct drm_gem_close_ *args) {
    struct vgpu_res *res = file_get_res(file, args->handle);
    if (res == NULL)
        return _EINVAL;
    file->handles[args->handle - 1] = NULL;
    if (file->ctx != NULL) {
        pthread_mutex_lock(&renderer_lock);
        virgl_renderer_ctx_detach_resource(file->ctx->id, res->id);
        pthread_mutex_unlock(&renderer_lock);
    }
    res_release(res);
    return 0;
}

static int ioctl_prime_handle_to_fd(struct vgpu_file *file, struct drm_prime_handle_ *args) {
    struct vgpu_res *res = file_get_res(file, args->handle);
    if (res == NULL)
        return _ENOENT;
    struct vgpu_prime *prime = malloc(sizeof(*prime));
    if (prime == NULL)
        return _ENOMEM;
    struct fd *fd = adhoc_fd_create(&virtgpu_prime_ops);
    if (fd == NULL) {
        free(prime);
        return _ENOMEM;
    }
    res->refcount++;
    prime->res = res;
    fd->data = prime;
    int f = f_install(fd, args->flags & DRM_CLOEXEC_);
    if (f < 0)
        return f;
    args->fd = f;
    return 0;
}

static int ioctl_prime_fd_to_handle(struct vgpu_file *file, struct drm_prime_handle_ *args) {
    struct fd *fd = f_get(args->fd);
    if (fd == NULL)
        return _EBADF;
    if (fd->ops != &virtgpu_prime_ops)
        return _EINVAL;
    struct vgpu_res *res = ((struct vgpu_prime *) fd->data)->res;
    for (uint32_t i = 0; i < file->handles_cap; i++) {
        if (file->handles[i] == res) {
            args->handle = i + 1;
            return 0;
        }
    }
    uint32_t handle = file_add_handle(file, res);
    if (handle == 0)
        return _ENOMEM;
    res->refcount++;
    if (file->ctx != NULL) {
        pthread_mutex_lock(&renderer_lock);
        virgl_renderer_ctx_attach_resource(file->ctx->id, res->id);
        pthread_mutex_unlock(&renderer_lock);
    }
    args->handle = handle;
    return 0;
}

static ssize_t virtgpu_ioctl_size(int cmd) {
    if (IOC_TYPE(cmd) != DRM_IOCTL_TYPE)
        return -1;
    return IOC_SIZE(cmd);
}

static int virtgpu_ioctl_locked(struct vgpu_file *file, int cmd, void *arg) {
    size_t size = IOC_SIZE(cmd);
    // Newer userspace may pass a longer struct than we know, older a shorter
    // one; work on a zero-extended local copy of the known part.
    union {
        struct drm_version_ version;
        struct drm_gem_close_ gem_close;
        struct drm_get_cap_ get_cap;
        struct drm_prime_handle_ prime;
        struct drm_virtgpu_map_ map;
        struct drm_virtgpu_execbuffer_ execbuffer;
        struct drm_virtgpu_getparam_ getparam;
        struct drm_virtgpu_resource_info_ info;
        struct drm_virtgpu_get_caps_ get_caps;
        struct drm_virtgpu_resource_create_blob_ create_blob;
        struct drm_virtgpu_context_init_ context_init;
    } a = {};
    size_t copy = size < sizeof(a) ? size : sizeof(a);
    memcpy(&a, arg, copy);

    int err;
    unsigned nr = IOC_NR(cmd);
    switch (nr) {
        case DRM_NR_VERSION:
            err = ioctl_version(&a.version);
            break;
        case DRM_NR_GEM_CLOSE:
            err = ioctl_gem_close(file, &a.gem_close);
            break;
        case DRM_NR_GET_CAP:
            a.get_cap.value = a.get_cap.capability == DRM_CAP_PRIME_ ?
                DRM_PRIME_CAP_IMPORT_ | DRM_PRIME_CAP_EXPORT_ : 0;
            err = 0;
            break;
        case DRM_NR_SET_CLIENT_CAP:
            err = _EINVAL;
            break;
        case DRM_NR_PRIME_HANDLE_TO_FD:
            err = ioctl_prime_handle_to_fd(file, &a.prime);
            break;
        case DRM_NR_PRIME_FD_TO_HANDLE:
            err = ioctl_prime_fd_to_handle(file, &a.prime);
            break;
        case DRM_COMMAND_BASE + VIRTGPU_NR_MAP:
            err = file_get_res(file, a.map.handle) ? 0 : _ENOENT;
            a.map.offset = (uint64_t) a.map.handle << PAGE_BITS;
            break;
        case DRM_COMMAND_BASE + VIRTGPU_NR_EXECBUFFER:
            err = ioctl_execbuffer(file, &a.execbuffer);
            break;
        case DRM_COMMAND_BASE + VIRTGPU_NR_GETPARAM:
            err = ioctl_getparam(&a.getparam);
            break;
        case DRM_COMMAND_BASE + VIRTGPU_NR_RESOURCE_INFO: {
            struct vgpu_res *res = file_get_res(file, a.info.bo_handle);
            if (res == NULL) {
                err = _ENOENT;
                break;
            }
            a.info.res_handle = res->id;
            a.info.size = res->size;
            a.info.blob_mem = res->blob_mem;
            err = 0;
            break;
        }
        case DRM_COMMAND_BASE + VIRTGPU_NR_WAIT:
            // Every blob is coherent host memory and the renderer has no
            // per-resource fences, so there is nothing to wait for.
            err = 0;
            break;
        case DRM_COMMAND_BASE + VIRTGPU_NR_GET_CAPS:
            err = ioctl_get_caps(&a.get_caps);
            break;
        case DRM_COMMAND_BASE + VIRTGPU_NR_RESOURCE_CREATE_BLOB:
            err = ioctl_create_blob(file, &a.create_blob);
            break;
        case DRM_COMMAND_BASE + VIRTGPU_NR_CONTEXT_INIT:
            err = ioctl_context_init(file, &a.context_init);
            break;
        default:
            VGPU_DEBUG("unsupported ioctl nr %#x size %zu\n", nr, size);
            return _EINVAL;
    }
    if (err == 0)
        memcpy(arg, &a, copy);
    else
        VGPU_DEBUG("ioctl nr %#x -> %d\n", nr, err);
    return err;
}

static int virtgpu_ioctl(struct fd *fd, int cmd, void *arg) {
    struct vgpu_file *file = fd->data;
    pthread_mutex_lock(&file->lock);
    int err = virtgpu_ioctl_locked(file, cmd, arg);
    pthread_mutex_unlock(&file->lock);
    return err;
}

static int virtgpu_mmap(struct fd *fd, struct mem *mem, page_t start, pages_t pages, off_t offset, int prot, int flags) {
    (void) flags;
    struct vgpu_file *file = fd->data;
    pthread_mutex_lock(&file->lock);
    struct vgpu_res *res = file_get_res(file, offset >> PAGE_BITS);
    if (res != NULL)
        res->refcount++;
    pthread_mutex_unlock(&file->lock);
    if (res == NULL)
        return _EINVAL;
    int err = map_res(res, mem, start, pages, 0, prot);
    res_release(res);
    return err;
}

static int virtgpu_open(int major, int minor, struct fd *fd) {
    (void) major;
    if (minor != DRM_RENDER_MINOR)
        return _ENXIO;
    pthread_mutex_lock(&renderer_lock);
    int err = renderer_init_locked();
    pthread_mutex_unlock(&renderer_lock);
    if (err < 0)
        return err;
    struct vgpu_file *file = calloc(1, sizeof(*file));
    if (file == NULL)
        return _ENOMEM;
    pthread_mutex_init(&file->lock, NULL);
    fd->data = file;
    return 0;
}

static int virtgpu_close(struct fd *fd) {
    struct vgpu_file *file = fd->data;
    if (file == NULL)
        return 0;
    for (uint32_t i = 0; i < file->handles_cap; i++) {
        struct vgpu_res *res = file->handles[i];
        if (res == NULL)
            continue;
        if (file->ctx != NULL) {
            pthread_mutex_lock(&renderer_lock);
            virgl_renderer_ctx_detach_resource(file->ctx->id, res->id);
            pthread_mutex_unlock(&renderer_lock);
        }
        res_release(res);
    }
    free(file->handles);
    if (file->ctx != NULL)
        ctx_release(file->ctx);
    pthread_mutex_destroy(&file->lock);
    free(file);
    fd->data = NULL;
    return 0;
}

struct dev_ops virtgpu_dev = {
    .open = virtgpu_open,
    .fd.ioctl_size = virtgpu_ioctl_size,
    .fd.ioctl = virtgpu_ioctl,
    .fd.mmap = virtgpu_mmap,
    .fd.close = virtgpu_close,
};

// --- device node and sysfs ---

static void write_file(const char *path, const char *contents) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0444);
    if (IS_ERR(fd))
        return;
    fd->ops->write(fd, contents, strlen(contents));
    fd_close(fd);
}

void virtgpu_create_nodes(void) {
    const char *debug = getenv("ISH_VIRTGPU_DEBUG");
    debug_enabled = debug != NULL && *debug != '\0' && *debug != '0';

    generic_mkdirat(AT_PWD, "/dev/dri", 0755);
    generic_mknodat(AT_PWD, "/dev/dri/renderD128", S_IFCHR | 0666, dev_make(DRM_MAJOR, DRM_RENDER_MINOR));

    // libdrm's drmGetDevices2 walks /sys/dev/char/<maj>:<min>/device to
    // classify the node; a platform device needs only uevent and subsystem.
    static const char *dirs[] = {
        "/sys", "/sys/bus", "/sys/bus/platform", "/sys/dev", "/sys/dev/char",
        "/sys/devices", "/sys/devices/platform", "/sys/devices/platform/virtio-gpu",
        "/sys/devices/platform/virtio-gpu/drm",
        "/sys/devices/platform/virtio-gpu/drm/renderD128",
    };
    for (unsigned i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++)
        generic_mkdirat(AT_PWD, dirs[i], 0755);
    generic_symlinkat("../../../bus/platform", AT_PWD, "/sys/devices/platform/virtio-gpu/subsystem");
    generic_symlinkat("../../../virtio-gpu", AT_PWD, "/sys/devices/platform/virtio-gpu/drm/renderD128/device");
    generic_symlinkat("../../devices/platform/virtio-gpu/drm/renderD128", AT_PWD, "/sys/dev/char/226:128");
    write_file("/sys/devices/platform/virtio-gpu/uevent",
            "DRIVER=virtio_gpu\n"
            "OF_FULLNAME=/virtio-gpu\n"
            "OF_COMPATIBLE_N=1\n"
            "OF_COMPATIBLE_0=virtio,gpu\n"
            "MODALIAS=of:Nvirtio-gpuT(null)Cvirtio,gpu\n");
    write_file("/sys/devices/platform/virtio-gpu/drm/renderD128/uevent",
            "MAJOR=226\nMINOR=128\nDEVNAME=dri/renderD128\nDEVTYPE=drm_minor\n");
}
