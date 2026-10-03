// Test pattern camera source for /dev/videoN (ISH_FAKECAM=1): eight colour
// bars (white, yellow, cyan, green, magenta, red, blue, black; mirrored on
// camera 1) over the top 7/8 of the frame, and a white block moving along a
// grey band at the bottom. Frames are NV12 at the size the iOS host would
// pick for the same request (640x480 up to 640 wide, else 1280x720), so the
// scaler is exercised too. ISH_FAKECAM_SIZE=WxH forces another host size
// (480x640 imitates a portrait iPad and exercises the crop). ISH_FAKECAM=stall
// registers the cameras but never delivers a frame, like a camera taken away by
// another app, so the kernel's black-frame fallback can be tested.

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "fs/dev_video.h"

struct fake_cam {
    pthread_mutex_t lock;
    pthread_t thread;
    bool running;
    atomic_bool stop;
    uint32_t width;
    uint32_t height;
    uint32_t fps;
};

static struct fake_cam fake_cams[VIDEO_MAX_CAMERAS] = {
    {.lock = PTHREAD_MUTEX_INITIALIZER},
    {.lock = PTHREAD_MUTEX_INITIALIZER},
};

static const uint8_t bar_rgb[8][3] = {
    {255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
    {255, 0, 255}, {255, 0, 0}, {0, 0, 255}, {0, 0, 0},
};

// BT.601 limited range, the same matrix V4L2 consumers assume for YUYV/NV12.
static void rgb_to_yuv(const uint8_t rgb[3], uint8_t yuv[3]) {
    double r = rgb[0], g = rgb[1], b = rgb[2];
    yuv[0] = (uint8_t) (16 + (65.481 * r + 128.553 * g + 24.966 * b) / 255 + 0.5);
    yuv[1] = (uint8_t) (128 + (-37.797 * r - 74.203 * g + 112.0 * b) / 255 + 0.5);
    yuv[2] = (uint8_t) (128 + (112.0 * r - 93.786 * g - 18.214 * b) / 255 + 0.5);
}

static void draw(uint8_t *y_plane, uint8_t *uv_plane, uint32_t w, uint32_t h, int index, uint32_t frame) {
    uint8_t bars[8][3];
    for (int i = 0; i < 8; i++)
        rgb_to_yuv(bar_rgb[index == 1 ? 7 - i : i], bars[i]);
    uint32_t band_top = h * 7 / 8 & ~1u;
    uint32_t block = h / 8 & ~1u;
    uint32_t block_x = (frame * 8) % (w - block) & ~1u;
    for (uint32_t y = 0; y < h; y++) {
        for (uint32_t x = 0; x < w; x++) {
            uint8_t yuv[3];
            if (y < band_top) {
                memcpy(yuv, bars[x * 8 / w], 3);
            } else if (x >= block_x && x < block_x + block) {
                yuv[0] = 235, yuv[1] = 128, yuv[2] = 128;
            } else {
                yuv[0] = 64, yuv[1] = 128, yuv[2] = 128;
            }
            y_plane[(size_t) y * w + x] = yuv[0];
            if ((y & 1) == 0 && (x & 1) == 0) {
                uv_plane[(size_t) (y / 2) * w + x] = yuv[1];
                uv_plane[(size_t) (y / 2) * w + x + 1] = yuv[2];
            }
        }
    }
}

static void *fake_main(void *arg) {
    int index = (int) (intptr_t) arg;
    struct fake_cam *cam = &fake_cams[index];
    uint32_t w = cam->width, h = cam->height;
    uint8_t *pixels = malloc((size_t) w * h * 3 / 2);
    if (pixels == NULL)
        return NULL;
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    for (uint32_t frame = 0; !atomic_load(&cam->stop); frame++) {
        draw(pixels, pixels + (size_t) w * h, w, h, index, frame);
        struct video_host_frame f = {
            .format = VIDEO_HOST_NV12,
            .width = w,
            .height = h,
            .planes = {pixels, pixels + (size_t) w * h},
            .strides = {w, w},
        };
        video_host_frame(index, &f);
        next.tv_nsec += 1000000000l / cam->fps;
        if (next.tv_nsec >= 1000000000l) {
            next.tv_sec++;
            next.tv_nsec -= 1000000000l;
        }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long long wait_ns = (next.tv_sec - now.tv_sec) * 1000000000ll + (next.tv_nsec - now.tv_nsec);
        if (wait_ns > 0)
            usleep((useconds_t) (wait_ns / 1000));
        else
            next = now;
    }
    free(pixels);
    return NULL;
}

static void fake_start(void *ctx, int index, uint32_t width, uint32_t height, uint32_t fps) {
    (void) ctx;
    (void) height;
    const char *mode = getenv("ISH_FAKECAM");
    if (mode != NULL && strcmp(mode, "stall") == 0)
        return;
    struct fake_cam *cam = &fake_cams[index];
    pthread_mutex_lock(&cam->lock);
    if (!cam->running) {
        cam->width = width <= 640 ? 640 : 1280;
        cam->height = width <= 640 ? 480 : 720;
        const char *size = getenv("ISH_FAKECAM_SIZE");
        unsigned forced_w, forced_h;
        if (size != NULL && sscanf(size, "%ux%u", &forced_w, &forced_h) == 2 &&
                forced_w >= 16 && forced_h >= 16 && forced_w <= 4096 && forced_h <= 4096) {
            cam->width = forced_w & ~1u;
            cam->height = forced_h & ~1u;
        }
        cam->fps = fps ? fps : 30;
        atomic_store(&cam->stop, false);
        if (pthread_create(&cam->thread, NULL, fake_main, (void *) (intptr_t) index) == 0)
            cam->running = true;
    }
    pthread_mutex_unlock(&cam->lock);
}

static void fake_stop(void *ctx, int index) {
    (void) ctx;
    struct fake_cam *cam = &fake_cams[index];
    pthread_mutex_lock(&cam->lock);
    if (cam->running) {
        atomic_store(&cam->stop, true);
        pthread_join(cam->thread, NULL);
        cam->running = false;
    }
    pthread_mutex_unlock(&cam->lock);
}

static const struct video_host_ops fake_ops = {
    .start = fake_start,
    .stop = fake_stop,
};

void video_fake_install(void) {
    static const char *const names[] = {"Test Pattern (Back)", "Test Pattern (Front)"};
    video_set_host(&fake_ops, NULL, VIDEO_MAX_CAMERAS, names);
}
