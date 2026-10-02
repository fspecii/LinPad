/* SCM_RIGHTS compatibility for iSH's ARM64 guest.
 *
 * iSH's sendmsg/recvmsg (fs/sock.c) parse control messages with the 32-bit
 * x86 cmsghdr layout {u32 len; i32 level; i32 type; data @12}, while 64-bit
 * Linux uses {size_t len; i32 level; i32 type; data @16}. An ARM64 guest's
 * fds are therefore silently dropped, and Wayland cannot work without fd
 * passing (wl_shm pools, keymaps).
 *
 * This file interposes sendmsg/recvmsg and translates between the two layouts
 * when (and only when) a startup probe shows fd passing is broken, so it
 * becomes a no-op once the emulator is fixed. It is linked into ishwl and
 * built as libishwl-scm.so, which ishwl LD_PRELOADs into the apps it starts.
 *
 * It also rejects SCM_RIGHTS with a closed fd (EBADF, as Linux does): iSH's
 * sendmsg dereferences the missing fd and takes down the whole app
 * (fs/sock.c, fd_retain(f_get(fd))). Firefox's IPC does send such messages.
 *
 * And it enlarges unix socket buffers (connect, socketpair): iSH sockets are host
 * sockets, and Darwin gives them 8 KiB where Linux gives ~200 KiB. Full buffers are
 * more than slow here: an SCM_RIGHTS send that hits EAGAIN on the host makes iSH
 * return EINVAL or crash, which is what killed Firefox's IPC channels. */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <stdlib.h>
#include <unistd.h>

struct ish_cmsghdr {
    uint32_t len;
    int32_t level;
    int32_t type;
};

#define MAX_FDS 64

static int translate = -1; /* -1 unknown, 0 native works, 1 translate */

/* The C library's own sendmsg/recvmsg. musl's sendmsg zeroes the padding word next
 * to every 32-bit cmsg_len before the kernel (or iSH, which reads a 64-bit length)
 * sees it, so anything in native layout must go through it, never a raw syscall. */
static ssize_t libc_sendmsg(int fd, const struct msghdr *msg, int flags) {
    static ssize_t (*real)(int, const struct msghdr *, int);
    if (!real) real = (ssize_t (*)(int, const struct msghdr *, int)) dlsym(RTLD_NEXT, "sendmsg");
    return real(fd, msg, flags);
}

static ssize_t libc_recvmsg(int fd, struct msghdr *msg, int flags) {
    static ssize_t (*real)(int, struct msghdr *, int);
    if (!real) real = (ssize_t (*)(int, struct msghdr *, int)) dlsym(RTLD_NEXT, "recvmsg");
    return real(fd, msg, flags);
}

/* Raw syscalls are only for the translated iSH layout, which libc would "fix up". */
static ssize_t raw_sendmsg(int fd, const struct msghdr *msg, int flags) {
    return syscall(SYS_sendmsg, fd, msg, flags);
}

static ssize_t raw_recvmsg(int fd, struct msghdr *msg, int flags) {
    return syscall(SYS_recvmsg, fd, msg, flags);
}

static bool probe_native(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) < 0)
        return true;
    int payload = open("/dev/null", O_RDONLY | O_CLOEXEC);
    bool native = false;
    char byte = 'x';
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } control;
    memset(&control, 0, sizeof(control));
    struct iovec iov = {&byte, 1};
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1,
                         .msg_control = control.buf, .msg_controllen = sizeof(control.buf)};
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &payload, sizeof(int));
    if (payload >= 0 && libc_sendmsg(sv[0], &msg, 0) == 1) {
        memset(&control, 0, sizeof(control));
        msg.msg_controllen = sizeof(control.buf);
        if (libc_recvmsg(sv[1], &msg, MSG_DONTWAIT) == 1) {
            cmsg = CMSG_FIRSTHDR(&msg);
            if (cmsg && cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
                int received;
                memcpy(&received, CMSG_DATA(cmsg), sizeof(int));
                native = received >= 0;
                if (received >= 0) close(received);
            }
        }
    }
    if (payload >= 0) close(payload);
    close(sv[0]);
    close(sv[1]);
    return native;
}

