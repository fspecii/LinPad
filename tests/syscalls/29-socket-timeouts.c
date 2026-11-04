// Checks: SO_RCVTIMEO and SO_SNDTIMEO as 64-bit libcs and Go set them (options 20 and 21,
// with the native struct timeval), including on a netlink socket, which is what the netlink
// library under sing-box and Tailscale does before every request.
// Expected (Linux, socket(7)): set and read back; a receive times out with EAGAIN; tv_usec out
// of range is EDOM. Observed before: EINVAL for every socket, so those libraries gave up.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#define NETLINK_ROUTE 0
static int failures;
#define CHECK(cond, ...) do { int ok_ = (cond); printf("%s: ", ok_ ? "PASS" : "FAIL"); failures += !ok_; \
    printf(__VA_ARGS__); printf("\n"); } while (0)

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(void) {
    int udp = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(udp, (struct sockaddr *) &addr, sizeof(addr));
    struct timeval tv = {.tv_sec = 0, .tv_usec = 200000};
    int r = setsockopt(udp, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)), r2;
    CHECK(r == 0, "setsockopt SO_RCVTIMEO (%d) = %d errno %d", SO_RCVTIMEO, r, r ? errno : 0);
    struct timeval got = {0};
    socklen_t len = sizeof(got);
    r = getsockopt(udp, SOL_SOCKET, SO_RCVTIMEO, &got, &len);
    CHECK(r == 0 && len == sizeof(got) && got.tv_sec == 0 && got.tv_usec == 200000,
        "getsockopt SO_RCVTIMEO = %d, %ld.%06ld, len %u", r, (long) got.tv_sec, (long) got.tv_usec, len);
    char buf[8];
    double start = now();
    r = recv(udp, buf, sizeof(buf), 0);
    double waited = now() - start;
    CHECK(r == -1 && errno == EAGAIN && waited > 0.15 && waited < 1.5,
        "recv times out: %d errno %d after %.2fs", r, errno, waited);
    tv = (struct timeval) {.tv_sec = 1, .tv_usec = 1000000};
    r = setsockopt(udp, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    CHECK(r == -1 && errno == EDOM, "tv_usec 1000000 = %d errno %d", r, errno);
    r = setsockopt(udp, SOL_SOCKET, SO_SNDTIMEO, &tv, 4);
    CHECK(r == -1 && errno == EINVAL, "short option = %d errno %d", r, errno);

    // cronet (sing-box's naive outbound) sets path MTU discovery on its UDP sockets; Darwin has
    // neither option, which is accepted and ignored
    int udp6 = socket(AF_INET6, SOCK_DGRAM, 0);
    int pmtu = 2; // IP_PMTUDISC_DO
    r = setsockopt(udp6, IPPROTO_IPV6, 23, &pmtu, sizeof(pmtu));
    r2 = setsockopt(udp, IPPROTO_IP, 10, &pmtu, sizeof(pmtu));
    CHECK(r == 0 && r2 == 0, "IPV6_MTU_DISCOVER = %d, IP_MTU_DISCOVER = %d", r, r2);

    int nl = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    tv = (struct timeval) {.tv_sec = 60};
    r = setsockopt(nl, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    r2 = setsockopt(nl, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    CHECK(r == 0 && r2 == 0, "netlink SO_SNDTIMEO = %d, SO_RCVTIMEO = %d errno %d", r, r2, errno);
    len = sizeof(got);
    r = getsockopt(nl, SOL_SOCKET, SO_SNDTIMEO, &got, &len);
    CHECK(r == 0 && got.tv_sec == 60 && got.tv_usec == 0, "netlink SO_SNDTIMEO reads back %ld", (long) got.tv_sec);
    return failures != 0;
}
