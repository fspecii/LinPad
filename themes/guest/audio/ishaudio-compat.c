/*
 * LD_PRELOAD shim for PulseAudio (server and libpulse clients) under iSH.
 *
 * 1. PulseAudio asks for priority-inheritance mutexes and asserts that
 *    pthread_mutexattr_setprotocol() returns 0 or ENOTSUP. musl probes PI support with
 *    FUTEX_LOCK_PI, which iSH does not implement ("SYS_FUTEX: unsupported op=6"), and
 *    passes the resulting error through, so every PulseAudio process aborts in
 *    pa_mutex_new(). Reporting ENOTSUP makes PulseAudio use plain mutexes, as it does on
 *    any kernel without PI futexes.
 *
 * 2. pa_read()/pa_write() try recv()/send() first and switch to read()/write() only when
 *    the fd turns out not to be a socket (ENOTSOCK). iSH fails send()/recv() on a pipe
 *    with EBADF instead, which breaks the main loop's wakeup pipe and the daemon's
 *    startup handshake. The error is translated back to ENOTSOCK.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/stat.h>

int pthread_mutexattr_setprotocol(pthread_mutexattr_t *attr, int protocol)
{
    (void)attr;
    return protocol == PTHREAD_PRIO_NONE ? 0 : ENOTSUP;
}

static int open_non_socket(int fd)
{
    struct stat st;
    return fstat(fd, &st) == 0 && !S_ISSOCK(st.st_mode);
}

ssize_t send(int fd, const void *buf, size_t len, int flags)
{
    static ssize_t (*real_send)(int, const void *, size_t, int);
    if (!real_send)
        real_send = (ssize_t (*)(int, const void *, size_t, int))dlsym(RTLD_NEXT, "send");
    ssize_t r = real_send(fd, buf, len, flags);
    if (r < 0 && errno == EBADF && open_non_socket(fd))
        errno = ENOTSOCK;
    return r;
}

ssize_t recv(int fd, void *buf, size_t len, int flags)
{
    static ssize_t (*real_recv)(int, void *, size_t, int);
    if (!real_recv)
        real_recv = (ssize_t (*)(int, void *, size_t, int))dlsym(RTLD_NEXT, "recv");
    ssize_t r = real_recv(fd, buf, len, flags);
    if (r < 0 && errno == EBADF && open_non_socket(fd))
        errno = ENOTSOCK;
    return r;
}
