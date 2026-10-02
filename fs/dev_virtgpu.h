#ifndef FS_DEV_VIRTGPU_H
#define FS_DEV_VIRTGPU_H

#include "fs/dev.h"

#define DRM_MAJOR 226
#define DRM_RENDER_MINOR 128

extern struct dev_ops virtgpu_dev;

// Creates /dev/dri/renderD128 and the sysfs entries libdrm needs to
// enumerate it. Call after the root is mounted, as the first process.
void virtgpu_create_nodes(void);

#endif
