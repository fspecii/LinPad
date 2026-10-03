// V4L2 capture devices backed by host cameras (see fs/dev_video.h).
//
// Only what capture applications need: one camera input, YUYV and NV12 at a
// few discrete sizes, MMAP streaming I/O and poll. Buffers live in host memory
// owned by the camera; each guest mmap gets its own host alias of the buffer
// (pt_map owns and eventually unmaps the alias), so guest mappings stay valid
// even after the buffers are freed on the kernel side.

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif

#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/dev_video.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/poll.h"
#include "util/sync.h"

// --- uAPI (include/uapi/linux/videodev2.h), aarch64 layout ---

#define V4L2_IOCTL_TYPE 'V'
#define IOC_NR(cmd) ((cmd) & 0xff)
#define IOC_TYPE(cmd) (((cmd) >> 8) & 0xff)
#define IOC_SIZE(cmd) (((cmd) >> 16) & 0x3fff)

#define VIDIOC_NR_QUERYCAP 0
#define VIDIOC_NR_ENUM_FMT 2
#define VIDIOC_NR_G_FMT 4
#define VIDIOC_NR_S_FMT 5
#define VIDIOC_NR_REQBUFS 8
#define VIDIOC_NR_QUERYBUF 9
#define VIDIOC_NR_QBUF 15
#define VIDIOC_NR_DQBUF 17
#define VIDIOC_NR_STREAMON 18
#define VIDIOC_NR_STREAMOFF 19
#define VIDIOC_NR_G_PARM 21
#define VIDIOC_NR_S_PARM 22
#define VIDIOC_NR_ENUMINPUT 26
#define VIDIOC_NR_G_INPUT 38
#define VIDIOC_NR_S_INPUT 39
#define VIDIOC_NR_TRY_FMT 64
#define VIDIOC_NR_G_PRIORITY 67
#define VIDIOC_NR_S_PRIORITY 68
#define VIDIOC_NR_ENUM_FRAMESIZES 74
#define VIDIOC_NR_ENUM_FRAMEINTERVALS 75

struct v4l2_capability_ {
    char driver[16];
    char card[32];
    char bus_info[32];
    uint32_t version;
    uint32_t capabilities;
    uint32_t device_caps;
    uint32_t reserved[3];
};

struct v4l2_fmtdesc_ {
    uint32_t index;
    uint32_t type;
    uint32_t flags;
    char description[32];
    uint32_t pixelformat;
    uint32_t mbus_code;
    uint32_t reserved[3];
};

struct v4l2_pix_format_ {
    uint32_t width;
    uint32_t height;
    uint32_t pixelformat;
    uint32_t field;
    uint32_t bytesperline;
    uint32_t sizeimage;
    uint32_t colorspace;
    uint32_t priv;
    uint32_t flags;
    uint32_t ycbcr_enc;
    uint32_t quantization;
    uint32_t xfer_func;
};

// The kernel union also holds struct v4l2_window, which has pointers, so it is
// 8-byte aligned on 64-bit.
struct v4l2_format_ {
    uint32_t type;
    uint32_t pad;
    union {
        struct v4l2_pix_format_ pix;
        uint8_t raw_data[200];
    } fmt;
};

struct v4l2_requestbuffers_ {
    uint32_t count;
    uint32_t type;
    uint32_t memory;
    uint32_t capabilities;
    uint8_t flags;
    uint8_t reserved[3];
};

struct v4l2_timecode_ {
    uint32_t type;
    uint32_t flags;
    uint8_t frames;
    uint8_t seconds;
    uint8_t minutes;
    uint8_t hours;
    uint8_t userbits[4];
};

struct v4l2_buffer_ {
    uint32_t index;
    uint32_t type;
    uint32_t bytesused;
    uint32_t flags;
    uint32_t field;
    uint32_t pad0;
    int64_t tv_sec;
    int64_t tv_usec;
    struct v4l2_timecode_ timecode;
    uint32_t sequence;
    uint32_t memory;
    uint64_t m; // offset (low 32 bits), userptr, planes or fd
    uint32_t length;
    uint32_t reserved2;
    int32_t request_fd;
    uint32_t pad1;
};

struct v4l2_fract_ {
    uint32_t numerator;
    uint32_t denominator;
};

struct v4l2_captureparm_ {
    uint32_t capability;
    uint32_t capturemode;
    struct v4l2_fract_ timeperframe;
    uint32_t extendedmode;
    uint32_t readbuffers;
    uint32_t reserved[4];
};

struct v4l2_streamparm_ {
    uint32_t type;
    union {
        struct v4l2_captureparm_ capture;
        uint8_t raw_data[200];
    } parm;
};

struct v4l2_input_ {
    uint32_t index;
    char name[32];
    uint32_t type;
    uint32_t audioset;
    uint32_t tuner;
    uint64_t std;
    uint32_t status;
    uint32_t capabilities;
    uint32_t reserved[3];
};

struct v4l2_frmsizeenum_ {
    uint32_t index;
    uint32_t pixel_format;
    uint32_t type;
    union {
        struct {
            uint32_t width;
            uint32_t height;
        } discrete;
        uint32_t stepwise[6];
    };
    uint32_t reserved[2];
};

struct v4l2_frmivalenum_ {
    uint32_t index;
    uint32_t pixel_format;
    uint32_t width;
    uint32_t height;
    uint32_t type;
    union {
        struct v4l2_fract_ discrete;
        uint32_t stepwise[6];
    };
    uint32_t reserved[2];
};

_Static_assert(sizeof(struct v4l2_capability_) == 104, "v4l2_capability");
_Static_assert(sizeof(struct v4l2_fmtdesc_) == 64, "v4l2_fmtdesc");
_Static_assert(sizeof(struct v4l2_format_) == 208, "v4l2_format");
_Static_assert(sizeof(struct v4l2_requestbuffers_) == 20, "v4l2_requestbuffers");
_Static_assert(sizeof(struct v4l2_buffer_) == 88, "v4l2_buffer");
_Static_assert(sizeof(struct v4l2_streamparm_) == 204, "v4l2_streamparm");
_Static_assert(sizeof(struct v4l2_input_) == 80, "v4l2_input");
_Static_assert(sizeof(struct v4l2_frmsizeenum_) == 44, "v4l2_frmsizeenum");
_Static_assert(sizeof(struct v4l2_frmivalenum_) == 52, "v4l2_frmivalenum");

