#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/sysfs.h"

// /sys/devices/system/cpu, which runtimes read to size thread pools (libuv,
// Go, Chromium's base::SysInfo, glibc's get_nprocs). There is no sysfs mount,
// so the files are written into the root filesystem at boot, the way the
// virtio-gpu device nodes are; they are refreshed every boot.

static void write_file(const char *path, const char *contents) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0444);
    if (IS_ERR(fd))
        return;
    fd->ops->write(fd, contents, strlen(contents));
    fd_close(fd);
}

void sysfs_create_nodes(void) {
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (cpus < 1)
        cpus = 1;
    static const char *dirs[] = {"/sys", "/sys/devices", "/sys/devices/system", "/sys/devices/system/cpu"};
    for (unsigned i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++)
        generic_mkdirat(AT_PWD, dirs[i], 0755);

    char range[32];
    if (cpus == 1)
        snprintf(range, sizeof(range), "0\n");
    else
        snprintf(range, sizeof(range), "0-%ld\n", cpus - 1);
    write_file("/sys/devices/system/cpu/online", range);
    write_file("/sys/devices/system/cpu/possible", range);
    write_file("/sys/devices/system/cpu/present", range);
    char max[16];
    snprintf(max, sizeof(max), "%ld\n", cpus - 1);
    write_file("/sys/devices/system/cpu/kernel_max", max);
    for (long i = 0; i < cpus; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%ld", i);
        generic_mkdirat(AT_PWD, path, 0755);
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%ld/online", i);
        write_file(path, "1\n");
    }
}
