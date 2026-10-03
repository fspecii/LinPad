// System V IPC: shared memory, semaphores and message queues.
//
// One namespace for the whole emulator. A shared memory segment is an
// unlinked host temp file, like memfd: shmat maps it MAP_SHARED, so every
// attachment (in any process, and across fork) is a real host shared mapping.
// Each shmat opens its own file description on the segment; the description
// is released when the last page of that attachment is unmapped in every
// address space (shmdt, munmap, exec, exit), which is when the attachment
// ends. A segment removed with IPC_RMID goes away after its last detach.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include "kernel/calls.h"
#include "kernel/errno.h"
#include "kernel/fs.h"
#include "kernel/ipc.h"
#include "kernel/task.h"
#include "kernel/time.h"
#include "fs/fd.h"
#include "fs/real.h"
#include "fs/proc.h"
#include "util/list.h"
#include "util/sync.h"

#define IPC_PRIVATE_ 0
#define IPC_CREAT_ 01000
#define IPC_EXCL_ 02000
#define IPC_NOWAIT_ 04000
#define IPC_RMID_ 0
#define IPC_SET_ 1
#define IPC_STAT_ 2
#define IPC_INFO_ 3
#define IPC_64_ 0x100

#define SHM_RDONLY_ 010000
#define SHM_RND_ 020000
#define SHM_REMAP_ 040000
#define SHM_EXEC_ 0100000
#define SHM_LOCK_ 11
#define SHM_UNLOCK_ 12
#define SHM_STAT_ 13
#define SHM_INFO_ 14
#define SHM_STAT_ANY_ 15
#define SHM_DEST_ 01000
#define SHM_LOCKED_ 02000
#define SHMLBA_ PAGE_SIZE

#define SEM_UNDO_ 0x1000
#define GETPID_ 11
#define GETVAL_ 12
#define GETALL_ 13
#define GETNCNT_ 14
#define GETZCNT_ 15
#define SETVAL_ 16
#define SETALL_ 17
#define SEM_STAT_ 18
#define SEM_INFO_ 19
#define SEM_STAT_ANY_ 20

#define MSG_STAT_ 11
#define MSG_INFO_ 12
#define MSG_STAT_ANY_ 13
#define MSG_NOERROR_ 010000
#define MSG_EXCEPT_ 020000
#define MSG_COPY_ 040000

// Limits (Linux defaults), shown in /proc/sys/kernel.
#define IPC_MNI 4096           // objects of each kind
#define SHMMIN 1
#define SHMMAX (~0ul - (1ul << 24))
#define SHMALL (~0ul - (1ul << 24))
#define SEMMSL 32000
#define SEMMNS 1024000000
#define SEMOPM 500
#define SEMVMX 32767
#define SEMAEM SEMVMX
#define MSGMAX 8192
#define MSGMNB 16384
#define IPC_SEQ_MULT 32768     // id = seq * IPC_SEQ_MULT + index

// guest structures (asm-generic, 64-bit)
struct ipc64_perm_ {
    int_t key;
    uint_t uid, gid, cuid, cgid;
    uint_t mode;
    uint16_t seq, pad2;
    uint64_t unused1, unused2;
};
struct shmid64_ds_ {
    struct ipc64_perm_ perm;
    uint64_t segsz;
    int64_t atime, dtime, ctime;
    int_t cpid, lpid;
    uint64_t nattch;
    uint64_t unused4, unused5;
};
struct shminfo64_ {
    uint64_t shmmax, shmmin, shmmni, shmseg, shmall, unused[4];
};
struct shm_info_ {
    int_t used_ids;
    uint64_t shm_tot, shm_rss, shm_swp, swap_attempts, swap_successes;
};
struct semid64_ds_ {
    struct ipc64_perm_ perm;
    int64_t otime, ctime;
    uint64_t nsems;
    uint64_t unused3, unused4;
};
struct seminfo_ {
    int_t semmap, semmni, semmns, semmnu, semmsl, semopm, semume, semusz, semvmx, semaem;
};
struct sembuf_ {
    uint16_t num;
    int16_t op;
    int16_t flg;
};
struct msqid64_ds_ {
    struct ipc64_perm_ perm;
    int64_t stime, rtime, ctime;
    uint64_t cbytes, qnum, qbytes;
    int_t lspid, lrpid;
    uint64_t unused4, unused5;
};
struct msginfo_ {
    int_t msgpool, msgmap, msgmax, msgmnb, msgmni, msgssz, msgtql;
    uint16_t msgseg;
};

// One lock for all of System V IPC; semaphore and message waits sleep on it.
static lock_t ipc_lock = LOCK_INITIALIZER;

struct ipc_perm {
    bool used;
    bool removed;
    int_t key;
    uint16_t seq;
    uint_t uid, gid, cuid, cgid, mode;
};

struct shm_seg {
    struct ipc_perm perm;
    size_t size;
    int real_fd;
    int64_t atime, dtime, ctime;
    pid_t_ cpid, lpid;
    struct list attachments;
};

struct shm_attach {
    struct list link;
    struct shm_seg *seg;
    struct data *data;   // the attachment's mapping, NULL until mapped
    pages_t pages;
};

struct sem_ {
    int val;
    pid_t_ pid;
    int ncnt, zcnt;
};
struct sem_set {
    struct ipc_perm perm;
    int nsems;
    struct sem_ *sems;
    int64_t otime, ctime;
    cond_t changed;
    int waiters;   // a removed set is freed when the last waiter leaves
};
// SEM_UNDO adjustments of one process for one set, applied when it exits.
struct sem_undo {
    struct list link;
    pid_t_ tgid;
    int semid;
    int nsems;
    short adj[];
};
static struct list sem_undos = {&sem_undos, &sem_undos};

struct msg {
    struct list link;
    int64_t type;
    size_t size;
    char text[];
};
struct msg_queue {
    struct ipc_perm perm;
    struct list messages;
    size_t cbytes, qnum, qbytes;
    pid_t_ lspid, lrpid;
    int64_t stime, rtime, ctime;
    cond_t changed;
    int waiters;
};

static struct shm_seg *shms[IPC_MNI];
static struct sem_set *sems[IPC_MNI];
static struct msg_queue *msqs[IPC_MNI];
static uint64_t shm_pages_total;

static int64_t now(void) {
    return time(NULL);
}