#define FOURCC(a, b, c, d) ((uint32_t) (a) | ((uint32_t) (b) << 8) | ((uint32_t) (c) << 16) | ((uint32_t) (d) << 24))
#define V4L2_PIX_FMT_YUYV_ FOURCC('Y', 'U', 'Y', 'V')
#define V4L2_PIX_FMT_NV12_ FOURCC('N', 'V', '1', '2')

#define V4L2_BUF_TYPE_VIDEO_CAPTURE_ 1
#define V4L2_MEMORY_MMAP_ 1
#define V4L2_FIELD_NONE_ 1
#define V4L2_COLORSPACE_SMPTE170M_ 1
#define V4L2_QUANTIZATION_LIM_RANGE_ 2
#define V4L2_YCBCR_ENC_601_ 1
#define V4L2_XFER_FUNC_709_ 1

#define V4L2_CAP_VIDEO_CAPTURE_ 0x00000001
#define V4L2_CAP_EXT_PIX_FORMAT_ 0x00200000
#define V4L2_CAP_STREAMING_ 0x04000000
#define V4L2_CAP_DEVICE_CAPS_ 0x80000000
#define V4L2_CAP_TIMEPERFRAME_ 0x1000
#define V4L2_BUF_CAP_SUPPORTS_MMAP_ 0x1

#define V4L2_BUF_FLAG_MAPPED_ 0x0001
#define V4L2_BUF_FLAG_QUEUED_ 0x0002
#define V4L2_BUF_FLAG_DONE_ 0x0004
#define V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC_ 0x2000

#define V4L2_INPUT_TYPE_CAMERA_ 2
#define V4L2_FRMSIZE_TYPE_DISCRETE_ 1
#define V4L2_FRMIVAL_TYPE_DISCRETE_ 1

#define V4L2_PRIORITY_BACKGROUND_ 1
#define V4L2_PRIORITY_INTERACTIVE_ 2
#define V4L2_PRIORITY_RECORD_ 3

// --- formats ---

struct pixfmt {
    uint32_t fourcc;
    const char *description;
};
static const struct pixfmt pixfmts[] = {
    {V4L2_PIX_FMT_YUYV_, "YUYV 4:2:2"},
    {V4L2_PIX_FMT_NV12_, "Y/UV 4:2:0"},
};
#define NUM_PIXFMTS (sizeof(pixfmts) / sizeof(pixfmts[0]))

struct frame_size {
    uint32_t width;
    uint32_t height;
};
static const struct frame_size frame_sizes[] = {
    {640, 480},
    {1280, 720},
    {320, 240},
};
#define NUM_FRAME_SIZES (sizeof(frame_sizes) / sizeof(frame_sizes[0]))

static const uint32_t frame_rates[] = {30, 15};
#define NUM_FRAME_RATES (sizeof(frame_rates) / sizeof(frame_rates[0]))

static bool pixfmt_supported(uint32_t fourcc) {
    for (unsigned i = 0; i < NUM_PIXFMTS; i++)
        if (pixfmts[i].fourcc == fourcc)
            return true;
    return false;
}

static void fill_pix_format(struct v4l2_pix_format_ *pix, uint32_t width, uint32_t height, uint32_t fourcc) {
    *pix = (struct v4l2_pix_format_) {
        .width = width,
        .height = height,
        .pixelformat = fourcc,
        .field = V4L2_FIELD_NONE_,
        .colorspace = V4L2_COLORSPACE_SMPTE170M_,
        .ycbcr_enc = V4L2_YCBCR_ENC_601_,
        .quantization = V4L2_QUANTIZATION_LIM_RANGE_,
        .xfer_func = V4L2_XFER_FUNC_709_,
    };
    if (fourcc == V4L2_PIX_FMT_NV12_) {
        pix->bytesperline = width;
        pix->sizeimage = width * height * 3 / 2;
    } else {
        pix->bytesperline = width * 2;
        pix->sizeimage = width * height * 2;
    }
}

// Like a UVC camera: the closest discrete size wins.
static struct frame_size nearest_size(uint32_t width, uint32_t height) {
    struct frame_size best = frame_sizes[0];
    uint64_t best_dist = UINT64_MAX;
    for (unsigned i = 0; i < NUM_FRAME_SIZES; i++) {
        int64_t dw = (int64_t) frame_sizes[i].width - width;
        int64_t dh = (int64_t) frame_sizes[i].height - height;
        uint64_t dist = (uint64_t) (dw * dw + dh * dh);
        if (dist < best_dist) {
            best_dist = dist;
            best = frame_sizes[i];
        }
    }
    return best;
}

// --- host buffer memory ---

struct host_buf {
    uint8_t *mem;
    size_t size; // multiple of the host page size
#ifndef __APPLE__
    int fd;
#endif
};

static int host_buf_alloc(struct host_buf *buf, size_t bytes) {
    size_t size = (bytes + real_page_size - 1) / real_page_size * real_page_size;
#ifdef __APPLE__
    void *mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mem == MAP_FAILED)
        return _ENOMEM;
#else
    char path[] = "/tmp/ish-video-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        return _ENOMEM;
    unlink(path);
    if (ftruncate(fd, size) < 0) {
        close(fd);
        return _ENOMEM;
    }
    void *mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem == MAP_FAILED) {
        close(fd);
        return _ENOMEM;
    }
    buf->fd = fd;
#endif
    buf->mem = mem;
    buf->size = size;
    return 0;
}

// A second host mapping of the same pages, for the guest page table to own.
static void *host_buf_alias(struct host_buf *buf, size_t bytes) {
    size_t size = (bytes + real_page_size - 1) / real_page_size * real_page_size;
    if (size > buf->size)
        return MAP_FAILED;
#ifdef __APPLE__
    vm_address_t alias = 0;
    vm_prot_t cur, max;
    // vm_remap rather than mach_vm_remap: mach_vm.h is not in the iOS SDK.
    kern_return_t kr = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE,
            mach_task_self(), (vm_address_t) buf->mem, false, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS)
        return MAP_FAILED;
    return (void *) alias;
