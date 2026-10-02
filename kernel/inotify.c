// inotify, fed from two sources:
//  - the guest's own filesystem operations (fs/generic.c, fd writes and
//    closes call the fsnotify_* hooks), so events never depend on host
//    notification latency;
//  - on Darwin, a host kqueue thread watching each watched file/directory,
//    for changes made outside the guest (other processes, the Files app).
// Watches are keyed by absolute guest path, one watch descriptor per
// directory or file as on Linux. Directory contents are snapshotted so that
// a change seen from both sources is reported once.
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <pthread.h>
#include <sys/stat.h>
#if __APPLE__
#include <sys/event.h>
#endif
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/inotify.h"
#include "fs/fd.h"
#include "fs/poll.h"
#include "fs/path.h"
#include "fs/real.h"
#include "fs/fix_path.h"
#include "util/list.h"

static struct fd_ops inotify_ops;

#define IN_CLOEXEC_ O_CLOEXEC_
#define IN_NONBLOCK_ O_NONBLOCK_
#define INOTIFY_MAX_QUEUED 16384
#define INOTIFY_HASH_SIZE 4096
// host notifications for a file within this long of a guest event on it
// are taken to be the echo of that guest event
#define HOST_ECHO_NS 1000000000ULL

_Atomic int inotify_watch_count = 0;
_Atomic uint32_t inotify_mask_union = 0;

struct inotify_event_rec {
    struct list link;
    int32_t wd;
    uint32_t mask;
    uint32_t cookie;
    uint32_t len; // padded name length, as in struct inotify_event
    char name[];
};

struct inotify_instance {
    struct fd *fd;
    struct list watches;  // inotify_watch.instance_link, under inotify_lock
    struct list events;   // inotify_event_rec, under fd->lock
    unsigned nevents;
    size_t bytes;
    int next_wd;
};

struct inotify_watch {
    struct list hash_link;      // under inotify_lock
    struct list instance_link;  // under inotify_lock
    struct list all_link;       // under inotify_lock
    struct inotify_instance *in;
    int wd;
    uint32_t mask;
    char *path;
    bool isdir;
    uint64_t id;
    uint64_t last_guest_ns;
    // host side (Darwin)
    int host_fd;           // O_EVTONLY fd registered with the kqueue, or -1
    struct mount *mount;   // retained while host_fd is open
    char *host_rel;        // path relative to mount->root_fd
    char **snapshot;       // sorted entry names of a watched directory
    size_t nsnapshot;
};

static lock_t inotify_lock = LOCK_INITIALIZER;
static struct list watch_hash[INOTIFY_HASH_SIZE];
static struct list all_watches;
static bool watch_hash_ready = false;
static uint64_t next_watch_id = 1;
static _Atomic uint32_t next_cookie = 1;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static unsigned path_hash(const char *path) {
    unsigned h = 5381;
    for (const char *c = path; *c; c++)
        h = h * 33 ^ (unsigned char) *c;
    return h % INOTIFY_HASH_SIZE;
}

static void hash_init(void) {
    if (watch_hash_ready)
        return;
    for (int i = 0; i < INOTIFY_HASH_SIZE; i++)
        list_init(&watch_hash[i]);
    list_init(&all_watches);
    watch_hash_ready = true;
}

static void recompute_mask_union(void) {
    uint32_t mask = 0;
    struct inotify_watch *w;
    list_for_each_entry(&all_watches, w, all_link)
        mask |= w->mask;
    // the hooks also need these to keep watch paths and snapshots right
    inotify_mask_union = mask | IN_DELETE_SELF_ | IN_MOVE_SELF_ | IN_CREATE_ | IN_DELETE_ |
        IN_MOVED_FROM_ | IN_MOVED_TO_;
}

// Take a reference unless the fd is already being closed.
static bool fd_try_retain(struct fd *fd) {
    unsigned count = atomic_load(&fd->refcount);
    while (count != 0) {
        if (atomic_compare_exchange_weak(&fd->refcount, &count, count + 1))
            return true;
    }
    return false;
}

// Instances that got events while inotify_lock was held; woken after.
struct wake_list {
    struct fd *fds[16];
    int n;
};