static int ipc_id(struct ipc_perm *perm, int index) {
    return perm->seq * IPC_SEQ_MULT + index;
}

// The object for an id, or NULL (EINVAL) if it does not exist or was removed.
#define IPC_LOOKUP(table, id) ({ \
    int id_ = (id); \
    typeof(table[0]) obj_ = NULL; \
    if (id_ >= 0 && id_ % IPC_SEQ_MULT < IPC_MNI) { \
        obj_ = table[id_ % IPC_SEQ_MULT]; \
        if (obj_ != NULL && (obj_->perm.removed || obj_->perm.seq != id_ / IPC_SEQ_MULT)) \
            obj_ = NULL; \
    } \
    obj_; \
})

// Index of the live object with this key, or -1.
#define IPC_FIND_KEY(table, k) ({ \
    int found_ = -1; \
    for (int i_ = 0; i_ < IPC_MNI; i_++) { \
        if (table[i_] != NULL && !table[i_]->perm.removed && table[i_]->perm.key == (k)) { \
            found_ = i_; \
            break; \
        } \
    } \
    found_; \
})

#define IPC_FREE_SLOT(table) ({ \
    int free_ = -1; \
    for (int i_ = 0; i_ < IPC_MNI; i_++) { \
        if (table[i_] == NULL) { \
            free_ = i_; \
            break; \
        } \
    } \
    free_; \
})

static uint16_t next_seq;

static void perm_init(struct ipc_perm *perm, int_t key, int flags) {
    perm->used = true;
    perm->removed = false;
    perm->key = key;
    perm->seq = next_seq++ % (0x7fffffff / IPC_SEQ_MULT);
    perm->uid = perm->cuid = current->euid;
    perm->gid = perm->cgid = current->egid;
    perm->mode = flags & 0777;
}

// Linux ipcperms: want is a mask of 4 (read) and 2 (write).
static bool ipc_allowed(struct ipc_perm *perm, int want) {
    if (superuser())
        return true;
    uint_t mode = perm->mode;
    uint_t granted;
    if (current->euid == perm->uid || current->euid == perm->cuid)
        granted = mode >> 6;
    else if (current->egid == perm->gid || current->egid == perm->cgid)
        granted = mode >> 3;
    else
        granted = mode;
    return (want & ~granted & 07) == 0;
}

static bool ipc_owner(struct ipc_perm *perm) {
    return superuser() || current->euid == perm->uid || current->euid == perm->cuid;
}

static void perm_to_user(struct ipc_perm *perm, struct ipc64_perm_ *out) {
    memset(out, 0, sizeof(*out));
    out->key = perm->removed ? IPC_PRIVATE_ : perm->key;
    out->uid = perm->uid;
    out->gid = perm->gid;
    out->cuid = perm->cuid;
    out->cgid = perm->cgid;
    out->mode = perm->mode;
    out->seq = perm->seq;
}

static int perm_set(struct ipc_perm *perm, struct ipc64_perm_ *in) {
    if (!ipc_owner(perm))
        return _EPERM;
    perm->uid = in->uid;
    perm->gid = in->gid;
    perm->mode = (perm->mode & ~0777) | (in->mode & 0777);
    return 0;
}

// get: find or create an object; create is called with ipc_lock held.
#define IPC_GET(table, key, flags, want_check, create) ({ \
    int res_; \
    if ((key) == IPC_PRIVATE_) { \
        res_ = (create); \
    } else { \
        int idx_ = IPC_FIND_KEY(table, key); \
        if (idx_ < 0) { \
            res_ = (flags) & IPC_CREAT_ ? (create) : _ENOENT; \
        } else if (((flags) & (IPC_CREAT_ | IPC_EXCL_)) == (IPC_CREAT_ | IPC_EXCL_)) { \
            res_ = _EEXIST; \
        } else { \
            res_ = want_check(table[idx_]); \
            if (res_ == 0) \
                res_ = ipc_id(&table[idx_]->perm, idx_); \
        } \
    } \
    res_; \
})

static int flags_to_want(int flags) {
    return ((flags & 0444) ? 4 : 0) | ((flags & 0222) ? 2 : 0);
}

// ---------------------------------------------------------------------------
// Shared memory
// ---------------------------------------------------------------------------

static void shm_destroy(struct shm_seg *seg, int index) {
    close(seg->real_fd);
    shm_pages_total -= PAGE_ROUND_UP(seg->size);
    shms[index] = NULL;
    free(seg);
}

// The segment with this id, also if IPC_RMID removed it but it is still attached.
static struct shm_seg *shm_by_id(int id) {
    if (id < 0 || id % IPC_SEQ_MULT >= IPC_MNI)
        return NULL;
    struct shm_seg *seg = shms[id % IPC_SEQ_MULT];
    if (seg == NULL || seg->perm.seq != id / IPC_SEQ_MULT)
        return NULL;
    return seg;
}

static int shm_index(struct shm_seg *seg) {
    for (int i = 0; i < IPC_MNI; i++)
        if (shms[i] == seg)
            return i;
    return -1;
}

static int shm_nattch(struct shm_seg *seg) {
    int n = 0;
    struct shm_attach *a;
    list_for_each_entry(&seg->attachments, a, link) {
        if (a->data == NULL) {
            n++;
            continue;
        }
        // one reference per page per address space (fork shares the mapping)
        unsigned refs = atomic_load(&a->data->refcount);
        n += (refs + a->pages - 1) / a->pages;
    }
    return n;
}

// The last page of an attachment was unmapped everywhere.
static int shm_attach_close(struct fd *fd) {
    struct shm_attach *a = fd->data;
    if (a == NULL)
        return 0;
    lock(&ipc_lock);
    struct shm_seg *seg = a->seg;
    list_remove(&a->link);
    seg->dtime = now();
    if (current != NULL)
        seg->lpid = current->tgid;
    if (seg->perm.removed && list_empty(&seg->attachments))
        shm_destroy(seg, shm_index(seg));
    unlock(&ipc_lock);
    free(a);
    fd->data = NULL;
    return 0;
}

static int shm_fstat(struct fd *fd, struct statbuf *stat) {
    int err = realfs_fstat(fd, stat);
    if (err < 0)
        return err;
    stat->mode = S_IFREG | 0600;
    return 0;
}