#else
    return mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, buf->fd, 0);
#endif
}

static void host_buf_free(struct host_buf *buf) {
    if (buf->mem == NULL)
        return;
    munmap(buf->mem, buf->size);
#ifndef __APPLE__
    close(buf->fd);
#endif
    buf->mem = NULL;
}

// --- cameras ---

#define MAX_BUFFERS 16
#define STALL_BLACK_NS 500000000ll
#define START_GRACE_NS 1500000000ll

enum buf_state { BUF_DEQUEUED, BUF_QUEUED, BUF_DONE };

struct video_buffer {
    struct host_buf host;
    enum buf_state state;
    uint32_t bytesused;
    uint32_t sequence;
    struct timespec timestamp;
};

struct fifo_ {
    uint8_t items[MAX_BUFFERS];
    unsigned head;
    unsigned count;
};

static void fifo_push(struct fifo_ *q, unsigned index) {
    q->items[(q->head + q->count++) % MAX_BUFFERS] = index;
}
static unsigned fifo_pop(struct fifo_ *q) {
    unsigned index = q->items[q->head];
    q->head = (q->head + 1) % MAX_BUFFERS;
    q->count--;
    return index;
}

struct video_file;

struct camera {
    lock_t lock;
    cond_t done_cond;
    pthread_mutex_t host_lock;
    bool host_running;
    char name[32];
    bool present;

    uint32_t width;
    uint32_t height;
    uint32_t pixelformat;
    uint32_t fps;

    unsigned prio_count[V4L2_PRIORITY_RECORD_ + 1];

    struct video_file *owner;
    struct video_buffer bufs[MAX_BUFFERS];
    unsigned nbufs;
    size_t buf_stride;
    struct fifo_ queued;
    struct fifo_ done;
    bool streaming;
    uint32_t sequence;
    int64_t last_frame_ns;

    uint32_t *xmap;
    uint32_t xmap_src;
    uint32_t xmap_dst;
    uint32_t xmap_offset;
};

struct video_file {
    struct camera *cam;
    struct fd *fd;
    uint32_t prio;
};

static struct camera cameras[VIDEO_MAX_CAMERAS];
static int camera_count;
static const struct video_host_ops *host_ops;
static void *host_ctx;

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t) ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

void video_set_host(const struct video_host_ops *ops, void *ctx, int count, const char *const names[]) {
    if (count > VIDEO_MAX_CAMERAS)
        count = VIDEO_MAX_CAMERAS;
    host_ops = ops;
    host_ctx = ctx;
    camera_count = count;
    for (int i = 0; i < VIDEO_MAX_CAMERAS; i++) {
        struct camera *cam = &cameras[i];
        lock_init(&cam->lock);
        cond_init(&cam->done_cond);
        pthread_mutex_init(&cam->host_lock, NULL);
        cam->present = i < count;
        snprintf(cam->name, sizeof(cam->name), "%s", i < count && names && names[i] ? names[i] : "Camera");
        cam->width = frame_sizes[0].width;
        cam->height = frame_sizes[0].height;
        cam->pixelformat = V4L2_PIX_FMT_YUYV_;
        cam->fps = frame_rates[0];
    }
}

// --- frame conversion (called with cam->lock held) ---

// Source columns for each destination column, for the current host -> guest size.
static const uint32_t *column_map(struct camera *cam, uint32_t offset, uint32_t src, uint32_t dst) {
    if (cam->xmap == NULL || cam->xmap_src != src || cam->xmap_dst != dst || cam->xmap_offset != offset) {
        uint32_t *map = realloc(cam->xmap, dst * sizeof(*map));
        if (map == NULL)
            return NULL;
        for (uint32_t x = 0; x < dst; x++)
            map[x] = offset + (uint32_t) ((uint64_t) x * src / dst);
        cam->xmap = map;
        cam->xmap_src = src;
        cam->xmap_dst = dst;
        cam->xmap_offset = offset;
    }
    return cam->xmap;
}

static void fill_black(struct camera *cam, uint8_t *dst) {
    size_t pixels = (size_t) cam->width * cam->height;
    if (cam->pixelformat == V4L2_PIX_FMT_NV12_) {
        memset(dst, 16, pixels);
        memset(dst + pixels, 128, pixels / 2);
    } else {
        for (size_t i = 0; i < pixels / 2; i++) {
            dst[i * 4 + 0] = 16;
            dst[i * 4 + 1] = 128;
            dst[i * 4 + 2] = 16;
            dst[i * 4 + 3] = 128;
        }
    }
}

