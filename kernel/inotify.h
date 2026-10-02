#ifndef KERNEL_INOTIFY_H
#define KERNEL_INOTIFY_H
#include <stdbool.h>
#include <stdint.h>

// inotify event masks (Linux values)
#define IN_ACCESS_        0x00000001
#define IN_MODIFY_        0x00000002
#define IN_ATTRIB_        0x00000004
#define IN_CLOSE_WRITE_   0x00000008
#define IN_CLOSE_NOWRITE_ 0x00000010
#define IN_OPEN_          0x00000020
#define IN_MOVED_FROM_    0x00000040
#define IN_MOVED_TO_      0x00000080
#define IN_CREATE_        0x00000100
#define IN_DELETE_        0x00000200
#define IN_DELETE_SELF_   0x00000400
#define IN_MOVE_SELF_     0x00000800
#define IN_UNMOUNT_       0x00002000
#define IN_Q_OVERFLOW_    0x00004000
#define IN_IGNORED_       0x00008000
#define IN_ONLYDIR_       0x01000000
#define IN_DONT_FOLLOW_   0x02000000
#define IN_EXCL_UNLINK_   0x04000000
#define IN_MASK_CREATE_   0x10000000
#define IN_MASK_ADD_      0x20000000
#define IN_ISDIR_         0x40000000
#define IN_ONESHOT_       0x80000000
#define IN_ALL_EVENTS_    0x00000fff

// Nonzero while any inotify watch exists; hooks check it before doing work.
extern _Atomic int inotify_watch_count;
// Union of all watch masks, so hooks can skip events nobody asked for.
extern _Atomic uint32_t inotify_mask_union;

static inline bool inotify_wants(uint32_t mask) {
    return inotify_watch_count != 0 && (inotify_mask_union & mask);
}

// Hooks for the guest's own filesystem operations. Paths are absolute
// guest paths (mount point included).
void fsnotify_create(const char *path, bool isdir);
void fsnotify_delete(const char *path, bool isdir);
void fsnotify_move(const char *old_path, const char *new_path, bool isdir);
void fsnotify_path(const char *path, uint32_t mask);
void fsnotify_path_isdir(const char *path, uint32_t mask, bool isdir);
struct fd;
void fsnotify_fd(struct fd *fd, uint32_t mask);

#endif
