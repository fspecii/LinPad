#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <xf86drm.h>
int main(void) {
    int fd = open("/dev/dri/renderD128", O_RDWR);
    struct stat st; fstat(fd, &st);
    printf("fd %d fstat mode %o rdev %u:%u\n", fd, st.st_mode, major(st.st_rdev), minor(st.st_rdev));
    drmDevicePtr dev;
    int r = drmGetDevice2(fd, 0, &dev);
    printf("drmGetDevice2 = %d\n", r);
    if (!r) printf("bustype %d nodes %#x render %s\n", dev->bustype, dev->available_nodes, dev->nodes[DRM_NODE_RENDER]);
    drmDevicePtr devs[4]; int n = drmGetDevices2(0, devs, 4); printf("drmGetDevices2 = %d\n", n);
    char *name = drmGetDeviceNameFromFd2(fd); printf("name from fd: %s\n", name ? name : "(null)");
    return 0;
}