static int shm_getpath(struct fd *fd, char *buf) {
    struct shm_attach *a = fd->data;
    sprintf(buf, "/SYSV%08x (deleted)", a != NULL ? (unsigned) a->seg->perm.key : 0);
    return 0;
}

static const struct fs_ops shm_fs = {
    .magic = 0x01021994, // TMPFS_MAGIC
    .fstat = shm_fstat,
    .getpath = shm_getpath,
    .close = shm_attach_close,
};
static struct mount shm_mount = {
    .fs = &shm_fs,
    .point = "",
};

static int shm_host_file(size_t size) {
    const char *dir = getenv("TMPDIR");
    if (dir == NULL || *dir == '\0')
        dir = "/tmp";
    char template[MAX_PATH];
    if (snprintf(template, sizeof(template), "%s/ish-sysvshm.XXXXXX", dir) >= (int) sizeof(template))
        return _ENAMETOOLONG;
    int real_fd = mkstemp(template);
    if (real_fd < 0)
        return errno_map();
    unlink(template);
    // whole host pages, so no attached page is past EOF
    size_t host = (size + real_page_size - 1) / real_page_size * real_page_size;
    if (ftruncate(real_fd, host) < 0) {
        int err = errno_map();
        close(real_fd);
        return err;
    }
    return real_fd;
}

static int shm_create(int_t key, uint64_t size, int flags) {
    if (size < SHMMIN || size > SHMMAX)
        return _EINVAL;
    pages_t pages = PAGE_ROUND_UP(size);
    if (shm_pages_total + pages > SHMALL)
        return _ENOSPC;
    int index = IPC_FREE_SLOT(shms);
    if (index < 0)
        return _ENOSPC;
    struct shm_seg *seg = calloc(1, sizeof(*seg));
    if (seg == NULL)
        return _ENOMEM;
    int real_fd = shm_host_file(size);
    if (real_fd < 0) {
        free(seg);
        return real_fd;
    }
    perm_init(&seg->perm, key, flags);
    seg->size = size;
    seg->real_fd = real_fd;
    seg->ctime = now();
    seg->cpid = current->tgid;
    list_init(&seg->attachments);
    shms[index] = seg;
    shm_pages_total += pages;
    return ipc_id(&seg->perm, index);
}

int_t sys_shmget(int_t key, uint64_t size, int_t flags) {
    STRACE("shmget(%#x, %#llx, %#o)", key, (unsigned long long) size, flags);
    lock(&ipc_lock);
    int want = flags_to_want(flags);
#define SHM_CHECK(seg) ((seg)->size < size ? _EINVAL : !ipc_allowed(&(seg)->perm, want) ? _EACCES : 0)
    int res = IPC_GET(shms, key, flags, SHM_CHECK, shm_create(key, size, flags));
#undef SHM_CHECK
    unlock(&ipc_lock);
    return res;
}

addr_t sys_shmat(int_t id, addr_t addr, int_t flags) {
    STRACE("shmat(%d, %#llx, %#o)", id, (unsigned long long) addr, flags);
    if (addr != 0) {
        if (flags & SHM_RND_)
            addr &= ~(addr_t) (SHMLBA_ - 1);
        else if (addr & (SHMLBA_ - 1))
            return _EINVAL;
    }
    unsigned prot = P_READ;
    if (!(flags & SHM_RDONLY_))
        prot |= P_WRITE;
    if (flags & SHM_EXEC_)
        prot |= P_EXEC;

    lock(&ipc_lock);
    // A segment removed with IPC_RMID can still be attached by id until its
    // last detach, as on Linux: X11 MIT-SHM clients remove the segment right
    // after attaching it, before the X server attaches it.
    struct shm_seg *seg = shm_by_id(id);
    if (seg == NULL) {
        unlock(&ipc_lock);
        return _EINVAL;
    }
    if (!ipc_allowed(&seg->perm, prot & P_WRITE ? 6 : 4)) {
        unlock(&ipc_lock);
        return _EACCES;
    }
    struct shm_attach *a = calloc(1, sizeof(*a));
    int real_fd = a != NULL ? dup(seg->real_fd) : -1;
    struct fd *fd = real_fd >= 0 ? fd_create(&realfs_fdops) : NULL;
    if (fd == NULL) {
        if (real_fd >= 0)
            close(real_fd);
        free(a);
        unlock(&ipc_lock);
        return _ENOMEM;
    }
    a->seg = seg;
    a->pages = PAGE_ROUND_UP(seg->size);
    list_add(&seg->attachments, &a->link);
    mount_retain(&shm_mount);
    fd->mount = &shm_mount;
    fd->real_fd = real_fd;
    fd->dir = NULL;
    fd->flags = O_RDWR_;
    fd->data = a;
    size_t size = seg->size;
    unlock(&ipc_lock);

    // ipc_lock is not held here: unmapping takes it (shm_attach_close) under
    // the memory lock.
    write_wrlock(&current->mem->lock);
    addr_t res;
    if (addr != 0 && !(flags & SHM_REMAP_) && !pt_is_hole(current->mem, PAGE(addr), a->pages))
        res = _EINVAL;
    else
        res = mmap_file(addr, size, prot, MMAP_SHARED | (addr != 0 ? MMAP_FIXED : 0), fd);
    if (!IS_ERR(res))
        a->data = mem_pt(current->mem, PAGE(res))->data;
    write_wrunlock(&current->mem->lock);
    // the mapping holds its own reference to fd (none if it failed, which
    // detaches right here)
    fd_close(fd);
    if (IS_ERR(res))
        return res;

    lock(&ipc_lock);
    seg->atime = now();
    seg->lpid = current->tgid;
    unlock(&ipc_lock);
    return res;
}

int_t sys_shmdt(addr_t addr) {
    STRACE("shmdt(%#llx)", (unsigned long long) addr);
    if (addr & (SHMLBA_ - 1))
        return _EINVAL;
    write_wrlock(&current->mem->lock);
    struct pt_entry *entry = mem_pt(current->mem, PAGE(addr));
    struct data *data = entry != NULL ? entry->data : NULL;
    if (data == NULL || data->fd == NULL || data->fd->mount != &shm_mount || entry->offset != 0) {
        write_wrunlock(&current->mem->lock);
        return _EINVAL;
    }
    struct shm_attach *a = data->fd->data;
    pages_t pages = a != NULL ? a->pages : 1;
    // the pages of this attachment from addr on (some may be unmapped already)
    page_t page = PAGE(addr);
    pages_t n = 0;
    while (n < pages) {
        struct pt_entry *e = mem_pt(current->mem, page + n);
        if (e == NULL || e->data != data)
            break;
        n++;
    }
    pt_unmap_always(current->mem, page, n);
    write_wrunlock(&current->mem->lock);
    return 0;
}

