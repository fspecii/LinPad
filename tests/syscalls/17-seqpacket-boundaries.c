// AF_UNIX SOCK_SEQPACKET keeps message boundaries, both for socketpair() and
// for sockets connected through bind/listen/connect/accept: each send is one
// record, a short read sets MSG_TRUNC and discards the rest, zero-length
// records are delivered, MSG_PEEK peeks one whole record, the MSG_TRUNC recv
// flag returns the real length, and a closed peer reads as EOF, with no
// address or control data, and polls readable.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
static int failures;
#define CHECK(cond, ...) do { if (cond) printf("PASS: "); else { printf("FAIL: "); failures++; } \
    printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static ssize_t rmsg(int fd, char *buf, size_t len, int flags, int *mflags) {
    struct iovec iov = {buf, len};
    struct msghdr mh = {.msg_iov = &iov, .msg_iovlen = 1};
    ssize_t r = recvmsg(fd, &mh, flags);
    *mflags = mh.msg_flags;
    return r;
}

static void check_pair(const char *what, int a, int b) {
    char buf[64];
    int mf;
    send(a, "abc", 3, 0);
    send(a, "", 0, 0);
    send(a, "defgh", 5, 0);
    ssize_t r = rmsg(b, buf, sizeof(buf), 0, &mf);
    CHECK(r == 3 && memcmp(buf, "abc", 3) == 0 && !(mf & MSG_TRUNC), "%s: first record r=%zd", what, r);
    r = rmsg(b, buf, sizeof(buf), 0, &mf);
    CHECK(r == 0, "%s: zero-length record r=%zd errno=%d", what, r, errno);
    r = rmsg(b, buf, sizeof(buf), 0, &mf);
    CHECK(r == 5 && memcmp(buf, "defgh", 5) == 0, "%s: third record r=%zd", what, r);

    send(a, "0123456789", 10, 0);
    send(a, "XY", 2, 0);
    r = rmsg(b, buf, 4, 0, &mf);
    CHECK(r == 4 && (mf & MSG_TRUNC) && memcmp(buf, "0123", 4) == 0, "%s: short read r=%zd MSG_TRUNC=%d", what, r, !!(mf & MSG_TRUNC));
    r = rmsg(b, buf, sizeof(buf), 0, &mf);
    CHECK(r == 2 && memcmp(buf, "XY", 2) == 0, "%s: rest of truncated record discarded r=%zd", what, r);

    send(a, "peekme", 6, 0);
    send(a, "next", 4, 0);
    r = rmsg(b, buf, sizeof(buf), MSG_PEEK, &mf);
    CHECK(r == 6 && memcmp(buf, "peekme", 6) == 0, "%s: MSG_PEEK whole record r=%zd", what, r);
    r = rmsg(b, buf, sizeof(buf), 0, &mf);
    CHECK(r == 6 && memcmp(buf, "peekme", 6) == 0, "%s: read after peek r=%zd", what, r);
    r = rmsg(b, buf, sizeof(buf), 0, &mf);
    CHECK(r == 4, "%s: next record after peek r=%zd", what, r);

    send(a, "0123456789", 10, 0);
    r = recv(b, buf, 3, MSG_TRUNC);
    CHECK(r == 10, "%s: recv MSG_TRUNC returns real length r=%zd", what, r);

    errno = 0;
    r = recv(b, buf, sizeof(buf), MSG_DONTWAIT);
    CHECK(r == -1 && errno == EAGAIN, "%s: MSG_DONTWAIT empty r=%zd errno=%d", what, r, errno);

    int type = 0;
    socklen_t tl = sizeof(type);
    getsockopt(b, SOL_SOCKET, SO_TYPE, &type, &tl);
    CHECK(type == SOCK_SEQPACKET, "%s: SO_TYPE=%d", what, type);

    send(a, "last", 4, 0);
    close(a);
    r = recv(b, buf, sizeof(buf), 0);
    CHECK(r == 4, "%s: queued record readable after peer close r=%zd", what, r);
    r = recv(b, buf, sizeof(buf), 0);
    CHECK(r == 0, "%s: EOF after peer close r=%zd errno=%d", what, r, errno);
    // EOF carries no control data. A connected (not socketpair) pair left the
    // caller's control buffer unset and walked it: ish spun or closed host fds.
    char control[CMSG_SPACE(sizeof(int) * 4)];
    memset(control, 0xa5, sizeof(control));
    // nor an address: the name buffer is not read back as one
    struct sockaddr_un name;
    memset(&name, 0xa5, sizeof(name));
    struct iovec iov = {buf, sizeof(buf)};
    struct msghdr mh = {.msg_name = &name, .msg_namelen = sizeof(name), .msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control, .msg_controllen = sizeof(control)};
    r = recvmsg(b, &mh, 0);
    CHECK(r == 0 && mh.msg_controllen == 0 && mh.msg_namelen == 0, "%s: recvmsg at EOF r=%zd errno=%d controllen=%zu namelen=%u",
            what, r, r < 0 ? errno : 0, (size_t) mh.msg_controllen, (unsigned) mh.msg_namelen);
    // and EOF stays readable for poll
    struct pollfd pfd = {.fd = b, .events = POLLIN};
    r = poll(&pfd, 1, 1000);
    CHECK(r == 1 && (pfd.revents & POLLIN), "%s: poll at EOF r=%zd revents=%#x", what, r, pfd.revents);
    close(b);
}

int main(void) {
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) == 0, "socketpair seqpacket");
    check_pair("socketpair", sv[0], sv[1]);

    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strcpy(addr.sun_path, "/tmp/linpad-seq");
    unlink(addr.sun_path);
    int l = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    CHECK(l >= 0, "socket seqpacket");
    CHECK(bind(l, (void *) &addr, sizeof(addr)) == 0, "bind errno=%d", errno);
    CHECK(listen(l, 4) == 0, "listen");
    int c = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    CHECK(connect(c, (void *) &addr, sizeof(addr)) == 0, "connect errno=%d", errno);
    // sent before accept: must still arrive as its own record
    send(c, "early", 5, 0);
    int s = accept(l, NULL, NULL);
    CHECK(s >= 0, "accept errno=%d", errno);
    char buf[16];
    int mf;
    ssize_t r = rmsg(s, buf, sizeof(buf), 0, &mf);
    CHECK(r == 5 && memcmp(buf, "early", 5) == 0, "record sent before accept r=%zd", r);
    check_pair("connected c->s", c, s);

    c = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    connect(c, (void *) &addr, sizeof(addr));
    s = accept(l, NULL, NULL);
    check_pair("connected s->c", s, c);
    close(l);
    unlink(addr.sun_path);
    printf(failures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", failures);
    return failures != 0;
}