static bool must_translate(void) {
    if (translate < 0) {
        int saved = errno;
        translate = probe_native() ? 0 : 1;
        errno = saved;
    }
    return translate == 1;
}

/* For ishwl's log: whether this process translates control messages. */
const char *scm_compat_mode(void) {
    return must_translate() ? "translating (emulator drops aarch64 SCM_RIGHTS)" : "off (native fd passing works)";
}

static void enlarge_buffers(int fd) {
    int saved = errno, size = 1 << 20;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    errno = saved;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    int res = syscall(SYS_connect, fd, addr, len);
    if ((res == 0 || errno == EINPROGRESS) && addr && addr->sa_family == AF_UNIX)
        enlarge_buffers(fd);
    return res;
}

int socketpair(int domain, int type, int protocol, int sv[2]) {
    int res = syscall(SYS_socketpair, domain, type, protocol, sv);
    if (res == 0 && domain == AF_UNIX) {
        enlarge_buffers(sv[0]);
        enlarge_buffers(sv[1]);
    }
    return res;
}

static bool rights_are_valid(const struct msghdr *msg) {
    for (struct cmsghdr *c = CMSG_FIRSTHDR((struct msghdr *) msg); c; c = CMSG_NXTHDR((struct msghdr *) msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
            continue;
        size_t n = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        const int *fds = (const int *) CMSG_DATA(c);
        for (size_t i = 0; i < n; i++)
            if (fcntl(fds[i], F_GETFD) < 0)
                return false;
    }
    return true;
}

/* iSH fails some stream sends that carry two or more fds with EINVAL (Firefox:
 * GDK's wl_shm pools and IPC shmem both hit it), while one fd per sendmsg always
 * works. On a stream socket the fds may arrive split over several chunks, so each
 * fd but the last goes with one byte of the payload and the last with the rest.
 * The chunks are sent blocking: once the first byte is out, the message has to
 * be completed. */
static ssize_t send_split(int fd, const struct msghdr *msg, int flags) {
    int type = 0;
    socklen_t len = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) < 0 || type != SOCK_STREAM) {
        errno = EINVAL;
        return -1;
    }
    int fds[MAX_FDS];
    size_t nfds = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR((struct msghdr *) msg); c; c = CMSG_NXTHDR((struct msghdr *) msg, c)) {
        size_t n = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || nfds + n > MAX_FDS) continue;
        memcpy(fds + nfds, CMSG_DATA(c), n * sizeof(int));
        nfds += n;
    }
    /* Flatten the payload. */
    size_t total = 0;
    for (size_t i = 0; i < (size_t) msg->msg_iovlen; i++) total += msg->msg_iov[i].iov_len;
    if (total < nfds) { errno = EINVAL; return -1; }
    char *buf = malloc(total);
    if (!buf) { errno = ENOMEM; return -1; }
    size_t off = 0;
    for (size_t i = 0; i < (size_t) msg->msg_iovlen; i++) {
        memcpy(buf + off, msg->msg_iov[i].iov_base, msg->msg_iov[i].iov_len);
        off += msg->msg_iov[i].iov_len;
    }
    size_t sent = 0;
    for (size_t k = 0; k < nfds; k++) {
        union { char b[CMSG_SPACE(sizeof(int))]; struct cmsghdr a; } ctl;
        memset(&ctl, 0, sizeof(ctl));
        size_t chunk = k + 1 == nfds ? total - sent : 1;
        struct iovec iov = {buf + sent, chunk};
        struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.b, .msg_controllen = sizeof(ctl.b)};
        struct cmsghdr *c = CMSG_FIRSTHDR(&m);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fds[k], sizeof(int));
        ssize_t r = libc_sendmsg(fd, &m, flags & ~MSG_DONTWAIT);
        if (r < 0) { int e = errno; free(buf); if (sent) return sent; errno = e; return -1; }
        sent += r;
    }
    free(buf);
    return sent;
}