static void shm_to_user(struct shm_seg *seg, struct shmid64_ds_ *ds) {
    memset(ds, 0, sizeof(*ds));
    perm_to_user(&seg->perm, &ds->perm);
    if (seg->perm.removed)
        ds->perm.mode |= SHM_DEST_;
    ds->segsz = seg->size;
    ds->atime = seg->atime;
    ds->dtime = seg->dtime;
    ds->ctime = seg->ctime;
    ds->cpid = seg->cpid;
    ds->lpid = seg->lpid;
    ds->nattch = shm_nattch(seg);
}

int_t sys_shmctl(int_t id, int_t cmd, addr_t buf) {
    STRACE("shmctl(%d, %d, %#llx)", id, cmd, (unsigned long long) buf);
    cmd &= ~IPC_64_;
    int res = 0;
    lock(&ipc_lock);
    switch (cmd) {
        case IPC_INFO_: {
            struct shminfo64_ info = {
                .shmmax = SHMMAX, .shmmin = SHMMIN, .shmmni = IPC_MNI, .shmseg = IPC_MNI, .shmall = SHMALL,
            };
            int max = -1;
            for (int i = 0; i < IPC_MNI; i++)
                if (shms[i] != NULL)
                    max = i;
            res = user_put(buf, info) ? _EFAULT : (max < 0 ? 0 : max);
            break;
        }
        case SHM_INFO_: {
            struct shm_info_ info = {};
            int max = -1;
            for (int i = 0; i < IPC_MNI; i++) {
                if (shms[i] != NULL) {
                    max = i;
                    info.used_ids++;
                    info.shm_tot += PAGE_ROUND_UP(shms[i]->size);
                    info.shm_rss += PAGE_ROUND_UP(shms[i]->size);
                }
            }
            res = user_put(buf, info) ? _EFAULT : (max < 0 ? 0 : max);
            break;
        }
        case SHM_STAT_:
        case SHM_STAT_ANY_: {
            // id is an index here; the result is the real id
            struct shm_seg *seg = id >= 0 && id < IPC_MNI ? shms[id] : NULL;
            if (seg == NULL) {
                res = _EINVAL;
                break;
            }
            if (cmd == SHM_STAT_ && !ipc_allowed(&seg->perm, 4)) {
                res = _EACCES;
                break;
            }
            struct shmid64_ds_ ds;
            shm_to_user(seg, &ds);
            res = user_put(buf, ds) ? _EFAULT : ipc_id(&seg->perm, id);
            break;
        }
        case IPC_STAT_:
        case IPC_SET_:
        case IPC_RMID_:
        case SHM_LOCK_:
        case SHM_UNLOCK_: {
            // a removed segment stays usable until its last detach
            struct shm_seg *seg = shm_by_id(id);
            if (seg == NULL) {
                res = _EINVAL;
                break;
            }
            int index = id % IPC_SEQ_MULT;
            if (cmd == IPC_STAT_) {
                if (!ipc_allowed(&seg->perm, 4)) {
                    res = _EACCES;
                    break;
                }
                struct shmid64_ds_ ds;
                shm_to_user(seg, &ds);
                if (user_put(buf, ds))
                    res = _EFAULT;
            } else if (cmd == IPC_SET_) {
                struct shmid64_ds_ ds;
                if (user_get(buf, ds)) {
                    res = _EFAULT;
                    break;
                }
                res = perm_set(&seg->perm, &ds.perm);
                if (res == 0)
                    seg->ctime = now();
            } else if (cmd == IPC_RMID_) {
                if (!ipc_owner(&seg->perm)) {
                    res = _EPERM;
                    break;
                }
                seg->perm.removed = true;
                seg->ctime = now();
                if (list_empty(&seg->attachments))
                    shm_destroy(seg, index);
            } else {
                // SHM_LOCK/SHM_UNLOCK: nothing is ever swapped out here
                if (!ipc_owner(&seg->perm))
                    res = _EPERM;
                else if (cmd == SHM_LOCK_)
                    seg->perm.mode |= SHM_LOCKED_;
                else
                    seg->perm.mode &= ~SHM_LOCKED_;
            }
            break;
        }
        default:
            res = _EINVAL;
    }
    unlock(&ipc_lock);
    return res;
}

// ---------------------------------------------------------------------------
// Semaphores
// ---------------------------------------------------------------------------

static void sem_free(struct sem_set *set) {
    cond_destroy(&set->changed);
    free(set->sems);
    free(set);
}

static void sem_undo_forget(int semid, int num) {
    struct sem_undo *u, *tmp;
    list_for_each_entry_safe(&sem_undos, u, tmp, link) {
        if (u->semid != semid)
            continue;
        if (num < 0) {
            list_remove(&u->link);
            free(u);
        } else if (num < u->nsems) {
            u->adj[num] = 0;
        }
    }
}

static void sem_remove(struct sem_set *set, int index) {
    set->perm.removed = true;
    sem_undo_forget(ipc_id(&set->perm, index), -1);
    sems[index] = NULL;
    if (set->waiters > 0)
        notify(&set->changed);   // the last waiter frees it
    else
        sem_free(set);
}

static int sem_create(int_t key, int nsems, int flags) {
    if (nsems <= 0 || nsems > SEMMSL)
        return _EINVAL;
    int index = IPC_FREE_SLOT(sems);
    if (index < 0)
        return _ENOSPC;
    struct sem_set *set = calloc(1, sizeof(*set));
    struct sem_ *s = calloc(nsems, sizeof(*s));
    if (set == NULL || s == NULL) {
        free(set);
        free(s);
        return _ENOMEM;
    }
    perm_init(&set->perm, key, flags);
    set->nsems = nsems;
    set->sems = s;
    set->ctime = now();
    cond_init(&set->changed);
    sems[index] = set;
    return ipc_id(&set->perm, index);
}

