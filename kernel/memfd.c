#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/fs.h"
#include "fs/fd.h"
#include "fs/real.h"

// memfd is backed by an unlinked host temp file, so guest MAP_SHARED mappings
// of it are real host shared mappings of fd->real_fd.

#define MFD_CLOEXEC_ 1
#define MFD_ALLOW_SEALING_ 2
#define MFD_NAME_MAX 249

static struct mount memfd_mount;

static int memfd_fstat(struct fd *fd, struct statbuf *stat) {
    int err = realfs_fstat(fd, stat);
    if (err < 0)
        return err;
    stat->mode = S_IFREG | (stat->mode & 07777);
    return 0;
}

static int memfd_getpath(struct fd *fd, char *buf) {
    sprintf(buf, "/memfd:%s (deleted)", (const char *) fd->data);
    return 0;
}

static int memfd_close(struct fd *fd) {
    free(fd->data);
    return 0;
}

static const struct fs_ops memfd_fs = {
    .magic = 0x01021994, // TMPFS_MAGIC
    .fstat = memfd_fstat,
    .fsetattr = realfs_fsetattr,
    .getpath = memfd_getpath,
    .close = memfd_close,
};

static struct mount memfd_mount = {
    .fs = &memfd_fs,
    .point = "",
};

static int memfd_host_file(void) {
    const char *dir = getenv("TMPDIR");
    if (dir == NULL || *dir == '\0')
        dir = "/tmp";
    char template[MAX_PATH];
    if (snprintf(template, sizeof(template), "%s/ish-memfd.XXXXXX", dir) >= (int) sizeof(template))
        return _ENAMETOOLONG;
    int real_fd = mkstemp(template);
    if (real_fd < 0)
        return errno_map();
    unlink(template);
    return real_fd;
}

fd_t sys_memfd_create(addr_t name_addr, uint_t flags) {
    char name[MFD_NAME_MAX + 1];
    if (user_read_string(name_addr, name, sizeof(name)))
        return _EFAULT;
    STRACE("memfd_create(\"%s\", %#x)", name, flags);
    if (flags & ~(MFD_CLOEXEC_ | MFD_ALLOW_SEALING_))
        return _EINVAL;

    int real_fd = memfd_host_file();
    if (real_fd < 0)
        return real_fd;
    struct fd *fd = fd_create(&realfs_fdops);
    if (fd == NULL) {
        close(real_fd);
        return _ENOMEM;
    }
    mount_retain(&memfd_mount);
    fd->mount = &memfd_mount;
    fd->real_fd = real_fd;
    fd->dir = NULL;
    fd->flags = O_RDWR_;
    fd->data = strdup(name);
    return f_install(fd, O_RDWR_ | (flags & MFD_CLOEXEC_ ? O_CLOEXEC_ : 0));
}