// Host NV12 -> guest YUYV or NV12. The source is centre-cropped to the guest's
// aspect ratio (a portrait iPad delivers portrait frames) and scaled with
// nearest neighbour.
static bool convert_frame(struct camera *cam, uint8_t *dst, const struct video_host_frame *frame) {
    if (frame->format != VIDEO_HOST_NV12 || frame->width < 2 || frame->height < 2)
        return false;
    uint32_t w = cam->width, h = cam->height;
    uint32_t sw = frame->width & ~1u, sh = frame->height & ~1u;
    uint32_t cx = 0, cy = 0, cw = sw, ch = sh;
    if ((uint64_t) sw * h > (uint64_t) sh * w) {
        cw = (uint32_t) ((uint64_t) sh * w / h) & ~1u;
        cx = (sw - cw) / 2 & ~1u;
    } else if ((uint64_t) sw * h < (uint64_t) sh * w) {
        ch = (uint32_t) ((uint64_t) sw * h / w) & ~1u;
        cy = (sh - ch) / 2 & ~1u;
    }
    const uint32_t *xmap = column_map(cam, cx, cw, w);
    if (xmap == NULL)
        return false;
    const uint8_t *src_y = frame->planes[0];
    const uint8_t *src_uv = frame->planes[1];
    bool same_width = cw == w;

    if (cam->pixelformat == V4L2_PIX_FMT_NV12_) {
        uint8_t *dst_uv = dst + (size_t) w * h;
        for (uint32_t y = 0; y < h; y++) {
            const uint8_t *row = src_y + (size_t) (cy + y * ch / h) * frame->strides[0];
            uint8_t *out = dst + (size_t) y * w;
            if (same_width) {
                memcpy(out, row + cx, w);
            } else {
                for (uint32_t x = 0; x < w; x++)
                    out[x] = row[xmap[x]];
            }
        }
        for (uint32_t y = 0; y < h / 2; y++) {
            const uint8_t *row = src_uv + (size_t) ((cy + y * 2 * ch / h) / 2) * frame->strides[1];
            uint8_t *out = dst_uv + (size_t) y * w;
            if (same_width) {
                memcpy(out, row + cx, w);
            } else {
                for (uint32_t x = 0; x < w; x += 2) {
                    uint32_t sx = xmap[x] & ~1u;
                    out[x] = row[sx];
                    out[x + 1] = row[sx + 1];
                }
            }
        }
        return true;
    }

    for (uint32_t y = 0; y < h; y++) {
        uint32_t sy = cy + y * ch / h;
        const uint8_t *row_y = src_y + (size_t) sy * frame->strides[0];
        const uint8_t *row_uv = src_uv + (size_t) (sy / 2) * frame->strides[1];
        uint8_t *out = dst + (size_t) y * w * 2;
        for (uint32_t x = 0; x < w; x += 2) {
            uint32_t sx0 = xmap[x], sx1 = xmap[x + 1];
            uint32_t sc = sx0 & ~1u;
            out[x * 2 + 0] = row_y[sx0];
            out[x * 2 + 1] = row_uv[sc];
            out[x * 2 + 2] = row_y[sx1];
            out[x * 2 + 3] = row_uv[sc + 1];
        }
    }
    return true;
}

// Moves the oldest queued buffer to the done queue, filled from `frame` (or
// black). Returns the owner's fd, retained, for a poll wakeup after unlocking.
static struct fd *complete_buffer_locked(struct camera *cam, const struct video_host_frame *frame) {
    if (!cam->streaming || cam->queued.count == 0)
        return NULL;
    unsigned index = fifo_pop(&cam->queued);
    struct video_buffer *buf = &cam->bufs[index];
    if (frame == NULL || !convert_frame(cam, buf->host.mem, frame))
        fill_black(cam, buf->host.mem);
    struct v4l2_pix_format_ pix;
    fill_pix_format(&pix, cam->width, cam->height, cam->pixelformat);
    buf->bytesused = pix.sizeimage;
    buf->sequence = cam->sequence++;
    clock_gettime(CLOCK_MONOTONIC, &buf->timestamp);
    buf->state = BUF_DONE;
    fifo_push(&cam->done, index);
    notify(&cam->done_cond);
    // The owner may be mid-close (refcount already 0, waiting for this lock).
    struct fd *fd = cam->owner->fd;
    unsigned refs = atomic_load(&fd->refcount);
    while (refs != 0) {
        if (atomic_compare_exchange_weak(&fd->refcount, &refs, refs + 1))
            return fd;
    }
    return NULL;
}

static void wake_poller(struct fd *fd) {
    if (fd == NULL)
        return;
    poll_wakeup(fd, POLL_READ);
    fd_close(fd);
}

void video_host_frame(int index, const struct video_host_frame *frame) {
    if (index < 0 || index >= camera_count)
        return;
    struct camera *cam = &cameras[index];
    lock(&cam->lock);
    struct fd *fd = NULL;
    if (cam->streaming) {
        cam->last_frame_ns = now_ns();
        fd = complete_buffer_locked(cam, frame);
    }
    unlock(&cam->lock);
    wake_poller(fd);
}

// --- stall watchdog: black frames while the host delivers nothing ---

static pthread_mutex_t watchdog_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t watchdog_cond = PTHREAD_COND_INITIALIZER;
static unsigned watchdog_streams;
static bool watchdog_running;

static void *watchdog_main(void *arg) {
    (void) arg;
    pthread_setname_np("video-watchdog");
    for (;;) {
        pthread_mutex_lock(&watchdog_lock);
        while (watchdog_streams == 0)
            pthread_cond_wait(&watchdog_cond, &watchdog_lock);
        pthread_mutex_unlock(&watchdog_lock);

        uint32_t fps = 30;
        for (int i = 0; i < camera_count; i++) {
            struct camera *cam = &cameras[i];
            lock(&cam->lock);
            struct fd *fd = NULL;
            if (cam->streaming) {
                if (cam->fps < fps)
                    fps = cam->fps;
                int64_t now = now_ns();
                if (now - cam->last_frame_ns > STALL_BLACK_NS) {
                    fd = complete_buffer_locked(cam, NULL);
                    // Pace black frames at the stream's rate, not the watchdog's.
                    cam->last_frame_ns = now - STALL_BLACK_NS + 1000000000ll / cam->fps;
                }
            }
            unlock(&cam->lock);
            wake_poller(fd);
        }
        usleep(1000000 / fps / 2);
    }
    return NULL;
}

static void watchdog_add(int delta) {
    pthread_mutex_lock(&watchdog_lock);
    watchdog_streams += delta;
    if (!watchdog_running) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, watchdog_main, NULL) == 0) {
            pthread_detach(thread);
            watchdog_running = true;
        }
    }
    pthread_cond_signal(&watchdog_cond);
    pthread_mutex_unlock(&watchdog_lock);
}

// --- streaming state (cam->lock held) ---

// Returns every buffer to the dequeued state, streaming or not (as vb2 does).
// True if the stream was running.
static bool stream_off_locked(struct camera *cam) {
    bool was_streaming = cam->streaming;
    cam->streaming = false;
    cam->queued.count = cam->done.count = 0;
    for (unsigned i = 0; i < cam->nbufs; i++)
        cam->bufs[i].state = BUF_DEQUEUED;
    notify(&cam->done_cond);
    return was_streaming;
}

static void free_buffers_locked(struct camera *cam) {
    for (unsigned i = 0; i < cam->nbufs; i++)
        host_buf_free(&cam->bufs[i].host);
    cam->nbufs = 0;
    cam->buf_stride = 0;
    cam->queued.count = cam->done.count = 0;
}