int_t sys_semget(int_t key, int_t nsems, int_t flags) {
    STRACE("semget(%#x, %d, %#o)", key, nsems, flags);
    lock(&ipc_lock);
    int want = flags_to_want(flags);
#define SEM_CHECK(set) ((set)->nsems < nsems ? _EINVAL : !ipc_allowed(&(set)->perm, want) ? _EACCES : 0)
    int res = IPC_GET(sems, key, flags, SEM_CHECK, sem_create(key, nsems, flags));
#undef SEM_CHECK
    unlock(&ipc_lock);
    return res;
}

static struct sem_undo *sem_undo_get(int semid, int nsems) {
    struct sem_undo *u;
    list_for_each_entry(&sem_undos, u, link) {
        if (u->tgid == current->tgid && u->semid == semid)
            return u;
    }
    u = calloc(1, sizeof(*u) + nsems * sizeof(u->adj[0]));
    if (u == NULL)
        return NULL;
    u->tgid = current->tgid;
    u->semid = semid;
    u->nsems = nsems;
    list_add(&sem_undos, &u->link);
    return u;
}

// Tries all operations at once. 0 if done, else the index of the first
// operation that has to wait (as a positive number + 1), or an error.
static int sem_try(struct sem_set *set, int semid, struct sembuf_ *ops, unsigned nops) {
    bool undo = false;
    // apply on a copy, in order (several operations may touch one semaphore)
    int *tmp = malloc(set->nsems * sizeof(int));
    if (tmp == NULL)
        return _ENOMEM;
    for (int i = 0; i < set->nsems; i++)
        tmp[i] = set->sems[i].val;
    for (unsigned i = 0; i < nops; i++) {
        int *v = &tmp[ops[i].num];
        if (ops[i].op > 0) {
            if (*v + ops[i].op > SEMVMX) {
                free(tmp);
                return _ERANGE;
            }
            *v += ops[i].op;
        } else if (ops[i].op < 0) {
            if (*v < -ops[i].op) {
                free(tmp);
                return i + 1;
            }
            *v += ops[i].op;
        } else if (*v != 0) {
            free(tmp);
            return i + 1;
        }
        if (ops[i].flg & SEM_UNDO_)
            undo = true;
    }
    struct sem_undo *u = NULL;
    if (undo) {
        u = sem_undo_get(semid, set->nsems);
        if (u == NULL) {
            free(tmp);
            return _ENOMEM;
        }
    }
    for (unsigned i = 0; i < nops; i++) {
        if (u != NULL && (ops[i].flg & SEM_UNDO_))
            u->adj[ops[i].num] -= ops[i].op;
        set->sems[ops[i].num].pid = current->tgid;
    }
    for (int i = 0; i < set->nsems; i++)
        set->sems[i].val = tmp[i];
    free(tmp);
    set->otime = now();
    notify(&set->changed);
    return 0;
}

static int64_t mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

static int sem_timedop(int_t id, addr_t ops_addr, uint_t nops, struct timespec *timeout) {
    if (nops == 0)
        return _EINVAL;
    if (nops > SEMOPM)
        return _E2BIG;
    struct sembuf_ ops[SEMOPM];
    if (user_read(ops_addr, ops, nops * sizeof(ops[0])))
        return _EFAULT;
    int64_t deadline = timeout != NULL ? mono_ns() + timeout->tv_sec * 1000000000ll + timeout->tv_nsec : 0;

    lock(&ipc_lock);
    struct sem_set *set = IPC_LOOKUP(sems, id);
    int res;
    if (set == NULL) {
        res = _EINVAL;
        goto out;
    }
    bool alter = false;
    for (unsigned i = 0; i < nops; i++) {
        if (ops[i].num >= set->nsems) {
            res = _EFBIG;
            goto out;
        }
        if (ops[i].op != 0)
            alter = true;
    }
    if (!ipc_allowed(&set->perm, alter ? 2 : 4)) {
        res = _EACCES;
        goto out;
    }
    for (;;) {
        res = sem_try(set, id, ops, nops);
        if (res <= 0)
            break;
        struct sembuf_ *blocked = &ops[res - 1];
        if (blocked->flg & IPC_NOWAIT_) {
            res = _EAGAIN;
            break;
        }
        struct sem_ *s = &set->sems[blocked->num];
        int *count = blocked->op == 0 ? &s->zcnt : &s->ncnt;
        struct timespec left, *wait = NULL;
        if (timeout != NULL) {
            int64_t ns = deadline - mono_ns();
            if (ns <= 0) {
                res = _EAGAIN;
                break;
            }
            left.tv_sec = ns / 1000000000;
            left.tv_nsec = ns % 1000000000;
            wait = &left;
        }
        (*count)++;
        set->waiters++;
        int err = wait_for(&set->changed, &ipc_lock, wait);
        set->waiters--;
        if (set->perm.removed) {
            if (set->waiters == 0)
                sem_free(set);
            res = _EIDRM;
            break;
        }
        (*count)--;
        if (err == _EINTR) {
            res = _EINTR;
            break;
        }
    }
out:
    unlock(&ipc_lock);
    return res;
}

int_t sys_semop(int_t id, addr_t ops, uint_t nops) {
    STRACE("semop(%d, %#llx, %u)", id, (unsigned long long) ops, nops);
    return sem_timedop(id, ops, nops, NULL);
}

int_t sys_semtimedop(int_t id, addr_t ops, uint_t nops, addr_t timeout_addr) {
    STRACE("semtimedop(%d, %#llx, %u, %#llx)", id, (unsigned long long) ops, nops, (unsigned long long) timeout_addr);
    if (timeout_addr == 0)
        return sem_timedop(id, ops, nops, NULL);
    struct timespec_ t;
    if (user_get(timeout_addr, t))
        return _EFAULT;
    if (t.nsec < 0 || t.nsec >= 1000000000 || t.sec < 0)
        return _EINVAL;
    struct timespec timeout = convert_timespec(t);
    return sem_timedop(id, ops, nops, &timeout);
}

static void sem_to_user(struct sem_set *set, struct semid64_ds_ *ds) {
    memset(ds, 0, sizeof(*ds));
    perm_to_user(&set->perm, &ds->perm);
    ds->otime = set->otime;
    ds->ctime = set->ctime;
    ds->nsems = set->nsems;
}

