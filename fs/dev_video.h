#ifndef FS_DEV_VIDEO_H
#define FS_DEV_VIDEO_H

// Host cameras as V4L2 capture devices: /dev/video0 is the front camera (video
// calls open the first device), /dev/video1 the back one.
//
// The host side (the iOS app, or the built-in test pattern source) registers
// a provider before the first process starts. The kernel calls start() on
// VIDIOC_STREAMON and stop() on VIDIOC_STREAMOFF or close; in between the host
// pushes frames with video_host_frame() from any thread. Frames are copied
// (and converted/scaled) straight into the buffer the guest queued, so the
// host keeps ownership of its pixels.
//
// When no frame arrives for a while (camera taken by another app in Split
// View, app in the background, permission denied) the guest keeps receiving
// black frames, so its capture loop never stalls.

#include <stddef.h>
#include <stdint.h>

#define VIDEO_MAJOR 81
#define VIDEO_MAX_CAMERAS 2

enum video_host_format {
    // Two planes: Y (width x height) and interleaved CbCr (width x height/2),
    // limited (video) range BT.601, like CoreVideo's 420v.
    VIDEO_HOST_NV12 = 1,
};

struct video_host_frame {
    enum video_host_format format;
    uint32_t width;
    uint32_t height;
    const uint8_t *planes[2];
    size_t strides[2];
};

struct video_host_ops {
    // Begin delivering frames for camera `index`, ideally width x height at
    // `fps`. Called from a guest thread; must not block on user interaction
    // (ask for permission asynchronously and deliver nothing until granted).
    void (*start)(void *ctx, int index, uint32_t width, uint32_t height, uint32_t fps);
    void (*stop)(void *ctx, int index);
};

struct dev_ops;
extern struct dev_ops video_dev;

// Registers the provider and the cameras it offers (at most
// VIDEO_MAX_CAMERAS). Call before become_first_process() so the device nodes
// get created.
void video_set_host(const struct video_host_ops *ops, void *ctx, int count, const char *const names[]);

// Delivers one frame for camera `index`. Safe from any thread; frames for a
// camera that is not streaming are dropped.
void video_host_frame(int index, const struct video_host_frame *frame);

// Creates /dev/videoN and the sysfs entries for the registered cameras.
// With ISH_FAKECAM=1 and no provider, the built-in test pattern source is
// registered first.
void video_create_nodes(void);

// Built-in source: SMPTE-style colour bars with a moving block (camera 1
// mirrors the bars), used by the CLI tests and the iOS simulator.
void video_fake_install(void);

#endif