ssize_t sendmsg(int fd, const struct msghdr *msg, int flags) {
    if (!msg->msg_control || msg->msg_controllen == 0)
        return libc_sendmsg(fd, msg, flags);
    if (!rights_are_valid(msg)) {
        errno = EBADF;
        return -1;
    }
    if (!must_translate()) {
        ssize_t r = libc_sendmsg(fd, msg, flags);
        if (r < 0 && errno == EINVAL)
            return send_split(fd, msg, flags);
        return r;
    }

    int fds[MAX_FDS];
    size_t nfds = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR((struct msghdr *) msg); c; c = CMSG_NXTHDR((struct msghdr *) msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
            continue; /* iSH rejects every other control message anyway */
        size_t n = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        if (nfds + n > MAX_FDS) {
            errno = EINVAL;
            return -1;
        }
        memcpy(fds + nfds, CMSG_DATA(c), n * sizeof(int));
        nfds += n;
    }
    char control[sizeof(struct ish_cmsghdr) + sizeof(fds)];
    struct msghdr copy = *msg;
    if (nfds == 0) {
        copy.msg_control = NULL;
        copy.msg_controllen = 0;
    } else {
        struct ish_cmsghdr header = {(uint32_t) (sizeof(header) + nfds * sizeof(int)), SOL_SOCKET, SCM_RIGHTS};
        memcpy(control, &header, sizeof(header));
        memcpy(control + sizeof(header), fds, nfds * sizeof(int));
        copy.msg_control = control;
        copy.msg_controllen = header.len;
    }
    return raw_sendmsg(fd, &copy, flags);
}

ssize_t recvmsg(int fd, struct msghdr *msg, int flags) {
    if (!msg->msg_control || msg->msg_controllen == 0 || !must_translate())
        return libc_recvmsg(fd, msg, flags);

    size_t capacity = msg->msg_controllen;
    ssize_t res = raw_recvmsg(fd, msg, flags & ~MSG_CMSG_CLOEXEC);
    if (res < 0 || msg->msg_controllen == 0)
        return res;

    struct ish_cmsghdr header;
    memcpy(&header, msg->msg_control, sizeof(header));
    if (header.level != SOL_SOCKET || header.type != SCM_RIGHTS || header.len < sizeof(header)) {
        msg->msg_controllen = 0;
        return res;
    }
    size_t nfds = (header.len - sizeof(header)) / sizeof(int);
    int fds[MAX_FDS];
    if (nfds > MAX_FDS) nfds = MAX_FDS;
    memcpy(fds, (char *) msg->msg_control + sizeof(header), nfds * sizeof(int));

    size_t fit = capacity >= CMSG_LEN(0) ? (capacity - CMSG_LEN(0)) / sizeof(int) : 0;
    for (size_t i = fit; i < nfds; i++)
        close(fds[i]);
    if (fit < nfds) {
        msg->msg_flags |= MSG_CTRUNC;
        nfds = fit;
    }
    if (flags & MSG_CMSG_CLOEXEC)
        for (size_t i = 0; i < nfds; i++)
            fcntl(fds[i], F_SETFD, FD_CLOEXEC);

    memset(msg->msg_control, 0, capacity);
    msg->msg_controllen = CMSG_SPACE(nfds * sizeof(int));
    if (msg->msg_controllen > capacity)
        msg->msg_controllen = capacity;
    struct cmsghdr *c = CMSG_FIRSTHDR(msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(nfds * sizeof(int));
    memcpy(CMSG_DATA(c), fds, nfds * sizeof(int));
    return res;
}