int_t sys_semctl(int_t id, int_t num, int_t cmd, uint64_t arg) {
    STRACE("semctl(%d, %d, %d, %#llx)", id, num, cmd, (unsigned long long) arg);
    cmd &= ~IPC_64_;
    int res = 0;
    lock(&ipc_lock);
    if (cmd == IPC_INFO_ || cmd == SEM_INFO_) {
        struct seminfo_ info = {
            .semmap = SEMMNS / SEMMSL, .semmni = IPC_MNI, .semmns = SEMMNS, .semmnu = SEMMNS,
            .semmsl = SEMMSL, .semopm = SEMOPM, .semume = SEMOPM, .semusz = 20, .semvmx = SEMVMX,
            .semaem = SEMAEM,
        };
        int max = -1;
        if (cmd == SEM_INFO_) {
            info.semusz = 0;
            info.semaem = 0;
        }
        for (int i = 0; i < IPC_MNI; i++) {
            if (sems[i] != NULL) {
                max = i;
                if (cmd == SEM_INFO_) {
                    info.semusz++;
                    info.semaem += sems[i]->nsems;
                }
            }
        }
        res = user_put(arg, info) ? _EFAULT : (max < 0 ? 0 : max);
        goto out;
    }
    if (cmd == SEM_STAT_ || cmd == SEM_STAT_ANY_) {
        struct sem_set *set = id >= 0 && id < IPC_MNI ? sems[id] : NULL;
        if (set == NULL) {
            res = _EINVAL;
        } else if (cmd == SEM_STAT_ && !ipc_allowed(&set->perm, 4)) {
            res = _EACCES;
        } else {
            struct semid64_ds_ ds;
            sem_to_user(set, &ds);
            res = user_put(arg, ds) ? _EFAULT : ipc_id(&set->perm, id);
        }
        goto out;
    }
    struct sem_set *set = IPC_LOOKUP(sems, id);
    if (set == NULL) {
        res = _EINVAL;
        goto out;
    }
    switch (cmd) {
        case IPC_STAT_: {
            if (!ipc_allowed(&set->perm, 4)) {
                res = _EACCES;
                break;
            }
            struct semid64_ds_ ds;
            sem_to_user(set, &ds);
            if (user_put(arg, ds))
                res = _EFAULT;
            break;
        }
        case IPC_SET_: {
            struct semid64_ds_ ds;
            if (user_get(arg, ds)) {
                res = _EFAULT;
                break;
            }
            res = perm_set(&set->perm, &ds.perm);
            if (res == 0)
                set->ctime = now();
            break;
        }
        case IPC_RMID_:
            if (!ipc_owner(&set->perm))
                res = _EPERM;
            else
                sem_remove(set, id % IPC_SEQ_MULT);
            break;
        case GETVAL_:
        case GETPID_:
        case GETNCNT_:
        case GETZCNT_:
            if (num < 0 || num >= set->nsems) {
                res = _EINVAL;
            } else if (!ipc_allowed(&set->perm, 4)) {
                res = _EACCES;
            } else {
                struct sem_ *s = &set->sems[num];
                res = cmd == GETVAL_ ? s->val : cmd == GETPID_ ? s->pid : cmd == GETNCNT_ ? s->ncnt : s->zcnt;
            }
            break;
        case GETALL_: {
            if (!ipc_allowed(&set->perm, 4)) {
                res = _EACCES;
                break;
            }
            uint16_t vals[set->nsems];
            for (int i = 0; i < set->nsems; i++)
                vals[i] = set->sems[i].val;
            if (user_write(arg, vals, sizeof(vals)))
                res = _EFAULT;
            break;
        }
        case SETVAL_: {
            int val = (int) arg;
            if (num < 0 || num >= set->nsems) {
                res = _EINVAL;
                break;
            }
            if (val < 0 || val > SEMVMX) {
                res = _ERANGE;
                break;
            }
            if (!ipc_allowed(&set->perm, 2)) {
                res = _EACCES;
                break;
            }
            set->sems[num].val = val;
            set->sems[num].pid = current->tgid;
            sem_undo_forget(id, num);
            set->ctime = now();
            notify(&set->changed);
            break;
        }
        case SETALL_: {
            if (!ipc_allowed(&set->perm, 2)) {
                res = _EACCES;
                break;
            }
            uint16_t vals[set->nsems];
            if (user_read(arg, vals, sizeof(vals))) {
                res = _EFAULT;
                break;
            }
            for (int i = 0; i < set->nsems; i++) {
                if (vals[i] > SEMVMX) {
                    res = _ERANGE;
                    break;
                }
            }
            if (res < 0)
                break;
            for (int i = 0; i < set->nsems; i++) {
                set->sems[i].val = vals[i];
                set->sems[i].pid = current->tgid;
                sem_undo_forget(id, i);
            }
            set->ctime = now();
            notify(&set->changed);
            break;
        }
        default:
            res = _EINVAL;
    }
out:
    unlock(&ipc_lock);
    return res;
}

// The process (thread group) tgid exited: apply its SEM_UNDO adjustments.
void sysv_ipc_exit(pid_t_ tgid) {
    lock(&ipc_lock);
    struct sem_undo *u, *tmp;
    list_for_each_entry_safe(&sem_undos, u, tmp, link) {
        if (u->tgid != tgid)
            continue;
        struct sem_set *set = IPC_LOOKUP(sems, u->semid);
        if (set != NULL) {
            for (int i = 0; i < u->nsems && i < set->nsems; i++) {
                if (u->adj[i] == 0)
                    continue;
                int val = set->sems[i].val + u->adj[i];
                set->sems[i].val = val < 0 ? 0 : val > SEMVMX ? SEMVMX : val;
                set->sems[i].pid = tgid;
            }
            set->otime = now();
            notify(&set->changed);
        }
        list_remove(&u->link);
        free(u);
    }
    unlock(&ipc_lock);
}

// ---------------------------------------------------------------------------
// Message queues
// ---------------------------------------------------------------------------

static void msq_free(struct msg_queue *q) {
    struct msg *m, *tmp;
    list_for_each_entry_safe(&q->messages, m, tmp, link) {
        list_remove(&m->link);
        free(m);
    }
    cond_destroy(&q->changed);
    free(q);
}

