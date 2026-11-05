// Checks: SO_BINDTOIFINDEX and SO_BINDTODEVICE (socket(7)), which sing-box's Tailscale
// endpoint sets on each UDP and DERP socket it opens, to scope it to the default interface.
// Expected (Linux): a socket binds to an interface by index or by name and reads it back;
// index 0 or an empty name unbinds; an unknown name is ENODEV; a socket bound to lo still
// reaches loopback, over IPv4 and IPv6; one bound to another interface reads it back.
// Observed before: EINVAL for both options, so Tailscale opened no UDP socket and no DERP
// connection.
#include <errno.h>
#include <ifaddrs.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#ifndef SO_BINDTOIFINDEX
#define SO_BINDTOIFINDEX 62
#endif
static int failures;
#define CHECK(cond, ...) do { int ok_ = (cond); printf("%s: ", ok_ ? "PASS" : "FAIL"); failures += !ok_; \
    printf(__VA_ARGS__); printf("\n"); } while (0)

static int bound_index(int fd) {
    int index = -1;
    socklen_t len = sizeof(index);
    return getsockopt(fd, SOL_SOCKET, SO_BINDTOIFINDEX, &index, &len) == 0 ? index : -1;
}

// a datagram from a socket bound to interface index to a receiver on loopback
static int loopback_datagram(int family, int index) {
    int rx = socket(family, SOCK_DGRAM, 0), tx = socket(family, SOCK_DGRAM, 0);
    struct sockaddr_storage at = {0};
    socklen_t len;
    if (family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *) &at;
        in->sin_family = AF_INET;
        in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        len = sizeof(*in);
    } else {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *) &at;
        in6->sin6_family = AF_INET6;
        in6->sin6_addr = in6addr_loopback;
        len = sizeof(*in6);
    }
    bind(rx, (struct sockaddr *) &at, len);
    getsockname(rx, (struct sockaddr *) &at, &len);
    struct timeval tv = {.tv_sec = 2};
    setsockopt(rx, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int ok = setsockopt(tx, SOL_SOCKET, SO_BINDTOIFINDEX, &index, sizeof(index)) == 0 &&
        sendto(tx, "x", 1, 0, (struct sockaddr *) &at, len) == 1;
    char c;
    ok = ok && recv(rx, &c, 1, 0) == 1 && c == 'x';
    close(rx);
    close(tx);
    return ok;
}

int main(void) {
    unsigned lo = if_nametoindex("lo");
    CHECK(lo > 0, "lo has index %u", lo);

    int udp = socket(AF_INET, SOCK_DGRAM, 0);
    int index = lo;
    int r = setsockopt(udp, SOL_SOCKET, SO_BINDTOIFINDEX, &index, sizeof(index));
    CHECK(r == 0 && bound_index(udp) == (int) lo, "SO_BINDTOIFINDEX lo = %d errno %d, reads %d",
        r, r ? errno : 0, bound_index(udp));
    char name[IF_NAMESIZE] = "?";
    socklen_t len = sizeof(name);
    r = getsockopt(udp, SOL_SOCKET, SO_BINDTODEVICE, name, &len);
    CHECK(r == 0 && strcmp(name, "lo") == 0 && len == 3, "SO_BINDTODEVICE reads %d: \"%s\" len %u", r, name, len);
    index = 0;
    r = setsockopt(udp, SOL_SOCKET, SO_BINDTOIFINDEX, &index, sizeof(index));
    CHECK(r == 0 && bound_index(udp) == 0, "index 0 unbinds: %d, reads %d", r, bound_index(udp));
    r = setsockopt(udp, SOL_SOCKET, SO_BINDTODEVICE, "lo", 3);
    CHECK(r == 0 && bound_index(udp) == (int) lo, "SO_BINDTODEVICE \"lo\" = %d errno %d", r, r ? errno : 0);
    r = setsockopt(udp, SOL_SOCKET, SO_BINDTODEVICE, "", 1);
    len = sizeof(name);
    getsockopt(udp, SOL_SOCKET, SO_BINDTODEVICE, name, &len);
    CHECK(r == 0 && bound_index(udp) == 0 && len == 0, "an empty name unbinds: %d, len %u", r, len);
    r = setsockopt(udp, SOL_SOCKET, SO_BINDTODEVICE, "nosuch9", 8);
    CHECK(r == -1 && errno == ENODEV, "an unknown name: %d errno %d", r, r ? errno : 0);
    index = -1;
    r = setsockopt(udp, SOL_SOCKET, SO_BINDTOIFINDEX, &index, sizeof(index));
    CHECK(r == -1 && errno == EINVAL, "index -1: %d errno %d", r, r ? errno : 0);
    close(udp);

    CHECK(loopback_datagram(AF_INET, lo), "bound to lo, IPv4 reaches loopback");
    CHECK(loopback_datagram(AF_INET6, lo), "bound to lo, IPv6 reaches loopback");

    // an interface that is not loopback, as Tailscale picks the default one
    unsigned other = 0;
    char other_name[IF_NAMESIZE] = "";
    struct ifaddrs *ifas;
    if (getifaddrs(&ifas) == 0) {
        for (struct ifaddrs *ifa = ifas; ifa != NULL && other == 0; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET ||
                    (ifa->ifa_flags & (IFF_UP | IFF_LOOPBACK)) != IFF_UP)
                continue;
            other = if_nametoindex(ifa->ifa_name);
            snprintf(other_name, sizeof(other_name), "%s", ifa->ifa_name);
        }
        freeifaddrs(ifas);
    }
    if (other == 0) {
        printf("skip: no interface besides lo with IPv4\n");
        return failures != 0;
    }
    int tcp = socket(AF_INET, SOCK_STREAM, 0);
    r = setsockopt(tcp, SOL_SOCKET, SO_BINDTODEVICE, other_name, strlen(other_name) + 1);
    CHECK(r == 0 && bound_index(tcp) == (int) other, "SO_BINDTODEVICE \"%s\" = %d errno %d",
        other_name, r, r ? errno : 0);
    close(tcp);
    return failures != 0;
}