// Brings the host camera in line with cam->streaming. Host calls are made
// without cam->lock (the host may deliver a frame from inside start()), and
// serialized per camera so a quick STREAMON/STREAMOFF can't reorder them.
static void host_sync(int index) {
    struct camera *cam = &cameras[index];
    pthread_mutex_lock(&cam->host_lock);
    lock(&cam->lock);
    bool want = cam->streaming;
    uint32_t width = cam->width, height = cam->height, fps = cam->fps;
    unlock(&cam->lock);
    if (want && !cam->host_running) {
        cam->host_running = true;
        watchdog_add(1);
        if (host_ops && host_ops->start)
            host_ops->start(host_ctx, index, width, height, fps);
    } else if (!want && cam->host_running) {
        cam->host_running = false;
        if (host_ops && host_ops->stop)
            host_ops->stop(host_ctx, index);
        watchdog_add(-1);
    }
    pthread_mutex_unlock(&cam->host_lock);
}

// --- ioctls ---

static int ioctl_querycap(struct camera *cam, struct v4l2_capability_ *cap) {
    memset(cap, 0, sizeof(*cap));
    strncpy(cap->driver, "ish-camera", sizeof(cap->driver) - 1);
    strncpy(cap->card, cam->name, sizeof(cap->card) - 1);
    snprintf(cap->bus_info, sizeof(cap->bus_info), "platform:ish-camera-%d", (int) (cam - cameras));
    cap->version = (6 << 16) | (6 << 8);
    cap->device_caps = V4L2_CAP_VIDEO_CAPTURE_ | V4L2_CAP_STREAMING_ | V4L2_CAP_EXT_PIX_FORMAT_;
    cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS_;
    return 0;
}

static int ioctl_enum_fmt(struct v4l2_fmtdesc_ *desc) {
    if (desc->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_ || desc->index >= NUM_PIXFMTS)
        return _EINVAL;
    uint32_t index = desc->index;
    memset(desc, 0, sizeof(*desc));
    desc->index = index;
    desc->type = V4L2_BUF_TYPE_VIDEO_CAPTURE_;
    desc->pixelformat = pixfmts[index].fourcc;
    strncpy(desc->description, pixfmts[index].description, sizeof(desc->description) - 1);
    return 0;
}

static void try_fmt(struct v4l2_format_ *f) {
    uint32_t fourcc = f->fmt.pix.pixelformat;
    if (!pixfmt_supported(fourcc))
        fourcc = V4L2_PIX_FMT_YUYV_;
    struct frame_size size = nearest_size(f->fmt.pix.width, f->fmt.pix.height);
    memset(&f->fmt, 0, sizeof(f->fmt));
    fill_pix_format(&f->fmt.pix, size.width, size.height, fourcc);
}

static int ioctl_s_fmt(struct video_file *file, struct v4l2_format_ *f) {
    struct camera *cam = file->cam;
    if (f->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_)
        return _EINVAL;
    try_fmt(f);
    if (cam->nbufs > 0 || cam->streaming) {
        // Allowed when it changes nothing, like vb2.
        if (f->fmt.pix.width == cam->width && f->fmt.pix.height == cam->height &&
                f->fmt.pix.pixelformat == cam->pixelformat)
            return 0;
        return _EBUSY;
    }
    cam->width = f->fmt.pix.width;
    cam->height = f->fmt.pix.height;
    cam->pixelformat = f->fmt.pix.pixelformat;
    return 0;
}

static int ioctl_reqbufs(struct video_file *file, struct v4l2_requestbuffers_ *req) {
    struct camera *cam = file->cam;
    if (req->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_ || req->memory != V4L2_MEMORY_MMAP_)
        return _EINVAL;
    if (cam->owner != NULL && cam->owner != file)
        return _EBUSY;
    if (cam->streaming)
        return _EBUSY;
    free_buffers_locked(cam);
    req->capabilities = V4L2_BUF_CAP_SUPPORTS_MMAP_;
    req->flags = 0;
    memset(req->reserved, 0, sizeof(req->reserved));
    if (req->count == 0) {
        cam->owner = NULL;
        return 0;
    }
    uint32_t count = req->count;
    if (count < 2)
        count = 2;
    if (count > MAX_BUFFERS)
        count = MAX_BUFFERS;
    struct v4l2_pix_format_ pix;
    fill_pix_format(&pix, cam->width, cam->height, cam->pixelformat);
    for (uint32_t i = 0; i < count; i++) {
        int err = host_buf_alloc(&cam->bufs[i].host, pix.sizeimage);
        if (err < 0) {
            free_buffers_locked(cam);
            return err;
        }
        cam->bufs[i].state = BUF_DEQUEUED;
        cam->nbufs = i + 1;
    }
    cam->buf_stride = cam->bufs[0].host.size;
    cam->owner = file;
    req->count = count;
    return 0;
}

static void fill_buffer_info(struct camera *cam, unsigned index, struct v4l2_buffer_ *b) {
    struct video_buffer *buf = &cam->bufs[index];
    struct v4l2_pix_format_ pix;
    fill_pix_format(&pix, cam->width, cam->height, cam->pixelformat);
    memset(b, 0, sizeof(*b));
    b->index = index;
    b->type = V4L2_BUF_TYPE_VIDEO_CAPTURE_;
    b->memory = V4L2_MEMORY_MMAP_;
    b->m = (uint64_t) index * cam->buf_stride;
    b->length = pix.sizeimage;
    b->field = V4L2_FIELD_NONE_;
    b->flags = V4L2_BUF_FLAG_MAPPED_ | V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC_;
    if (buf->state == BUF_QUEUED)
        b->flags |= V4L2_BUF_FLAG_QUEUED_;
    if (buf->state == BUF_DONE) {
        b->flags |= V4L2_BUF_FLAG_DONE_;
        b->bytesused = buf->bytesused;
        b->sequence = buf->sequence;
        b->tv_sec = buf->timestamp.tv_sec;
        b->tv_usec = buf->timestamp.tv_nsec / 1000;
    }
}

static int check_buffer(struct video_file *file, struct v4l2_buffer_ *b) {
    struct camera *cam = file->cam;
    if (b->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_ || b->memory != V4L2_MEMORY_MMAP_)
        return _EINVAL;
    if (cam->owner != file || b->index >= cam->nbufs)
        return _EINVAL;
    return 0;
}

