// Guest side of tests/lifecycle/netresume.sh: a client that keeps a TCP connection to a
// host server, the way a terminal over SSH or VS Code's extension host does. While the
// emulator is stopped (iPadOS suspending LinPad) the server drops every connection. After
// the resume the client must see the connection end cleanly (EOF or an error, never a
// hang or a crash) and connect again. Prints events and "bad=N" (N = failures).
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int dial(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(port)};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char **argv) {
    int port = atoi(argv[1]);
    int seconds = atoi(argv[2]);
    double start = now(), lost_at = 0;
    int connections = 0, bad = 0;
    int fd = -1;
    while (now() - start < seconds) {
        if (fd < 0) {
            fd = dial(port);
            if (fd < 0) { usleep(200000); continue; }
            connections++;
            if (lost_at > 0) {
                printf("reconnected after %.1f s\n", now() - lost_at);
                if (now() - lost_at > 10) bad++;
                lost_at = 0;
            }
        }
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int r = poll(&pfd, 1, 1000);
        if (r < 0 && errno != EINTR) { printf("poll error %d\n", errno); bad++; break; }
        if (r <= 0) continue;
        char buf[256];
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            printf("got %s", buf);
            fflush(stdout);
            continue;
        }
        printf("connection ended: %s\n", n == 0 ? "EOF" : strerror(errno));
        fflush(stdout);
        close(fd);
        fd = -1;
        lost_at = now();
    }
    if (lost_at > 0) { printf("never reconnected\n"); bad++; }
    printf("connections=%d bad=%d\n", connections, bad);
    return 0;
}
