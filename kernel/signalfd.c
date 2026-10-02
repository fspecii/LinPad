#include <string.h>
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/signal.h"
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/poll.h"

#define SFD_NONBLOCK_ O_NONBLOCK_
#define SFD_CLOEXEC_ O_CLOEXEC_

struct signalfd_siginfo_ {
    uint32_t signo;
    int32_t err;
    int32_t code;
    uint32_t pid;
    uint32_t uid;
    int32_t fd;
    uint32_t tid;
    uint32_t band;
    uint32_t overrun;
    uint32_t trapno;
    int32_t status;
    int32_t int_;
    uint64_t ptr;
    uint64_t utime;
    uint64_t stime;
    uint64_t addr;
    uint16_t addr_lsb;
    uint8_t pad[46];
};
_Static_assert(sizeof(struct signalfd_siginfo_) == 128, "signalfd_siginfo is 128 bytes");

// All open signalfds, so that signal delivery can wake their pollers.
static lock_t signalfds_lock = LOCK_INITIALIZER;
static struct list signalfds = LIST_INITIALIZER(signalfds);

static const struct fd_ops signalfd_ops;

void signalfd_notify(struct task *task, int sig) {
    lock(&signalfds_lock);
    struct fd *fd;
    list_for_each_entry(&signalfds, fd, signalfd.fds) {
        if (fd->signalfd.group == task->group && sigset_has(fd->signalfd.mask, sig))
            poll_wakeup(fd, POLL_READ);
    }
    unlock(&signalfds_lock);
}

fd_t sys_signalfd4(fd_t f, addr_t mask_addr, uint_t mask_size, int_t flags) {
    STRACE("signalfd4(%d, %#llx, %u, %#x)", f, (unsigned long long) mask_addr, mask_size, flags);
    if (flags & ~(SFD_NONBLOCK_ | SFD_CLOEXEC_))
        return _EINVAL;
    sigset_t_ mask;
    int err = user_get_sigset(mask_addr, mask_size, &mask);
    if (err < 0)
        return err;
    mask &= ~(sig_mask(SIGKILL_) | sig_mask(SIGSTOP_));

    if (f != -1) {
        struct fd *fd = f_get(f);
        if (fd == NULL)
            return _EBADF;
        if (fd->ops != &signalfd_ops)
            return _EINVAL;
        lock(&signalfds_lock);
        fd->signalfd.mask = mask;
        unlock(&signalfds_lock);
        return f;
    }

    struct fd *fd = adhoc_fd_create(&signalfd_ops);
    if (fd != NULL)
        fd->anon_name = "[signalfd]";
    if (fd == NULL)
        return _ENOMEM;
    fd->signalfd.mask = mask;
    fd->signalfd.group = current->group;
    lock(&signalfds_lock);
    list_add(&signalfds, &fd->signalfd.fds);
    unlock(&signalfds_lock);
    return f_install(fd, flags);
}

// Caller holds current->sighand->lock. Returns NULL if nothing in mask is queued.
static struct sigqueue *signalfd_dequeue(sigset_t_ mask) {
    struct sigqueue *sigqueue;
    list_for_each_entry(&current->queue, sigqueue, queue) {
        if (sigset_has(mask, sigqueue->info.sig)) {
            list_remove(&sigqueue->queue);
            int sig = sigqueue->info.sig;
            bool more = false;
            struct sigqueue *other;
            list_for_each_entry(&current->queue, other, queue) {
                if (other->info.sig == sig)
                    more = true;
            }
            if (!more)
                sigset_del(&current->pending, sig);
            return sigqueue;
        }
    }
    return NULL;
}

static ssize_t signalfd_read(struct fd *fd, void *buf, size_t bufsize) {
    if (bufsize < sizeof(struct signalfd_siginfo_))
        return _EINVAL;
    lock(&signalfds_lock);
    sigset_t_ mask = fd->signalfd.mask;
    unlock(&signalfds_lock);

    lock(&current->sighand->lock);
    struct sigqueue *sigqueue;
    while ((sigqueue = signalfd_dequeue(mask)) == NULL) {
        if (fd->flags & O_NONBLOCK_) {
            unlock(&current->sighand->lock);
            return _EAGAIN;
        }
        if (current->pending & ~current->blocked) {
            unlock(&current->sighand->lock);
            return _EINTR;
        }
        // let delivery of blocked signals in the mask wake us up
        current->waiting = mask;
        struct timespec bounded = {.tv_sec = 1};
        wait_for_ignore_signals(&current->pause, &current->sighand->lock, &bounded);
        current->waiting = 0;
    }
    unlock(&current->sighand->lock);

    struct signalfd_siginfo_ info = {
        .signo = sigqueue->info.sig,
        .err = sigqueue->info.sig_errno,
        .code = sigqueue->info.code,
    };
    if (info.signo == SIGCHLD_) {
        info.pid = sigqueue->info.child.pid;
        info.uid = sigqueue->info.child.uid;
        // child.status holds a wait status; report it the way siginfo does
        int_t wstatus = sigqueue->info.child.status;
        if ((wstatus & 0x7f) == 0) {
            info.code = 1; // CLD_EXITED
            info.status = (wstatus >> 8) & 0xff;
        } else {
            info.code = 2; // CLD_KILLED
            info.status = wstatus & 0x7f;
        }
        info.utime = sigqueue->info.child.utime;
        info.stime = sigqueue->info.child.stime;
    } else {
        info.pid = sigqueue->info.kill.pid;
        info.uid = sigqueue->info.kill.uid;
    }
    free(sigqueue);
    memcpy(buf, &info, sizeof(info));
    return sizeof(info);
}

static int signalfd_poll(struct fd *fd) {
    lock(&signalfds_lock);
    sigset_t_ mask = fd->signalfd.mask;
    unlock(&signalfds_lock);
    lock(&current->sighand->lock);
    bool ready = !!(current->pending & mask);
    unlock(&current->sighand->lock);
    return ready ? POLL_READ : 0;
}

static int signalfd_close(struct fd *fd) {
    lock(&signalfds_lock);
    list_remove(&fd->signalfd.fds);
    unlock(&signalfds_lock);
    return 0;
}

static const struct fd_ops signalfd_ops = {
    .read = signalfd_read,
    .poll = signalfd_poll,
    .close = signalfd_close,
};