static int ioctl_qbuf(struct video_file *file, struct v4l2_buffer_ *b) {
    struct camera *cam = file->cam;
    int err = check_buffer(file, b);
    if (err < 0)
        return err;
    struct video_buffer *buf = &cam->bufs[b->index];
    if (buf->state != BUF_DEQUEUED)
        return _EINVAL;
    buf->state = BUF_QUEUED;
    fifo_push(&cam->queued, b->index);
    fill_buffer_info(cam, b->index, b);
    return 0;
}

static int ioctl_dqbuf(struct video_file *file, struct v4l2_buffer_ *b) {
    struct camera *cam = file->cam;
    if (b->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_ || b->memory != V4L2_MEMORY_MMAP_)
        return _EINVAL;
    if (cam->owner != file)
        return _EINVAL;
    while (cam->done.count == 0) {
        if (!cam->streaming)
            return _EINVAL;
        if (file->fd->flags & O_NONBLOCK_)
            return _EAGAIN;
        int err = wait_for(&cam->done_cond, &cam->lock, NULL);
        if (err < 0)
            return err;
        if (cam->owner != file)
            return _EINVAL;
    }
    unsigned index = fifo_pop(&cam->done);
    fill_buffer_info(cam, index, b);
    b->flags &= ~V4L2_BUF_FLAG_DONE_;
    cam->bufs[index].state = BUF_DEQUEUED;
    return 0;
}

static int ioctl_g_parm(struct camera *cam, struct v4l2_streamparm_ *p) {
    if (p->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_)
        return _EINVAL;
    memset(&p->parm, 0, sizeof(p->parm));
    p->parm.capture.capability = V4L2_CAP_TIMEPERFRAME_;
    p->parm.capture.timeperframe = (struct v4l2_fract_) {1, cam->fps};
    p->parm.capture.readbuffers = 0;
    return 0;
}

static int ioctl_s_parm(struct camera *cam, struct v4l2_streamparm_ *p) {
    if (p->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_)
        return _EINVAL;
    struct v4l2_fract_ tpf = p->parm.capture.timeperframe;
    if (tpf.numerator != 0 && tpf.denominator != 0) {
        uint32_t wanted = tpf.denominator / tpf.numerator;
        uint32_t best = frame_rates[0];
        for (unsigned i = 0; i < NUM_FRAME_RATES; i++)
            if (frame_rates[i] <= wanted && (best > wanted || frame_rates[i] > best))
                best = frame_rates[i];
        if (best > wanted)
            best = frame_rates[NUM_FRAME_RATES - 1];
        cam->fps = best;
    }
    return ioctl_g_parm(cam, p);
}

static int ioctl_enum_framesizes(struct v4l2_frmsizeenum_ *fs) {
    if (!pixfmt_supported(fs->pixel_format) || fs->index >= NUM_FRAME_SIZES)
        return _EINVAL;
    fs->type = V4L2_FRMSIZE_TYPE_DISCRETE_;
    memset(fs->stepwise, 0, sizeof(fs->stepwise));
    fs->discrete.width = frame_sizes[fs->index].width;
    fs->discrete.height = frame_sizes[fs->index].height;
    memset(fs->reserved, 0, sizeof(fs->reserved));
    return 0;
}

static int ioctl_enum_frameintervals(struct v4l2_frmivalenum_ *fi) {
    if (!pixfmt_supported(fi->pixel_format) || fi->index >= NUM_FRAME_RATES)
        return _EINVAL;
    bool size_ok = false;
    for (unsigned i = 0; i < NUM_FRAME_SIZES; i++)
        size_ok |= frame_sizes[i].width == fi->width && frame_sizes[i].height == fi->height;
    if (!size_ok)
        return _EINVAL;
    fi->type = V4L2_FRMIVAL_TYPE_DISCRETE_;
    memset(fi->stepwise, 0, sizeof(fi->stepwise));
    fi->discrete = (struct v4l2_fract_) {1, frame_rates[fi->index]};
    memset(fi->reserved, 0, sizeof(fi->reserved));
    return 0;
}

static int ioctl_enuminput(struct camera *cam, struct v4l2_input_ *in) {
    if (in->index != 0)
        return _EINVAL;
    memset(in, 0, sizeof(*in));
    strncpy(in->name, cam->name, sizeof(in->name) - 1);
    in->type = V4L2_INPUT_TYPE_CAMERA_;
    return 0;
}

static size_t expected_size(unsigned nr) {
    switch (nr) {
        case VIDIOC_NR_QUERYCAP: return sizeof(struct v4l2_capability_);
        case VIDIOC_NR_ENUM_FMT: return sizeof(struct v4l2_fmtdesc_);
        case VIDIOC_NR_G_FMT:
        case VIDIOC_NR_S_FMT:
        case VIDIOC_NR_TRY_FMT: return sizeof(struct v4l2_format_);
        case VIDIOC_NR_REQBUFS: return sizeof(struct v4l2_requestbuffers_);
        case VIDIOC_NR_QUERYBUF:
        case VIDIOC_NR_QBUF:
        case VIDIOC_NR_DQBUF: return sizeof(struct v4l2_buffer_);
        case VIDIOC_NR_STREAMON:
        case VIDIOC_NR_STREAMOFF:
        case VIDIOC_NR_G_INPUT:
        case VIDIOC_NR_S_INPUT:
        case VIDIOC_NR_G_PRIORITY:
        case VIDIOC_NR_S_PRIORITY: return sizeof(uint32_t);
        case VIDIOC_NR_G_PARM:
        case VIDIOC_NR_S_PARM: return sizeof(struct v4l2_streamparm_);
        case VIDIOC_NR_ENUMINPUT: return sizeof(struct v4l2_input_);
        case VIDIOC_NR_ENUM_FRAMESIZES: return sizeof(struct v4l2_frmsizeenum_);
        case VIDIOC_NR_ENUM_FRAMEINTERVALS: return sizeof(struct v4l2_frmivalenum_);
    }
    return SIZE_MAX;
}

