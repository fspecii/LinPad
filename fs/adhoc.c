#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "debug.h"
#include "kernel/fs.h"
#include "fs/fd.h"
#include "kernel/errno.h"
#include "fs/real.h"
#include "fs/dev.h"
#include "fs/devices.h"

static struct mount adhoc_mount;

struct fd *adhoc_fd_create(const struct fd_ops *ops) {
    struct fd *fd = fd_create(ops);
    if (fd == NULL)
        return NULL;
    mount_retain(&adhoc_mount);
    fd->mount = &adhoc_mount;
    fd->stat = (struct statbuf) {};
    // every anonymous file gets its own inode number, as on Linux
    static _Atomic ino_t next_inode = 1;
    fd->stat.inode = next_inode++;
    fd->stat.mode = 0600;
    fd->stat.dev = 0xd; // anon_inodefs-like device
    fd->anon_name = "[unknown]";
    return fd;
}

// Populate stat from the host fd so guest fstat() returns valid metadata.
// Node.js (libuv) calls fstat on stdout/stderr to decide whether it is a TTY,
// pipe or file; with no file type it picks a stream that discards everything
// (console.log printed nothing).
void adhoc_stat_from_host(struct fd *fd) {
    struct stat real_stat;
    if (fd->real_fd < 0 || fstat(fd->real_fd, &real_stat) < 0)
        return;
    fd->stat.mode = real_stat.st_mode;
    fd->stat.rdev = dev_fake_from_real(real_stat.st_rdev);
    fd->stat.inode = real_stat.st_ino;
    fd->stat.size = real_stat.st_size;
    // On macOS, piped/redirected fds may appear as sockets (S_IFSOCK).
    // Guest programs (especially Node.js/libuv) don't recognize sockets
    // as valid stdio types and fail to initialize stdout/stderr handles.
    // Report sockets as character devices (S_IFCHR) which is what Linux
    // shows for TTY fds. This allows node's libuv uv_guess_handle() to
    // detect them as TTY-like (when combined with isatty/TCGETS support)
    // or fall back to a generic stream.
    if (S_ISSOCK(fd->stat.mode) || isatty(fd->real_fd)) {
        fd->stat.mode = S_IFCHR | 0620;
        fd->stat.rdev = dev_make(TTY_PSEUDO_SLAVE_MAJOR, 0);
    }
}

static int adhoc_fstat(struct fd *fd, struct statbuf *stat) {
    // A host fd wrapped by an embedder (the iOS app's command executor wraps
    // its pipes like this) without filling in the stat: take the host's.
    if ((fd->stat.mode & S_IFMT) == 0 && fd->ops == &realfs_fdops)
        adhoc_stat_from_host(fd);
    *stat = fd->stat;
    return 0;
}

static int adhoc_fsetattr(struct fd *fd, struct attr attr) {
    switch (attr.type) {
        case attr_uid:
            fd->stat.uid = attr.uid;
            break;
        case attr_gid:
            fd->stat.gid = attr.gid;
            break;
        case attr_mode:
            fd->stat.mode = (fd->stat.mode & S_IFMT) | (attr.mode & ~S_IFMT);
            break;
        case attr_size:
            return _EINVAL;
    }
    return 0;
}

static int adhoc_getpath(struct fd *fd, char *buf) {
    // the targets of /proc/<pid>/fd/<n> links, as Linux prints them
    if (S_ISSOCK(fd->stat.mode))
        sprintf(buf, "socket:[%lu]", (unsigned long) fd->stat.inode);
    else if (S_ISFIFO(fd->stat.mode))
        sprintf(buf, "pipe:[%lu]", (unsigned long) fd->stat.inode);
    else
        sprintf(buf, "anon_inode:%s", fd->anon_name);
    return 0;
}

bool is_adhoc_fd(struct fd *fd) {
    return fd->mount == &adhoc_mount;
}

static const struct fs_ops adhoc_fs = {
    .magic = 0x09041934, // FIXME wrong for pipes and sockets
    .fstat = adhoc_fstat,
    .fsetattr = adhoc_fsetattr,
    .getpath = adhoc_getpath,
};

static struct mount adhoc_mount = {
    .fs = &adhoc_fs,
    .point = "",
};
