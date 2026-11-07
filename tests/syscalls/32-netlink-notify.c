// Checks: subscribing to NETLINK_ROUTE change notifications, as Chromium's address tracker
// (bind with nl_groups) and Go netlink libraries (NETLINK_ADD_MEMBERSHIP) do.
// Expected (Linux, netlink(7)): both are accepted, a group past 32 is ignored, group 0 is
// EINVAL; while the host's network stays the same nothing arrives, and requests still get
// their replies on a subscribed socket.
// Observed before: membership options were ignored and nothing was ever sent on a change.
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

#define NETLINK_ROUTE 0
#define SOL_NETLINK 270
#define NETLINK_ADD_MEMBERSHIP 1
#define NETLINK_DROP_MEMBERSHIP 2
#define RTMGRP_LINK 0x1
#define RTMGRP_IPV4_IFADDR 0x10
#define RTMGRP_IPV6_IFADDR 0x100
#define RTNLGRP_IPV4_ROUTE 7
#define NLM_F_REQUEST 1
#define NLM_F_DUMP 0x300
#define RTM_GETLINK 18
#define RTM_GETADDR 22
#define RTM_GETROUTE 26
#define NLMSG_ERROR 2
#define NLMSG_DONE 3
struct sockaddr_nl {
    uint16_t nl_family, nl_pad;
    uint32_t nl_pid, nl_groups;
};
struct nlmsghdr {
    uint32_t nlmsg_len;
    uint16_t nlmsg_type, nlmsg_flags;
    uint32_t nlmsg_seq, nlmsg_pid;
};
static int failures;
#define CHECK(cond, ...) do { int ok_ = (cond); printf("%s: ", ok_ ? "PASS" : "FAIL"); failures += !ok_; \
    printf(__VA_ARGS__); printf("\n"); } while (0)

// A hash of the links, addresses and routes netlink reports, to tell a real network change
// from a spurious notification.
static unsigned long network_state(void) {
    static const unsigned short types[] = {RTM_GETLINK, RTM_GETADDR, RTM_GETROUTE};
    unsigned long hash = 5381;
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    for (unsigned t = 0; t < sizeof(types) / sizeof(types[0]); t++) {
        struct {
            struct nlmsghdr h;
            unsigned char family, pad[15];
        } req = {.h = {.nlmsg_len = sizeof(req), .nlmsg_type = types[t], .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP, .nlmsg_seq = 1}};
        send(fd, &req, sizeof(req), 0);
        for (int done = 0; !done;) {
            char buf[16384];
            int n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0)
                break;
            for (int off = 0; off + (int) sizeof(struct nlmsghdr) <= n;) {
                struct nlmsghdr *h = (struct nlmsghdr *) (buf + off);
                if (h->nlmsg_len < sizeof(*h) || off + (int) h->nlmsg_len > n || h->nlmsg_type == NLMSG_DONE ||
                        h->nlmsg_type == NLMSG_ERROR) {
                    done = 1;
                    break;
                }
                for (unsigned i = sizeof(*h); i < h->nlmsg_len; i++)
                    hash = hash * 33 + (unsigned char) buf[off + i];
                off += (h->nlmsg_len + 3) & ~3;
            }
        }
    }
    close(fd);
    return hash;
}

int main(void) {
    int tracker = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    struct sockaddr_nl addr = {.nl_family = AF_NETLINK, .nl_groups = RTMGRP_LINK | RTMGRP_IPV4_IFADDR | RTMGRP_IPV6_IFADDR};
    CHECK(bind(tracker, (struct sockaddr *) &addr, sizeof(addr)) == 0, "bind with nl_groups");
    struct sockaddr_nl name = {0};
    socklen_t len = sizeof(name);
    getsockname(tracker, (struct sockaddr *) &name, &len);
    CHECK(name.nl_groups == addr.nl_groups, "getsockname reports the groups %#x", name.nl_groups);

    int member = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    int group = RTNLGRP_IPV4_ROUTE;
    CHECK(setsockopt(member, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &group, sizeof(group)) == 0, "NETLINK_ADD_MEMBERSHIP");
    len = sizeof(name);
    getsockname(member, (struct sockaddr *) &name, &len);
    CHECK(name.nl_groups == 1u << (group - 1), "joined group %d: %#x", group, name.nl_groups);
    group = 0;
    int r = setsockopt(member, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &group, sizeof(group));
    CHECK(r == -1 && errno == EINVAL, "group 0: %d errno %d", r, errno);
    group = 40;
    CHECK(setsockopt(member, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &group, sizeof(group)) == 0, "group 40 is accepted");

    // a request on a subscribed socket still gets its own reply
    struct {
        struct nlmsghdr h;
        unsigned char family, pad[15];
    } req = {.h = {.nlmsg_len = sizeof(req), .nlmsg_type = RTM_GETLINK, .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP, .nlmsg_seq = 9}};
    send(tracker, &req, sizeof(req), 0);
    char buf[16384];
    r = recv(tracker, buf, sizeof(buf), 0);
    CHECK(r > (int) sizeof(struct nlmsghdr) && ((struct nlmsghdr *) buf)->nlmsg_seq == 9, "dump reply on the subscribed socket: %d bytes", r);
    while (recv(tracker, buf, sizeof(buf), MSG_DONTWAIT) > 0) {
    }

    // while the host's network stays the same nothing may arrive; a real change during the
    // poll (a network switch) makes the check moot
    unsigned long before = network_state();
    struct pollfd fds[2] = {{.fd = tracker, .events = POLLIN}, {.fd = member, .events = POLLIN}};
    r = poll(fds, 2, 5000);
    if (r != 0 && network_state() != before)
        printf("SKIP: the host's network changed during the poll\n");
    else
        CHECK(r == 0, "no notification in 5 s without a network change: poll = %d", r);

    group = RTNLGRP_IPV4_ROUTE;
    CHECK(setsockopt(member, SOL_NETLINK, NETLINK_DROP_MEMBERSHIP, &group, sizeof(group)) == 0, "NETLINK_DROP_MEMBERSHIP");
    len = sizeof(name);
    getsockname(member, (struct sockaddr *) &name, &len);
    CHECK(name.nl_groups == 0, "left the group: %#x", name.nl_groups);
    close(member);
    close(tracker);
    return failures != 0;
}