static void wake_add(struct wake_list *wl, struct inotify_instance *in) {
    for (int i = 0; i < wl->n; i++)
        if (wl->fds[i] == in->fd)
            return;
    if (wl->n < 16 && fd_try_retain(in->fd))
        wl->fds[wl->n++] = in->fd;
}

static void wake_all(struct wake_list *wl) {
    for (int i = 0; i < wl->n; i++) {
        poll_wakeup(wl->fds[i], POLL_READ);
        fd_close(wl->fds[i]);
    }
    wl->n = 0;
}

static void queue_event(struct inotify_instance *in, int32_t wd, uint32_t mask, uint32_t cookie,
                        const char *name, struct wake_list *wl) {
    struct fd *fd = in->fd;
    size_t name_len = name ? strlen(name) : 0;
    uint32_t len = name_len ? (uint32_t) ((name_len + 1 + 15) & ~15) : 0;
    lock(&fd->lock);
    if (!list_empty(&in->events)) {
        // merge with an identical event still unread, as Linux does
        struct inotify_event_rec *last = list_entry(in->events.prev, struct inotify_event_rec, link);
        if (last->wd == wd && last->mask == mask && last->cookie == cookie &&
                ((name_len == 0 && last->len == 0) || (name_len && last->len && strcmp(last->name, name) == 0))) {
            unlock(&fd->lock);
            return;
        }
        if (last->mask == IN_Q_OVERFLOW_) {
            unlock(&fd->lock);
            return;
        }
    }
    if (in->nevents >= INOTIFY_MAX_QUEUED) {
        wd = -1; mask = IN_Q_OVERFLOW_; cookie = 0; len = 0; name_len = 0;
    }
    struct inotify_event_rec *ev = calloc(1, sizeof(*ev) + len);
    if (ev != NULL) {
        ev->wd = wd;
        ev->mask = mask;
        ev->cookie = cookie;
        ev->len = len;
        if (name_len)
            memcpy(ev->name, name, name_len);
        list_add_tail(&in->events, &ev->link);
        in->nevents++;
        in->bytes += 16 + len;
        notify(&fd->cond);
    }
    unlock(&fd->lock);
    wake_add(wl, in);
}

static void free_snapshot(struct inotify_watch *w) {
    for (size_t i = 0; i < w->nsnapshot; i++)
        free(w->snapshot[i]);
    free(w->snapshot);
    w->snapshot = NULL;
    w->nsnapshot = 0;
}

static int cmp_names(const void *a, const void *b) {
    return strcmp(*(char *const *) a, *(char *const *) b);
}