static ssize_t video_ioctl_size(int cmd) {
    if (IOC_TYPE(cmd) != V4L2_IOCTL_TYPE)
        return -1;
    size_t expected = expected_size(IOC_NR(cmd));
    // Everything else (controls, priority, standards, selection, ...) is
    // ENOTTY, which is what the V4L2 core answers for a driver without them.
    if (expected == SIZE_MAX || IOC_SIZE(cmd) != expected)
        return -1;
    return expected;
}

static uint32_t max_prio(struct camera *cam) {
    for (uint32_t p = V4L2_PRIORITY_RECORD_; p > V4L2_PRIORITY_BACKGROUND_; p--)
        if (cam->prio_count[p] > 0)
            return p;
    return V4L2_PRIORITY_INTERACTIVE_;
}

static int video_ioctl_locked(struct video_file *file, int cmd, void *arg) {
    struct camera *cam = file->cam;
    int index = (int) (cam - cameras);
    // As in the V4L2 core: a file below the highest priority may not change state.
    switch (IOC_NR(cmd)) {
        case VIDIOC_NR_S_FMT:
        case VIDIOC_NR_REQBUFS:
        case VIDIOC_NR_STREAMON:
        case VIDIOC_NR_STREAMOFF:
        case VIDIOC_NR_S_PARM:
        case VIDIOC_NR_S_INPUT:
        case VIDIOC_NR_S_PRIORITY:
            if (file->prio < max_prio(cam))
                return _EBUSY;
    }
    switch (IOC_NR(cmd)) {
        case VIDIOC_NR_G_PRIORITY:
            *(uint32_t *) arg = max_prio(cam);
            return 0;
        case VIDIOC_NR_S_PRIORITY: {
            uint32_t prio = *(uint32_t *) arg;
            if (prio < V4L2_PRIORITY_BACKGROUND_ || prio > V4L2_PRIORITY_RECORD_)
                return _EINVAL;
            cam->prio_count[file->prio]--;
            cam->prio_count[prio]++;
            file->prio = prio;
            return 0;
        }
        case VIDIOC_NR_QUERYCAP:
            return ioctl_querycap(cam, arg);
        case VIDIOC_NR_ENUM_FMT:
            return ioctl_enum_fmt(arg);
        case VIDIOC_NR_G_FMT: {
            struct v4l2_format_ *f = arg;
            if (f->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_)
                return _EINVAL;
            memset(&f->fmt, 0, sizeof(f->fmt));
            fill_pix_format(&f->fmt.pix, cam->width, cam->height, cam->pixelformat);
            return 0;
        }
        case VIDIOC_NR_TRY_FMT: {
            struct v4l2_format_ *f = arg;
            if (f->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_)
                return _EINVAL;
            try_fmt(f);
            return 0;
        }
        case VIDIOC_NR_S_FMT:
            return ioctl_s_fmt(file, arg);
        case VIDIOC_NR_REQBUFS:
            return ioctl_reqbufs(file, arg);
        case VIDIOC_NR_QUERYBUF: {
            struct v4l2_buffer_ *b = arg;
            if (b->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_ || cam->owner != file || b->index >= cam->nbufs)
                return _EINVAL;
            fill_buffer_info(cam, b->index, b);
            return 0;
        }
        case VIDIOC_NR_QBUF:
            return ioctl_qbuf(file, arg);
        case VIDIOC_NR_DQBUF:
            return ioctl_dqbuf(file, arg);
        case VIDIOC_NR_STREAMON: {
            if (*(uint32_t *) arg != V4L2_BUF_TYPE_VIDEO_CAPTURE_)
                return _EINVAL;
            if (cam->owner != file || cam->nbufs == 0)
                return _EINVAL;
            if (cam->streaming)
                return 0;
            cam->streaming = true;
            cam->sequence = 0;
            cam->last_frame_ns = now_ns() + START_GRACE_NS - STALL_BLACK_NS;
            unlock(&cam->lock);
            host_sync(index);
            lock(&cam->lock);
            return 0;
        }
        case VIDIOC_NR_STREAMOFF: {
            if (*(uint32_t *) arg != V4L2_BUF_TYPE_VIDEO_CAPTURE_)
                return _EINVAL;
            if (cam->owner != file)
                return cam->owner == NULL ? 0 : _EINVAL;
            if (stream_off_locked(cam)) {
                unlock(&cam->lock);
                host_sync(index);
                lock(&cam->lock);
            }
            return 0;
        }
        case VIDIOC_NR_G_PARM:
            return ioctl_g_parm(cam, arg);
        case VIDIOC_NR_S_PARM:
            if (cam->streaming)
                return _EBUSY;
            return ioctl_s_parm(cam, arg);
        case VIDIOC_NR_ENUMINPUT:
            return ioctl_enuminput(cam, arg);
        case VIDIOC_NR_G_INPUT:
            *(uint32_t *) arg = 0;
            return 0;
        case VIDIOC_NR_S_INPUT:
            return *(uint32_t *) arg == 0 ? 0 : _EINVAL;
        case VIDIOC_NR_ENUM_FRAMESIZES:
            return ioctl_enum_framesizes(arg);
        case VIDIOC_NR_ENUM_FRAMEINTERVALS:
            return ioctl_enum_frameintervals(arg);
    }
    return _EINVAL;
}

static int video_ioctl(struct fd *fd, int cmd, void *arg) {
    struct video_file *file = fd->data;
    lock(&file->cam->lock);
    int err = video_ioctl_locked(file, cmd, arg);
    unlock(&file->cam->lock);
    return err;
}

// No read() I/O (V4L2_CAP_READWRITE is not offered).
static ssize_t video_read(struct fd *fd, void *buf, size_t size) {
    (void) fd;
    (void) buf;
    (void) size;
    return _EINVAL;
}

static int video_poll(struct fd *fd) {
    struct video_file *file = fd->data;
    struct camera *cam = file->cam;
    int events = 0;
    lock(&cam->lock);
    if (cam->owner == file) {
        if (cam->done.count > 0)
            events |= POLL_READ;
        else if (!cam->streaming)
            events |= POLL_ERR;
    }
    unlock(&cam->lock);
    return events;
}

