// Checks: NETLINK_ROUTE RTM_GETROUTE, as sing-box, Tailscale and `ip route` use it.
// Expected (Linux, rtnetlink(7)): a dump of the main table with a default route (no RTA_DST)
// whose RTA_OIF is a link RTM_GETLINK knows, and a route for one destination on request.
// Observed before: an empty table, so "missing default interface" / no route to the internet.
#include <errno.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <stdint.h>
#include <arpa/inet.h>

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
    int routes, defaults, main_table;
    unsigned default_oif;
};

static void parse(char *buf, int len, struct route_seen *seen, int *done) {
    for (int off = 0; off + (int) sizeof(struct nlmsghdr) <= len;) {
        struct nlmsghdr *h = (struct nlmsghdr *) (buf + off);
        if (h->nlmsg_len < sizeof(*h) || off + (int) h->nlmsg_len > len)
            return;
        off += ALIGN4(h->nlmsg_len);
        if (h->nlmsg_type == NLMSG_DONE || h->nlmsg_type == NLMSG_ERROR) {
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
            p += ALIGN4(a->rta_len);
        }
        seen->main_table += table == RT_TABLE_MAIN;
        if (!has_dst && rt->rtm_dst_len == 0 && seen->defaults++ == 0)
            seen->default_oif = oif;
    }
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
    struct route_seen seen = {0};
    int done = 0;
    char buf[8192];
    while (!done) {
        int n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0)
            break;
        parse(buf, n, &seen, &done);
    }
    CHECK(done, "dump ends with NLMSG_DONE");
    CHECK(seen.routes > 0 && seen.main_table == seen.routes, "%d routes, %d in the main table", seen.routes, seen.main_table);
    char name[IF_NAMESIZE] = "";
    CHECK(seen.defaults > 0 && seen.default_oif != 0 && if_indextoname(seen.default_oif, name) != NULL,
        "%d default routes, the first through ifindex %u (%s)", seen.defaults, seen.default_oif, name);

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
    struct route_seen one = {0};
    int n = recv(fd, buf, sizeof(buf), 0);
    done = 0;
    if (n > 0)
        parse(buf, n, &one, &done);
    CHECK(one.routes == 1, "route get 192.0.2.1: %d route(s)", one.routes);
    close(fd);
    return failures != 0;
}