// Is name in the watch's directory snapshot? (only meaningful with host_fd)
static ssize_t snapshot_find(struct inotify_watch *w, const char *name) {
    size_t lo = 0, hi = w->nsnapshot;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        int c = strcmp(w->snapshot[mid], name);
        if (c == 0)
            return mid;
        if (c < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    return -1;
}

// Returns false if the name was already present (nothing changed).
static bool snapshot_add(struct inotify_watch *w, const char *name) {
    if (w->host_fd < 0)
        return true;
    if (snapshot_find(w, name) >= 0)
        return false;
    char **grown = realloc(w->snapshot, (w->nsnapshot + 1) * sizeof(char *));
    if (grown == NULL)
        return true;
    w->snapshot = grown;
    w->snapshot[w->nsnapshot++] = strdup(name);
    qsort(w->snapshot, w->nsnapshot, sizeof(char *), cmp_names);
    return true;
}

// Returns false if the name was not present (nothing changed).
static bool snapshot_remove(struct inotify_watch *w, const char *name) {
    if (w->host_fd < 0)
        return true;
    ssize_t i = snapshot_find(w, name);
    if (i < 0)
        return false;
    free(w->snapshot[i]);
    memmove(&w->snapshot[i], &w->snapshot[i + 1], (w->nsnapshot - i - 1) * sizeof(char *));
    w->nsnapshot--;
    return true;
}

static void watch_free_locked(struct inotify_watch *w) {
    list_remove(&w->hash_link);
    list_remove(&w->instance_link);
    list_remove(&w->all_link);
    if (w->host_fd >= 0)
        close(w->host_fd);
    if (w->mount != NULL)
        mount_release(w->mount);
    free(w->host_rel);
    free_snapshot(w);
    free(w->path);
    free(w);
    inotify_watch_count--;
}

static void watch_remove_locked(struct inotify_watch *w, struct wake_list *wl) {
    queue_event(w->in, w->wd, IN_IGNORED_, 0, NULL, wl);
    watch_free_locked(w);
    recompute_mask_union();
}

static void split_path(const char *path, char *parent, const char **name) {
    const char *slash = strrchr(path, '/');
    if (slash == NULL || slash == path) {
        strcpy(parent, "/");
        *name = slash ? slash + 1 : path;
    } else {
        memcpy(parent, path, slash - path);
        parent[slash - path] = '\0';
        *name = slash + 1;
    }
}

// Event on a directory entry: to watches of the directory, with the name.
static void deliver_child(const char *dir, const char *name, uint32_t mask, uint32_t cookie,
                          bool from_guest, struct wake_list *wl) {
    struct inotify_watch *w, *tmp;
    list_for_each_entry_safe(&watch_hash[path_hash(dir)], w, tmp, hash_link) {
        if (strcmp(w->path, dir) != 0)
            continue;
        uint32_t ev = mask & ~IN_ISDIR_;
        if (from_guest) {
            // keep the snapshot in step, and drop what the host already reported
            if (ev & (IN_CREATE_ | IN_MOVED_TO_)) {
                if (!snapshot_add(w, name) && ev == IN_CREATE_)
                    continue;
            } else if (ev & (IN_DELETE_ | IN_MOVED_FROM_)) {
                if (!snapshot_remove(w, name) && ev == IN_DELETE_)
                    continue;
            }
        }
        if (!(w->mask & ev))
            continue;
        queue_event(w->in, w->wd, mask, cookie, name, wl);
    }
}

// Event on the watched object itself (no name).
static void deliver_self(const char *path, uint32_t mask, bool from_guest, struct wake_list *wl) {
    struct inotify_watch *w, *tmp;
    list_for_each_entry_safe(&watch_hash[path_hash(path)], w, tmp, hash_link) {
        if (strcmp(w->path, path) != 0)
            continue;
        if (from_guest)
            w->last_guest_ns = now_ns();
        uint32_t ev = mask & ~IN_ISDIR_;
        if (w->mask & ev)
            queue_event(w->in, w->wd, mask, 0, NULL, wl);
        if ((ev & IN_DELETE_SELF_) || ((ev & w->mask) && (w->mask & IN_ONESHOT_)))
            watch_remove_locked(w, wl);
    }
}

void fsnotify_path_isdir(const char *path, uint32_t mask, bool isdir) {
    if (!inotify_wants(mask))
        return;
    char parent[MAX_PATH];
    const char *name;
    split_path(path, parent, &name);
    uint32_t flags = isdir ? IN_ISDIR_ : 0;
    struct wake_list wl = {.n = 0};
    lock(&inotify_lock);
    if (*name)
        deliver_child(parent, name, mask | flags, 0, true, &wl);
    deliver_self(path, mask | flags, true, &wl);
    unlock(&inotify_lock);
    wake_all(&wl);
}

void fsnotify_path(const char *path, uint32_t mask) {
    fsnotify_path_isdir(path, mask, false);
}

void fsnotify_create(const char *path, bool isdir) {
    if (!inotify_wants(IN_CREATE_))
        return;
    char parent[MAX_PATH];
    const char *name;
    split_path(path, parent, &name);
    struct wake_list wl = {.n = 0};
    lock(&inotify_lock);
    deliver_child(parent, name, IN_CREATE_ | (isdir ? IN_ISDIR_ : 0), 0, true, &wl);
    unlock(&inotify_lock);
    wake_all(&wl);
}

void fsnotify_delete(const char *path, bool isdir) {
    if (inotify_watch_count == 0)
        return;
    char parent[MAX_PATH];
    const char *name;
    split_path(path, parent, &name);
    struct wake_list wl = {.n = 0};
    lock(&inotify_lock);
    uint32_t flags = isdir ? IN_ISDIR_ : 0;
    if (!isdir)
        deliver_self(path, IN_ATTRIB_, true, &wl); // link count changed
    deliver_self(path, IN_DELETE_SELF_, true, &wl);
    deliver_child(parent, name, IN_DELETE_ | flags, 0, true, &wl);
    unlock(&inotify_lock);
    wake_all(&wl);
}

void fsnotify_move(const char *old_path, const char *new_path, bool isdir) {
    if (inotify_watch_count == 0)
        return;
    char old_parent[MAX_PATH], new_parent[MAX_PATH];
    const char *old_name, *new_name;
    split_path(old_path, old_parent, &old_name);
    split_path(new_path, new_parent, &new_name);
    uint32_t cookie = next_cookie++;
    if (cookie == 0)
        cookie = next_cookie++;
    uint32_t flags = isdir ? IN_ISDIR_ : 0;
    struct wake_list wl = {.n = 0};
    lock(&inotify_lock);
    // a replaced destination is deleted
    deliver_self(new_path, IN_DELETE_SELF_, true, &wl);
    deliver_child(old_parent, old_name, IN_MOVED_FROM_ | flags, cookie, true, &wl);
    deliver_child(new_parent, new_name, IN_MOVED_TO_ | flags, cookie, true, &wl);
    deliver_self(old_path, IN_MOVE_SELF_ | flags, true, &wl);
    // watches on the moved object and everything under it follow it
    size_t old_len = strlen(old_path);
    struct inotify_watch *w, *tmp;
    list_for_each_entry_safe(&all_watches, w, tmp, all_link) {
        if (strncmp(w->path, old_path, old_len) != 0 ||
                (w->path[old_len] != '\0' && w->path[old_len] != '/'))
            continue;
        char moved[MAX_PATH];
        if (snprintf(moved, sizeof(moved), "%s%s", new_path, w->path + old_len) >= (int) sizeof(moved))
            continue;
        free(w->path);
        w->path = strdup(moved);
        list_remove(&w->hash_link);
        list_add(&watch_hash[path_hash(w->path)], &w->hash_link);
    }
    unlock(&inotify_lock);
    wake_all(&wl);
}

void fsnotify_fd(struct fd *fd, uint32_t mask) {
    if (!inotify_wants(mask) || fd->mount == NULL || is_adhoc_fd(fd))
        return;
    if (fd->mount->fs->getpath == NULL)
        return;
    char path[MAX_PATH];
    if (generic_getpath(fd, path) < 0)
        return;
    fsnotify_path_isdir(path, mask, S_ISDIR(fd->type));
}

// ===== host side (Darwin kqueue) =====

#if __APPLE__
static int host_kq = -1;
static pthread_t host_thread;

static char **read_dir_names(struct inotify_watch *w, size_t *count) {
    *count = 0;
    int dfd = openat(w->mount->root_fd, fix_path(w->host_rel), O_RDONLY | O_DIRECTORY);
    if (dfd < 0)
        return NULL;
    DIR *dir = fdopendir(dfd);
    if (dir == NULL) {
        close(dfd);
        return NULL;
    }
    char **names = NULL;
    size_t n = 0, cap = 0;
    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
            continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 32;
            char **grown = realloc(names, cap * sizeof(char *));
            if (grown == NULL)
                break;
            names = grown;
        }
        names[n++] = strdup(de->d_name);
    }
    closedir(dir);
    if (n)
        qsort(names, n, sizeof(char *), cmp_names);
    *count = n;
    return names;
}