static int video_mmap(struct fd *fd, struct mem *mem, page_t start, pages_t pages, off_t offset, int prot, int flags) {
    struct video_file *file = fd->data;
    struct camera *cam = file->cam;
    if (!(flags & MMAP_SHARED))
        return _EINVAL;
    lock(&cam->lock);
    if (cam->buf_stride == 0 || offset < 0 || (size_t) offset % cam->buf_stride != 0 ||
            (size_t) offset / cam->buf_stride >= cam->nbufs) {
        unlock(&cam->lock);
        return _EINVAL;
    }
    struct video_buffer *buf = &cam->bufs[offset / cam->buf_stride];
    void *alias = host_buf_alias(&buf->host, (size_t) pages * PAGE_SIZE);
    unlock(&cam->lock);
    if (alias == MAP_FAILED)
        return _EINVAL;
    return pt_map(mem, start, pages, alias, 0, prot);
}

static int video_open(int major, int minor, struct fd *fd) {
    (void) major;
    if (minor < 0 || minor >= camera_count || !cameras[minor].present)
        return _ENODEV;
    struct video_file *file = calloc(1, sizeof(*file));
    if (file == NULL)
        return _ENOMEM;
    file->cam = &cameras[minor];
    file->fd = fd;
    file->prio = V4L2_PRIORITY_INTERACTIVE_;
    lock(&file->cam->lock);
    file->cam->prio_count[file->prio]++;
    unlock(&file->cam->lock);
    fd->data = file;
    return 0;
}

static int video_close(struct fd *fd) {
    struct video_file *file = fd->data;
    if (file == NULL)
        return 0;
    struct camera *cam = file->cam;
    lock(&cam->lock);
    cam->prio_count[file->prio]--;
    bool stopped = false;
    if (cam->owner == file) {
        stopped = stream_off_locked(cam);
        free_buffers_locked(cam);
        cam->owner = NULL;
    }
    unlock(&cam->lock);
    if (stopped)
        host_sync((int) (cam - cameras));
    free(file);
    fd->data = NULL;
    return 0;
}

struct dev_ops video_dev = {
    .open = video_open,
    .fd.ioctl_size = video_ioctl_size,
    .fd.ioctl = video_ioctl,
    .fd.read = video_read,
    .fd.mmap = video_mmap,
    .fd.poll = video_poll,
    .fd.close = video_close,
};

// --- device nodes and sysfs ---

static void write_file(const char *path, const char *contents) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0444);
    if (IS_ERR(fd))
        return;
    fd->ops->write(fd, contents, strlen(contents));
    fd_close(fd);
}

void video_create_nodes(void) {
    if (host_ops == NULL) {
        const char *fake = getenv("ISH_FAKECAM");
        if (fake != NULL && *fake != '\0' && *fake != '0')
            video_fake_install();
    }
    if (camera_count == 0)
        return;

    // v4l-utils classifies a node by DEVNAME in /sys/dev/char/<maj>:<min>/uevent;
    // libudev (GStreamer, PipeWire) needs the subsystem link and reads udev's
    // database entry for the capabilities.
    generic_mkdirat(AT_PWD, "/dev", 0755);
    static const char *dirs[] = {
        "/sys", "/sys/class", "/sys/class/video4linux", "/sys/dev", "/sys/dev/char",
        "/sys/bus", "/sys/bus/platform", "/sys/devices", "/sys/devices/platform",
        "/run", "/run/udev", "/run/udev/data",
    };
    for (unsigned i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++)
        generic_mkdirat(AT_PWD, dirs[i], 0755);
    for (int i = 0; i < camera_count; i++) {
        char dir[64], parent[64], path[96], contents[160];
        snprintf(path, sizeof(path), "/dev/video%d", i);
        generic_mknodat(AT_PWD, path, S_IFCHR | 0666, dev_make(VIDEO_MAJOR, i));

        snprintf(parent, sizeof(parent), "/sys/devices/platform/ish-camera.%d", i);
        generic_mkdirat(AT_PWD, parent, 0755);
        snprintf(path, sizeof(path), "%s/uevent", parent);
        write_file(path, "DRIVER=ish-camera\n");
        snprintf(path, sizeof(path), "%s/subsystem", parent);
        generic_symlinkat("../../../bus/platform", AT_PWD, path);

        snprintf(dir, sizeof(dir), "/sys/class/video4linux/video%d", i);
        generic_mkdirat(AT_PWD, dir, 0755);
        snprintf(path, sizeof(path), "%s/name", dir);
        snprintf(contents, sizeof(contents), "%s\n", cameras[i].name);
        write_file(path, contents);
        snprintf(path, sizeof(path), "%s/dev", dir);
        snprintf(contents, sizeof(contents), "%d:%d\n", VIDEO_MAJOR, i);
        write_file(path, contents);
        snprintf(path, sizeof(path), "%s/index", dir);
        write_file(path, "0\n");
        snprintf(path, sizeof(path), "%s/uevent", dir);
        snprintf(contents, sizeof(contents), "MAJOR=%d\nMINOR=%d\nDEVNAME=video%d\n", VIDEO_MAJOR, i, i);
        write_file(path, contents);
        snprintf(path, sizeof(path), "%s/subsystem", dir);
        generic_symlinkat("../../../class/video4linux", AT_PWD, path);
        snprintf(path, sizeof(path), "%s/device", dir);
        snprintf(contents, sizeof(contents), "../../../devices/platform/ish-camera.%d", i);
        generic_symlinkat(contents, AT_PWD, path);

        snprintf(path, sizeof(path), "/sys/dev/char/%d:%d", VIDEO_MAJOR, i);
        snprintf(contents, sizeof(contents), "../../class/video4linux/video%d", i);
        generic_symlinkat(contents, AT_PWD, path);

        snprintf(path, sizeof(path), "/run/udev/data/c%d:%d", VIDEO_MAJOR, i);
        snprintf(contents, sizeof(contents),
                "E:ID_V4L_VERSION=2\nE:ID_V4L_CAPABILITIES=:capture:\nE:ID_V4L_PRODUCT=%s\nG:uaccess\n",
                cameras[i].name);
        write_file(path, contents);
    }
}
