// Checks: NETLINK_ROUTE RTM_GETROUTE, as sing-box, Tailscale and `ip route` use it.
// Expected (Linux, rtnetlink(7)): a dump of the main table with a default route (no RTA_DST)
// whose RTA_OIF is a link RTM_GETLINK knows (unless the host is offline), a route for one
// destination on request, and EINVAL for a malformed request.
// Observed before: an empty table, so "missing default interface" / no route to the internet.
#include <errno.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <stdint.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <netinet/in.h>

// <linux/rtnetlink.h> needs linux-headers; the parts used here.
#define NETLINK_ROUTE 0
#define NLM_F_REQUEST 1
#define NLM_F_DUMP 0x300
#define NLMSG_ERROR 2
#define NLMSG_DONE 3
#define RTM_NEWROUTE 24
#define RTM_GETROUTE 26
#define RTA_DST 1
#define RTA_OIF 4
#define RTA_TABLE 15
#define RT_TABLE_MAIN 254
struct nlmsghdr {
    uint32_t nlmsg_len;
    uint16_t nlmsg_type, nlmsg_flags;
    uint32_t nlmsg_seq, nlmsg_pid;
};
struct rtmsg {
    unsigned char rtm_family, rtm_dst_len, rtm_src_len, rtm_tos;
    unsigned char rtm_table, rtm_protocol, rtm_scope, rtm_type;
    unsigned rtm_flags;
};
struct rtattr {
    unsigned short rta_len, rta_type;
};
#define ALIGN4(len) (((len) + 3) & ~3)
static int failures;
#define CHECK(cond, ...) do { int ok_ = (cond); printf("%s: ", ok_ ? "PASS" : "FAIL"); failures += !ok_; \
    printf(__VA_ARGS__); printf("\n"); } while (0)

struct route_seen {
    int routes, defaults, main_table, error; // error: the NLMSG_ERROR code, or 1 for none sent
    unsigned default_oif;
    // the first route
    int family, dst_len, has_dst;
    unsigned char dst[4];
    unsigned oif;
};

static void parse(char *buf, int len, struct route_seen *seen, int *done) {
    for (int off = 0; off + (int) sizeof(struct nlmsghdr) <= len;) {
        struct nlmsghdr *h = (struct nlmsghdr *) (buf + off);
        if (h->nlmsg_len < sizeof(*h) || off + (int) h->nlmsg_len > len)
            return;
        off += ALIGN4(h->nlmsg_len);
        if (h->nlmsg_type == NLMSG_DONE || h->nlmsg_type == NLMSG_ERROR) {
            if (h->nlmsg_type == NLMSG_ERROR)
                memcpy(&seen->error, h + 1, sizeof(int));
            *done = 1;
            return;
        }
        if (h->nlmsg_type != RTM_NEWROUTE)
            continue;
        struct rtmsg *rt = (struct rtmsg *) (h + 1);
        seen->routes++;
        unsigned table = rt->rtm_table, oif = 0;
        int has_dst = 0;
        char *end = (char *) h + h->nlmsg_len;
        for (char *p = (char *) (rt + 1); p + sizeof(struct rtattr) <= end;) {
            struct rtattr *a = (struct rtattr *) p;
            if (a->rta_len < sizeof(*a) || p + a->rta_len > end)
                break;
            void *data = a + 1;
            if (a->rta_type == RTA_TABLE)
                memcpy(&table, data, 4);
            if (a->rta_type == RTA_OIF)
                memcpy(&oif, data, 4);
            if (a->rta_type == RTA_DST)
                has_dst = 1;
            if (seen->routes == 1 && a->rta_type == RTA_DST && rt->rtm_family == AF_INET && a->rta_len >= sizeof(*a) + 4)
                memcpy(seen->dst, data, 4);
            p += ALIGN4(a->rta_len);
        }
        if (seen->routes == 1) {
            seen->family = rt->rtm_family;
            seen->dst_len = rt->rtm_dst_len;
            seen->has_dst = has_dst;
            seen->oif = oif;
        }
        seen->main_table += table == RT_TABLE_MAIN;
        if (!has_dst && rt->rtm_dst_len == 0 && seen->defaults++ == 0)
            seen->default_oif = oif;
    }
}