// Compare a watched directory with its snapshot and report the difference.
static void host_rescan_dir(struct inotify_watch *w, struct wake_list *wl) {
    size_t n;
    char **names = read_dir_names(w, &n);
    if (names == NULL && n == 0) {
        // unreadable or empty: compare against nothing only if it's readable
        int dfd = openat(w->mount->root_fd, fix_path(w->host_rel), O_RDONLY | O_DIRECTORY);
        if (dfd < 0)
            return;
        close(dfd);
    }
    size_t i = 0, j = 0;
    char *path = strdup(w->path);
    while (i < w->nsnapshot || j < n) {
        int c = i >= w->nsnapshot ? 1 : j >= n ? -1 : strcmp(w->snapshot[i], names[j]);
        if (c < 0) {
            deliver_child(path, w->snapshot[i], IN_DELETE_, 0, false, wl);
            i++;
        } else if (c > 0) {
            struct stat st;
            char rel[MAX_PATH];
            snprintf(rel, sizeof(rel), "%s/%s", w->host_rel, names[j]);
            bool isdir = fstatat(w->mount->root_fd, fix_path(rel), &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(st.st_mode);
            deliver_child(path, names[j], IN_CREATE_ | (isdir ? IN_ISDIR_ : 0), 0, false, wl);
            j++;
        } else {
            i++;
            j++;
        }
    }
    free(path);
    // the watch may be gone if a delivery removed it; find it again by id
    struct inotify_watch *still;
    list_for_each_entry(&all_watches, still, all_link) {
        if (still == w) {
            free_snapshot(w);
            w->snapshot = names;
            w->nsnapshot = n;
            return;
        }
    }
    for (size_t k = 0; k < n; k++)
        free(names[k]);
    free(names);
}

static void *host_watch_thread(void *UNUSED(arg)) {
    struct kevent events[64];
    for (;;) {
        int n = kevent(host_kq, NULL, 0, events, 64, NULL);
        if (n <= 0)
            continue;
        // let a burst of changes settle, then handle each watch once
        struct timespec settle = {0, 30 * 1000000};
        nanosleep(&settle, NULL);
        struct timespec zero = {0, 0};
        int more = kevent(host_kq, NULL, 0, events + n, 64 - n, &zero);
        if (more > 0)
            n += more;
        struct wake_list wl = {.n = 0};
        lock(&inotify_lock);
        for (int k = 0; k < n; k++) {
            uint64_t id = (uint64_t) (uintptr_t) events[k].udata;
            uint32_t fflags = events[k].fflags;
            struct inotify_watch *w = NULL, *it;
            list_for_each_entry(&all_watches, it, all_link) {
                if (it->id == id) {
                    w = it;
                    break;
                }
            }
            if (w == NULL)
                continue;
            if (fflags & NOTE_DELETE) {
                deliver_self(w->path, IN_DELETE_SELF_ | (w->isdir ? IN_ISDIR_ : 0), false, &wl);
                continue;
            }
            if (fflags & NOTE_RENAME) {
                queue_event(w->in, w->wd, IN_MOVE_SELF_ | (w->isdir ? IN_ISDIR_ : 0), 0, NULL, &wl);
                continue;
            }
            bool echo = now_ns() - w->last_guest_ns < HOST_ECHO_NS;
            if (w->isdir) {
                if (fflags & (NOTE_WRITE | NOTE_EXTEND | NOTE_LINK))
                    host_rescan_dir(w, &wl);
                else if ((fflags & NOTE_ATTRIB) && !echo && (w->mask & IN_ATTRIB_))
                    queue_event(w->in, w->wd, IN_ATTRIB_ | IN_ISDIR_, 0, NULL, &wl);
            } else if (!echo) {
                if ((fflags & (NOTE_WRITE | NOTE_EXTEND)) && (w->mask & IN_MODIFY_))
                    queue_event(w->in, w->wd, IN_MODIFY_, 0, NULL, &wl);
                if ((fflags & NOTE_ATTRIB) && (w->mask & IN_ATTRIB_))
                    queue_event(w->in, w->wd, IN_ATTRIB_, 0, NULL, &wl);
            }
        }
        unlock(&inotify_lock);
        wake_all(&wl);
    }
    return NULL;
}

// Watch the host file behind a guest path, if it has one. Called with inotify_lock.
static void host_watch_add(struct inotify_watch *w) {
    char rel[MAX_PATH];
    strcpy(rel, w->path);
    struct mount *mount = find_mount_and_trim_path(rel);
    if (mount->fs != &realfs && mount->root_fd <= 0) {
        mount_release(mount);
        return;
    }
    // only real-file backed mounts (fakefs, realfs) have host files
    if (mount->fs != &realfs && mount->fs != &fakefs) {
        mount_release(mount);
        return;
    }
    int fd = openat(mount->root_fd, fix_path(rel), O_EVTONLY);
    if (fd < 0) {
        mount_release(mount);
        return;
    }
    if (host_kq < 0) {
        host_kq = kqueue();
        if (host_kq < 0) {
            close(fd);
            mount_release(mount);
            return;
        }
        pthread_create(&host_thread, NULL, host_watch_thread, NULL);
        pthread_detach(host_thread);
    }
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_DELETE | NOTE_RENAME | NOTE_LINK,
           0, (void *) (uintptr_t) w->id);
    if (kevent(host_kq, &ev, 1, NULL, 0, NULL) < 0) {
        close(fd);
        mount_release(mount);
        return;
    }
    w->host_fd = fd;
    w->mount = mount;
    w->host_rel = strdup(rel);
    if (w->isdir)
        w->snapshot = read_dir_names(w, &w->nsnapshot);
}
#else
static void host_watch_add(struct inotify_watch *UNUSED(w)) {}
#endif