static int msq_create(int_t key, int flags) {
    int index = IPC_FREE_SLOT(msqs);
    if (index < 0)
        return _ENOSPC;
    struct msg_queue *q = calloc(1, sizeof(*q));
    if (q == NULL)
        return _ENOMEM;
    perm_init(&q->perm, key, flags);
    list_init(&q->messages);
    q->qbytes = MSGMNB;
    q->ctime = now();
    cond_init(&q->changed);
    msqs[index] = q;
    return ipc_id(&q->perm, index);
}

int_t sys_msgget(int_t key, int_t flags) {
    STRACE("msgget(%#x, %#o)", key, flags);
    lock(&ipc_lock);
    int want = flags_to_want(flags);
#define MSQ_CHECK(q) (!ipc_allowed(&(q)->perm, want) ? _EACCES : 0)
    int res = IPC_GET(msqs, key, flags, MSQ_CHECK, msq_create(key, flags));
#undef MSQ_CHECK
    unlock(&ipc_lock);
    return res;
}

// Waits for the queue to change. 0, or an error; frees a queue removed meanwhile.
static int msq_wait(struct msg_queue *q) {
    q->waiters++;
    int err = wait_for(&q->changed, &ipc_lock, NULL);
    q->waiters--;
    if (q->perm.removed) {
        if (q->waiters == 0)
            msq_free(q);
        return _EIDRM;
    }
    return err == _EINTR ? _EINTR : 0;
}

int_t sys_msgsnd(int_t id, addr_t msgp, uint64_t size, int_t flags) {
    STRACE("msgsnd(%d, %#llx, %llu, %#o)", id, (unsigned long long) msgp, (unsigned long long) size, flags);
    if (size > MSGMAX)
        return _EINVAL;
    struct msg *m = malloc(sizeof(*m) + size);
    if (m == NULL)
        return _ENOMEM;
    if (user_get(msgp, m->type) || user_read(msgp + sizeof(int64_t), m->text, size)) {
        free(m);
        return _EFAULT;
    }
    if (m->type <= 0) {
        free(m);
        return _EINVAL;
    }
    m->size = size;
    lock(&ipc_lock);
    int res = 0;
    struct msg_queue *q = IPC_LOOKUP(msqs, id);
    if (q == NULL) {
        res = _EINVAL;
        goto out;
    }
    if (!ipc_allowed(&q->perm, 2)) {
        res = _EACCES;
        goto out;
    }
    while (q->cbytes + size > q->qbytes || q->qnum + 1 > q->qbytes) {
        if (flags & IPC_NOWAIT_) {
            res = _EAGAIN;
            goto out;
        }
        res = msq_wait(q);
        if (res < 0)
            goto out;
    }
    list_add_before(&q->messages, &m->link);
    m = NULL;
    q->cbytes += size;
    q->qnum++;
    q->lspid = current->tgid;
    q->stime = now();
    notify(&q->changed);
out:
    unlock(&ipc_lock);
    free(m);
    return res;
}

static struct msg *msq_find(struct msg_queue *q, int64_t type, int flags) {
    struct msg *m, *best = NULL;
    list_for_each_entry(&q->messages, m, link) {
        if (type == 0)
            return m;
        if (type > 0) {
            if ((flags & MSG_EXCEPT_) ? m->type != type : m->type == type)
                return m;
        } else if (m->type <= -type && (best == NULL || m->type < best->type)) {
            best = m;
        }
    }
    return best;
}

int64_t sys_msgrcv(int_t id, addr_t msgp, uint64_t size, int64_t type, int_t flags) {
    STRACE("msgrcv(%d, %#llx, %llu, %lld, %#o)", id, (unsigned long long) msgp, (unsigned long long) size,
            (long long) type, flags);
    if ((int64_t) size < 0)
        return _EINVAL;
    if (flags & MSG_COPY_)
        return _ENOSYS;
    lock(&ipc_lock);
    int64_t res;
    struct msg_queue *q = IPC_LOOKUP(msqs, id);
    if (q == NULL) {
        res = _EINVAL;
        goto out;
    }
    if (!ipc_allowed(&q->perm, 4)) {
        res = _EACCES;
        goto out;
    }
    struct msg *m;
    while ((m = msq_find(q, type, flags)) == NULL) {
        if (flags & IPC_NOWAIT_) {
            res = _ENOMSG;
            goto out;
        }
        res = msq_wait(q);
        if (res < 0)
            goto out;
    }
    if (m->size > size && !(flags & MSG_NOERROR_)) {
        res = _E2BIG;
        goto out;
    }
    size_t n = m->size < size ? m->size : size;
    if (user_put(msgp, m->type) || user_write(msgp + sizeof(int64_t), m->text, n)) {
        res = _EFAULT;
        goto out;
    }
    list_remove(&m->link);
    q->cbytes -= m->size;
    q->qnum--;
    q->lrpid = current->tgid;
    q->rtime = now();
    free(m);
    notify(&q->changed);
    res = n;
out:
    unlock(&ipc_lock);
    return res;
}

static void msq_to_user(struct msg_queue *q, struct msqid64_ds_ *ds) {
    memset(ds, 0, sizeof(*ds));
    perm_to_user(&q->perm, &ds->perm);
    ds->stime = q->stime;
    ds->rtime = q->rtime;
    ds->ctime = q->ctime;
    ds->cbytes = q->cbytes;
    ds->qnum = q->qnum;
    ds->qbytes = q->qbytes;
    ds->lspid = q->lspid;
    ds->lrpid = q->lrpid;
}