// Whether the host is on a network, so it ought to have a default route: an up, non-loopback
// interface with an IPv4 address outside 127/8 and 169.254/16.
static int has_global_ipv4(void) {
    struct ifaddrs *ifas;
    if (getifaddrs(&ifas) != 0)
        return 1;
    int found = 0;
    for (struct ifaddrs *ifa = ifas; ifa != NULL && !found; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET ||
                !(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;
        unsigned char *a = (unsigned char *) &((struct sockaddr_in *) ifa->ifa_addr)->sin_addr;
        found = a[0] != 127 && a[0] != 0 && !(a[0] == 169 && a[1] == 254);
    }
    freeifaddrs(ifas);
    return found;
}

int main(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    struct {
        struct nlmsghdr h;
        struct rtmsg rt;
    } req = {
        .h = {.nlmsg_len = sizeof(req), .nlmsg_type = RTM_GETROUTE, .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP, .nlmsg_seq = 1},
        .rt = {.rtm_family = AF_UNSPEC},
    };
    CHECK(send(fd, &req, sizeof(req), 0) == sizeof(req), "send RTM_GETROUTE dump");
    struct route_seen seen = {.error = 1};
    int done = 0;
    char buf[8192];
    while (!done) {
        int n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0)
            break;
        parse(buf, n, &seen, &done);
    }
    CHECK(done && seen.error == 1, "dump ends with NLMSG_DONE, not an error (%d)", seen.error);
    CHECK(seen.routes > 0 && seen.main_table == seen.routes, "%d routes, %d in the main table", seen.routes, seen.main_table);
    char name[IF_NAMESIZE] = "";
    int online = seen.defaults > 0 || has_global_ipv4();
    if (online)
        CHECK(seen.defaults > 0 && seen.default_oif != 0 && if_indextoname(seen.default_oif, name) != NULL,
            "%d default routes, the first through ifindex %u (%s)", seen.defaults, seen.default_oif, name);
    else
        printf("SKIP: no default route: the host has no network\n");

    // The netlink library under sing-box and Tailscale dumps with family 255, which Linux
    // answers like AF_UNSPEC.
    req.rt.rtm_family = 255;
    req.h.nlmsg_seq = 3;
    send(fd, &req, sizeof(req), 0);
    struct route_seen any = {0};
    done = 0;
    while (!done) {
        int n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0)
            break;
        parse(buf, n, &any, &done);
    }
    CHECK(any.routes == seen.routes, "family 255 dumps all %d routes: %d", seen.routes, any.routes);

    // ip route get 192.0.2.1
    struct {
        struct nlmsghdr h;
        struct rtmsg rt;
        struct rtattr a;
        struct in_addr dst;
    } get = {
        .h = {.nlmsg_len = sizeof(get), .nlmsg_type = RTM_GETROUTE, .nlmsg_flags = NLM_F_REQUEST, .nlmsg_seq = 2},
        .rt = {.rtm_family = AF_INET, .rtm_dst_len = 32},
        .a = {.rta_len = sizeof(struct rtattr) + 4, .rta_type = RTA_DST},
    };
    inet_pton(AF_INET, "192.0.2.1", &get.dst);
    send(fd, &get, sizeof(get), 0);
    struct route_seen one = {.error = 1};
    int n = recv(fd, buf, sizeof(buf), 0);
    done = 0;
    if (n > 0)
        parse(buf, n, &one, &done);
    name[0] = '\0';
    unsigned char want[4] = {192, 0, 2, 1};
    if (online)
        CHECK(one.routes == 1 && one.family == AF_INET && one.dst_len == 32 && one.has_dst &&
            memcmp(one.dst, want, 4) == 0 && if_indextoname(one.oif, name) != NULL,
            "route get 192.0.2.1: %d route(s), %d.%d.%d.%d/%d through ifindex %u (%s)", one.routes,
            one.dst[0], one.dst[1], one.dst[2], one.dst[3], one.dst_len, one.oif, name);

    // an RTA_DST shorter than the address is EINVAL, not a lookup of 0.0.0.0
    get.a.rta_len = sizeof(struct rtattr) + 2;
    get.h.nlmsg_seq = 4;
    send(fd, &get, sizeof(get), 0);
    struct route_seen bad = {.error = 1};
    n = recv(fd, buf, sizeof(buf), 0);
    done = 0;
    if (n > 0)
        parse(buf, n, &bad, &done);
    CHECK(bad.routes == 0 && bad.error == -EINVAL, "route get with a short RTA_DST: %d route(s), error %d",
        bad.routes, bad.error);
    close(fd);
    return failures != 0;
}