// ===== syscalls =====

fd_t sys_inotify_init1(int_t flags) {
    STRACE("inotify_init1(%#x)", flags);
    if (flags & ~(IN_CLOEXEC_|IN_NONBLOCK_))
        return _EINVAL;

    struct inotify_instance *in = calloc(1, sizeof(*in));
    if (in == NULL)
        return _ENOMEM;
    struct fd *fd = adhoc_fd_create(&inotify_ops);
    if (fd == NULL) {
        free(in);
        return _ENOMEM;
    }
    fd->anon_name = "inotify";
    in->fd = fd;
    list_init(&in->watches);
    list_init(&in->events);
    in->next_wd = 1;
    fd->data = in;
    return f_install(fd, flags);
}

fd_t sys_inotify_init(void) {
    return sys_inotify_init1(0);
}

int_t sys_inotify_add_watch(fd_t inotify_f, addr_t path_addr, uint_t mask) {
    char path_raw[MAX_PATH];
    if (user_read_string(path_addr, path_raw, sizeof(path_raw)))
        return _EFAULT;
    STRACE("inotify_add_watch(%d, \"%s\", %#x)", inotify_f, path_raw, mask);
    struct fd *fd = f_get(inotify_f);
    if (fd == NULL)
        return _EBADF;
    if (fd->ops != &inotify_ops)
        return _EINVAL;
    if (!(mask & IN_ALL_EVENTS_))
        return _EINVAL;
    if ((mask & IN_MASK_ADD_) && (mask & IN_MASK_CREATE_))
        return _EINVAL;
    struct inotify_instance *in = fd->data;

    char path[MAX_PATH];
    int err = path_normalize(AT_PWD, path_raw, path,
            mask & IN_DONT_FOLLOW_ ? N_SYMLINK_NOFOLLOW : N_SYMLINK_FOLLOW);
    if (err < 0)
        return err;
    struct statbuf stat;
    err = generic_statat(AT_PWD, path, &stat, !(mask & IN_DONT_FOLLOW_));
    if (err < 0)
        return err;
    bool isdir = S_ISDIR(stat.mode);
    if ((mask & IN_ONLYDIR_) && !isdir)
        return _ENOTDIR;

    lock(&inotify_lock);
    hash_init();
    struct inotify_watch *w;
    list_for_each_entry(&in->watches, w, instance_link) {
        if (strcmp(w->path, path) == 0) {
            if (mask & IN_MASK_CREATE_) {
                unlock(&inotify_lock);
                return _EEXIST;
            }
            w->mask = (mask & IN_MASK_ADD_) ? (w->mask | mask) : mask;
            recompute_mask_union();
            int wd = w->wd;
            unlock(&inotify_lock);
            return wd;
        }
    }
    w = calloc(1, sizeof(*w));
    if (w == NULL) {
        unlock(&inotify_lock);
        return _ENOMEM;
    }
    w->in = in;
    w->wd = in->next_wd++;
    w->mask = mask;
    w->path = strdup(path);
    w->isdir = isdir;
    w->id = next_watch_id++;
    w->host_fd = -1;
    list_add(&watch_hash[path_hash(path)], &w->hash_link);
    list_add_tail(&in->watches, &w->instance_link);
    list_add_tail(&all_watches, &w->all_link);
    inotify_watch_count++;
    recompute_mask_union();
    host_watch_add(w);
    int wd = w->wd;
    unlock(&inotify_lock);
    return wd;
}