int_t sys_msgctl(int_t id, int_t cmd, addr_t buf) {
    STRACE("msgctl(%d, %d, %#llx)", id, cmd, (unsigned long long) buf);
    cmd &= ~IPC_64_;
    int res = 0;
    lock(&ipc_lock);
    if (cmd == IPC_INFO_ || cmd == MSG_INFO_) {
        struct msginfo_ info = {
            .msgpool = IPC_MNI * MSGMNB / 1024, .msgmap = MSGMNB, .msgmax = MSGMAX, .msgmnb = MSGMNB,
            .msgmni = IPC_MNI, .msgssz = 16, .msgtql = MSGMNB, .msgseg = 0xffff,
        };
        int max = -1;
        if (cmd == MSG_INFO_)
            info.msgpool = info.msgmap = info.msgtql = 0;
        for (int i = 0; i < IPC_MNI; i++) {
            if (msqs[i] != NULL) {
                max = i;
                if (cmd == MSG_INFO_) {
                    info.msgpool++;
                    info.msgmap += msqs[i]->qnum;
                    info.msgtql += msqs[i]->cbytes;
                }
            }
        }
        res = user_put(buf, info) ? _EFAULT : (max < 0 ? 0 : max);
        goto out;
    }
    if (cmd == MSG_STAT_ || cmd == MSG_STAT_ANY_) {
        struct msg_queue *q = id >= 0 && id < IPC_MNI ? msqs[id] : NULL;
        if (q == NULL) {
            res = _EINVAL;
        } else if (cmd == MSG_STAT_ && !ipc_allowed(&q->perm, 4)) {
            res = _EACCES;
        } else {
            struct msqid64_ds_ ds;
            msq_to_user(q, &ds);
            res = user_put(buf, ds) ? _EFAULT : ipc_id(&q->perm, id);
        }
        goto out;
    }
    struct msg_queue *q = IPC_LOOKUP(msqs, id);
    if (q == NULL) {
        res = _EINVAL;
        goto out;
    }
    switch (cmd) {
        case IPC_STAT_: {
            if (!ipc_allowed(&q->perm, 4)) {
                res = _EACCES;
                break;
            }
            struct msqid64_ds_ ds;
            msq_to_user(q, &ds);
            if (user_put(buf, ds))
                res = _EFAULT;
            break;
        }
        case IPC_SET_: {
            struct msqid64_ds_ ds;
            if (user_get(buf, ds)) {
                res = _EFAULT;
                break;
            }
            if (ds.qbytes > MSGMNB && !superuser()) {
                res = _EPERM;
                break;
            }
            res = perm_set(&q->perm, &ds.perm);
            if (res == 0) {
                q->qbytes = ds.qbytes;
                q->ctime = now();
                notify(&q->changed);
            }
            break;
        }
        case IPC_RMID_:
            if (!ipc_owner(&q->perm)) {
                res = _EPERM;
                break;
            }
            q->perm.removed = true;
            msqs[id % IPC_SEQ_MULT] = NULL;
            if (q->waiters > 0)
                notify(&q->changed);
            else
                msq_free(q);
            break;
        default:
            res = _EINVAL;
    }
out:
    unlock(&ipc_lock);
    return res;
}

// ---------------------------------------------------------------------------
// i386 multiplexer (unused on arm64)
// ---------------------------------------------------------------------------

int_t sys_ipc(uint_t call, int_t first, int_t second, int_t third, addr_t ptr, int_t fifth) {
    STRACE("ipc(%u, %d, %d, %d, %#x, %d)", call, first, second, third, ptr, fifth);
    return _ENOSYS;
}

// ---------------------------------------------------------------------------
// /proc/sysvipc and /proc/sys/kernel limits
// ---------------------------------------------------------------------------

int proc_sysvipc_shm(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "       key      shmid perms                  size  cpid  lpid nattch   uid   gid  cuid  cgid      atime      dtime      ctime                   rss                  swap\n");
    lock(&ipc_lock);
    for (int i = 0; i < IPC_MNI; i++) {
        struct shm_seg *s = shms[i];
        if (s == NULL)
            continue;
        uint_t mode = s->perm.mode | (s->perm.removed ? SHM_DEST_ : 0);
        proc_printf(buf, "%10d %10d  %4o %21llu %5d %5d  %5d %5u %5u %5u %5u %10lld %10lld %10lld %21llu %21d\n",
                s->perm.removed ? 0 : s->perm.key, ipc_id(&s->perm, i), mode, (unsigned long long) s->size,
                s->cpid, s->lpid, shm_nattch(s), s->perm.uid, s->perm.gid, s->perm.cuid, s->perm.cgid,
                (long long) s->atime, (long long) s->dtime, (long long) s->ctime,
                (unsigned long long) PAGE_ROUND_UP(s->size) * PAGE_SIZE, 0);
    }
    unlock(&ipc_lock);
    return 0;
}

int proc_sysvipc_sem(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "       key      semid perms      nsems   uid   gid  cuid  cgid      otime      ctime\n");
    lock(&ipc_lock);
    for (int i = 0; i < IPC_MNI; i++) {
        struct sem_set *s = sems[i];
        if (s == NULL)
            continue;
        proc_printf(buf, "%10d %10d  %4o %10d %5u %5u %5u %5u %10lld %10lld\n",
                s->perm.key, ipc_id(&s->perm, i), s->perm.mode, s->nsems, s->perm.uid, s->perm.gid,
                s->perm.cuid, s->perm.cgid, (long long) s->otime, (long long) s->ctime);
    }
    unlock(&ipc_lock);
    return 0;
}

int proc_sysvipc_msg(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "       key      msqid perms      cbytes       qnum lspid lrpid   uid   gid  cuid  cgid      stime      rtime      ctime\n");
    lock(&ipc_lock);
    for (int i = 0; i < IPC_MNI; i++) {
        struct msg_queue *q = msqs[i];
        if (q == NULL)
            continue;
        proc_printf(buf, "%10d %10d  %4o  %10zu %10zu %5d %5d %5u %5u %5u %5u %10lld %10lld %10lld\n",
                q->perm.key, ipc_id(&q->perm, i), q->perm.mode, q->cbytes, q->qnum, q->lspid, q->lrpid,
                q->perm.uid, q->perm.gid, q->perm.cuid, q->perm.cgid,
                (long long) q->stime, (long long) q->rtime, (long long) q->ctime);
    }
    unlock(&ipc_lock);
    return 0;
}

int proc_sys_kernel_shmmax(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%lu\n", SHMMAX);
    return 0;
}
int proc_sys_kernel_shmall(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%lu\n", SHMALL);
    return 0;
}
int proc_sys_kernel_shmmni(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%d\n", IPC_MNI);
    return 0;
}
int proc_sys_kernel_sem(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%d\t%d\t%d\t%d\n", SEMMSL, SEMMNS, SEMOPM, IPC_MNI);
    return 0;
}
int proc_sys_kernel_msgmax(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%d\n", MSGMAX);
    return 0;
}
int proc_sys_kernel_msgmnb(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%d\n", MSGMNB);
    return 0;
}
int proc_sys_kernel_msgmni(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "%d\n", IPC_MNI);
    return 0;
}