int_t sys_inotify_rm_watch(fd_t inotify_f, int_t wd) {
    STRACE("inotify_rm_watch(%d, %d)", inotify_f, wd);
    struct fd *fd = f_get(inotify_f);
    if (fd == NULL)
        return _EBADF;
    if (fd->ops != &inotify_ops)
        return _EINVAL;
    struct inotify_instance *in = fd->data;
    struct wake_list wl = {.n = 0};
    lock(&inotify_lock);
    hash_init();
    struct inotify_watch *w;
    list_for_each_entry(&in->watches, w, instance_link) {
        if (w->wd == wd) {
            watch_remove_locked(w, &wl);
            unlock(&inotify_lock);
            wake_all(&wl);
            return 0;
        }
    }
    unlock(&inotify_lock);
    return _EINVAL;
}

static ssize_t inotify_read(struct fd *fd, void *buf, size_t bufsize) {
    struct inotify_instance *in = fd->data;
    lock(&fd->lock);
    while (list_empty(&in->events)) {
        if (fd->flags & O_NONBLOCK_) {
            unlock(&fd->lock);
            return _EAGAIN;
        }
        if (wait_for(&fd->cond, &fd->lock, NULL)) {
            unlock(&fd->lock);
            return _EINTR;
        }
    }
    size_t used = 0;
    while (!list_empty(&in->events)) {
        struct inotify_event_rec *ev = list_first_entry(&in->events, struct inotify_event_rec, link);
        size_t size = 16 + ev->len;
        if (used + size > bufsize)
            break;
        struct {
            int32_t wd;
            uint32_t mask;
            uint32_t cookie;
            uint32_t len;
        } header = {ev->wd, ev->mask, ev->cookie, ev->len};
        memcpy((char *) buf + used, &header, 16);
        memcpy((char *) buf + used + 16, ev->name, ev->len);
        used += size;
        list_remove(&ev->link);
        in->nevents--;
        in->bytes -= size;
        free(ev);
    }
    unlock(&fd->lock);
    if (used == 0)
        return _EINVAL; // buffer too small for the next event
    return used;
}

static int inotify_poll(struct fd *fd) {
    struct inotify_instance *in = fd->data;
    lock(&fd->lock);
    int ready = list_empty(&in->events) ? 0 : POLL_READ;
    unlock(&fd->lock);
    return ready;
}

#define FIONREAD_INOTIFY_ 0x541b
static ssize_t inotify_ioctl_size(int cmd) {
    if (cmd == FIONREAD_INOTIFY_)
        return sizeof(int32_t);
    return -1;
}

static int inotify_ioctl(struct fd *fd, int cmd, void *arg) {
    struct inotify_instance *in = fd->data;
    if (cmd != FIONREAD_INOTIFY_)
        return _ENOTTY;
    lock(&fd->lock);
    *(int32_t *) arg = (int32_t) in->bytes;
    unlock(&fd->lock);
    return 0;
}

static int inotify_close(struct fd *fd) {
    struct inotify_instance *in = fd->data;
    lock(&inotify_lock);
    hash_init();
    struct inotify_watch *w, *tmp;
    list_for_each_entry_safe(&in->watches, w, tmp, instance_link)
        watch_free_locked(w);
    recompute_mask_union();
    unlock(&inotify_lock);
    struct inotify_event_rec *ev, *etmp;
    list_for_each_entry_safe(&in->events, ev, etmp, link) {
        list_remove(&ev->link);
        free(ev);
    }
    free(in);
    return 0;
}

static struct fd_ops inotify_ops = {
    .read = inotify_read,
    .poll = inotify_poll,
    .ioctl_size = inotify_ioctl_size,
    .ioctl = inotify_ioctl,
    .close = inotify_close,
};
