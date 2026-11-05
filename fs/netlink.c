#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <pthread.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#ifdef __APPLE__
#include <net/if_dl.h>
#include <net/if_types.h>
#include <sys/sysctl.h>
#endif
#include "kernel/calls.h"
#include "fs/fd.h"
#include "fs/netlink.h"
#include "fs/sock.h"
#include "fs/proc.h"

// A minimal NETLINK_ROUTE: enough for getifaddrs(), if_nameindex(), address
// enumeration in runtimes (libuv, Chromium), finding the default route
// (sing-box, Tailscale, ip route) and hearing when the network changes. Requests are answered
// synchronously from the host's getifaddrs(); replies are queued on a host
// datagram socketpair, so recv/poll/nonblocking behave like a real socket.

// The host's interfaces, read again at most once a second. Chromium and libuv ask
// for them dozens of times while starting (netlink dumps, SIOCGIF* ioctls), and
// each answer was a getifaddrs() plus an if_nametoindex() (sysctls) per interface:
// about 3% of VS Code's start-up. /proc/net/dev still reads fresh counters.
static lock_t ifcache_lock = LOCK_INITIALIZER;
static struct ifaddrs *ifcache;
static struct timespec ifcache_time;
static struct {
    char name[IFNAMSIZ];
    unsigned index;
} ifcache_index[64];
static unsigned ifcache_nindex;

// Locks the cache; ifaddrs_put unlocks it. NULL if the host has no answer.
static struct ifaddrs *ifaddrs_get(void) {
    lock(&ifcache_lock);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (ifcache == NULL || now.tv_sec - ifcache_time.tv_sec > 1 ||
            (now.tv_sec - ifcache_time.tv_sec == 1 && now.tv_nsec >= ifcache_time.tv_nsec)) {
        struct ifaddrs *fresh;
        if (getifaddrs(&fresh) == 0) {
            if (ifcache != NULL)
                freeifaddrs(ifcache);
            ifcache = fresh;
            ifcache_time = now;
            ifcache_nindex = 0;
            for (struct ifaddrs *ifa = ifcache; ifa != NULL; ifa = ifa->ifa_next) {
                bool known = false;
                for (unsigned i = 0; i < ifcache_nindex && !known; i++)
                    known = strncmp(ifcache_index[i].name, ifa->ifa_name, IFNAMSIZ) == 0;
                if (known || ifcache_nindex == sizeof(ifcache_index) / sizeof(ifcache_index[0]))
                    continue;
                strncpy(ifcache_index[ifcache_nindex].name, ifa->ifa_name, IFNAMSIZ - 1);
                ifcache_index[ifcache_nindex].name[IFNAMSIZ - 1] = '\0';
                ifcache_index[ifcache_nindex].index = if_nametoindex(ifa->ifa_name);
                ifcache_nindex++;
            }
        }
    }
    return ifcache;
}

static void ifaddrs_put(void) {
    unlock(&ifcache_lock);
}

// if_nametoindex from the cache; ifcache_lock held
static unsigned cached_ifindex(const char *name) {
    for (unsigned i = 0; i < ifcache_nindex; i++)
        if (strncmp(ifcache_index[i].name, name, IFNAMSIZ) == 0)
            return ifcache_index[i].index;
    return if_nametoindex(name);
}

#define NLMSG_NOOP_ 1
#define NLMSG_ERROR_ 2
#define NLMSG_DONE_ 3
#define NLM_F_REQUEST_ 0x1
#define NLM_F_MULTI_ 0x2
#define NLM_F_ACK_ 0x4
#define NLM_F_DUMP_ 0x300

#define RTM_BASE_ 16
#define RTM_GETLINK_ 18
#define RTM_NEWLINK_ 16
#define RTM_GETADDR_ 22
#define RTM_NEWADDR_ 20
#define RTM_NEWROUTE_ 24
#define RTM_GETROUTE_ 26
#define RTM_MAX_ 127

#define IFLA_ADDRESS_ 1
#define IFLA_BROADCAST_ 2
#define IFLA_IFNAME_ 3
#define IFLA_MTU_ 4
#define IFLA_TXQLEN_ 13
#define IFLA_OPERSTATE_ 16

#define RTA_DST_ 1
#define RTA_OIF_ 4
#define RTA_GATEWAY_ 5
#define RTA_PREFSRC_ 7
#define RTA_TABLE_ 15
#define RT_TABLE_MAIN_ 254
#define RTPROT_KERNEL_ 2
#define RTPROT_BOOT_ 3
#define RTN_UNICAST_ 1

#define IFA_ADDRESS_ 1
#define IFA_LOCAL_ 2
#define IFA_LABEL_ 3
#define IFA_BROADCAST_ 4

#define IFF_UP_ 0x1
#define IFF_BROADCAST_ 0x2
#define IFF_LOOPBACK_ 0x8
#define IFF_POINTOPOINT_ 0x10
#define IFF_RUNNING_ 0x40
#define IFF_NOARP_ 0x80
#define IFF_PROMISC_ 0x100
#define IFF_ALLMULTI_ 0x200
#define IFF_MULTICAST_ 0x1000
#define IFF_LOWER_UP_ 0x10000

#define ARPHRD_ETHER_ 1
#define ARPHRD_NONE_ 0xfffe
#define ARPHRD_LOOPBACK_ 772
#define IF_OPER_DOWN_ 2
#define IF_OPER_UP_ 6
#define IFA_F_PERMANENT_ 0x80
#define RT_SCOPE_UNIVERSE_ 0
#define RT_SCOPE_LINK_ 253
#define RT_SCOPE_HOST_ 254

#define NETLINK_ROUTE_ 0
#define SOL_NETLINK_ 270

struct nlmsghdr_ {
    uint32_t len;
    uint16_t type;
    uint16_t flags;
    uint32_t seq;
    uint32_t pid;
};

struct ifinfomsg_ {
    uint8_t family;
    uint8_t pad;
    uint16_t type;
    int32_t index;
    uint32_t flags;
    uint32_t change;
};

struct ifaddrmsg_ {
    uint8_t family;
    uint8_t prefixlen;
    uint8_t flags;
    uint8_t scope;
    uint32_t index;
};

struct rtmsg_ {
    uint8_t family;
    uint8_t dst_len;
    uint8_t src_len;
    uint8_t tos;
    uint8_t table;
    uint8_t protocol;
    uint8_t scope;
    uint8_t type;
    uint32_t flags;
};

struct rtattr_ {
    uint16_t len;
    uint16_t type;
};

#define NL_ALIGN(len) (((len) + 3) & ~3)
// Linux sizes dump chunks to about a page; staying under that keeps readers
// with small buffers (musl uses 8 KB) from truncating a datagram.
#define NL_CHUNK 4096

struct nl_reply {
    char buf[NL_CHUNK];
    size_t used;
    size_t msg_start;
    int peer;
    uint32_t seq;
    uint32_t pid;
};

static void reply_flush(struct nl_reply *r) {
    if (r->used == 0)
        return;
    send(r->peer, r->buf, r->used, 0);
    r->used = 0;
}

static void reply_begin(struct nl_reply *r, uint16_t type, uint16_t flags, size_t max_payload) {
    if (r->used + NL_ALIGN(sizeof(struct nlmsghdr_)) + max_payload > NL_CHUNK)
        reply_flush(r);
    r->msg_start = r->used;
    struct nlmsghdr_ hdr = {.type = type, .flags = flags, .seq = r->seq, .pid = r->pid};
    memcpy(r->buf + r->used, &hdr, sizeof(hdr));
    r->used += NL_ALIGN(sizeof(hdr));
}

static void reply_put(struct nl_reply *r, const void *data, size_t len) {
    memcpy(r->buf + r->used, data, len);
    memset(r->buf + r->used + len, 0, NL_ALIGN(len) - len);
    r->used += NL_ALIGN(len);
}

static void reply_attr(struct nl_reply *r, uint16_t type, const void *data, size_t len) {
    struct rtattr_ attr = {.len = sizeof(attr) + len, .type = type};
    reply_put(r, &attr, sizeof(attr));
    reply_put(r, data, len);
}

static void reply_end(struct nl_reply *r) {
    uint32_t len = r->used - r->msg_start;
    memcpy(r->buf + r->msg_start, &len, sizeof(len));
}

static void reply_error(struct nl_reply *r, int err, const struct nlmsghdr_ *req) {
    reply_begin(r, NLMSG_ERROR_, 0, sizeof(int32_t) + sizeof(*req));
    int32_t error = err;
    reply_put(r, &error, sizeof(error));
    reply_put(r, req, sizeof(*req));
    reply_end(r);
}

static void reply_done(struct nl_reply *r) {
    reply_begin(r, NLMSG_DONE_, NLM_F_MULTI_, sizeof(int32_t));
    int32_t zero = 0;
    reply_put(r, &zero, sizeof(zero));
    reply_end(r);
}

// Linux tools expect the loopback interface to be called "lo".
static const char *guest_ifname(const char *name, unsigned flags) {
    if (flags & IFF_LOOPBACK)
        return "lo";
    return name;
}

static uint32_t flags_from_real(unsigned real) {
    uint32_t flags = 0;
    if (real & IFF_UP) flags |= IFF_UP_;
    if (real & IFF_BROADCAST) flags |= IFF_BROADCAST_;
    if (real & IFF_LOOPBACK) flags |= IFF_LOOPBACK_;
    if (real & IFF_POINTOPOINT) flags |= IFF_POINTOPOINT_;
    if (real & IFF_RUNNING) flags |= IFF_RUNNING_ | IFF_LOWER_UP_;
    if (real & IFF_NOARP) flags |= IFF_NOARP_;
    if (real & IFF_PROMISC) flags |= IFF_PROMISC_;
    if (real & IFF_ALLMULTI) flags |= IFF_ALLMULTI_;
    if (real & IFF_MULTICAST) flags |= IFF_MULTICAST_;
    return flags;
}

static bool ifa_is_link(struct ifaddrs *ifa) {
#ifdef __APPLE__
    return ifa->ifa_addr != NULL && ifa->ifa_addr->sa_family == AF_LINK;
#else
    return ifa->ifa_addr != NULL && ifa->ifa_addr->sa_family == AF_PACKET;
#endif
}

struct link_info {
    uint16_t type; // ARPHRD_*
    uint8_t mac[6];
    size_t mac_len;
    uint32_t mtu;
};

static void link_info(struct ifaddrs *ifa, struct link_info *link) {
    *link = (struct link_info) {
        .type = ifa->ifa_flags & IFF_LOOPBACK ? ARPHRD_LOOPBACK_ : ARPHRD_ETHER_,
        .mtu = 1500,
    };
#ifdef __APPLE__
    struct sockaddr_dl *dl = (struct sockaddr_dl *) ifa->ifa_addr;
    if (dl->sdl_alen == sizeof(link->mac)) {
        memcpy(link->mac, LLADDR(dl), sizeof(link->mac));
        link->mac_len = sizeof(link->mac);
    } else if (!(ifa->ifa_flags & IFF_LOOPBACK)) {
        link->type = ARPHRD_NONE_; // tunnels and other links without a MAC
    }
    if (ifa->ifa_data != NULL)
        link->mtu = ((struct if_data *) ifa->ifa_data)->ifi_mtu;
#endif
    if (ifa->ifa_flags & IFF_LOOPBACK)
        link->mac_len = sizeof(link->mac); // all zeroes, like Linux
}

static void dump_link(struct nl_reply *r, struct ifaddrs *ifa, uint16_t type, uint16_t flags, unsigned index) {
    const char *name = guest_ifname(ifa->ifa_name, ifa->ifa_flags);
    struct ifinfomsg_ info = {
        .index = index,
        .flags = flags_from_real(ifa->ifa_flags),
        .change = 0xffffffff,
    };
    struct link_info link;
    link_info(ifa, &link);
    info.type = link.type;

    reply_begin(r, type, flags, 256);
    reply_put(r, &info, sizeof(info));
    reply_attr(r, IFLA_IFNAME_, name, strlen(name) + 1);
    reply_attr(r, IFLA_MTU_, &link.mtu, sizeof(link.mtu));
    uint32_t txqlen = 1000;
    reply_attr(r, IFLA_TXQLEN_, &txqlen, sizeof(txqlen));
    uint8_t operstate = ifa->ifa_flags & IFF_RUNNING ? IF_OPER_UP_ : IF_OPER_DOWN_;
    reply_attr(r, IFLA_OPERSTATE_, &operstate, sizeof(operstate));
    if (link.mac_len != 0) {
        reply_attr(r, IFLA_ADDRESS_, link.mac, link.mac_len);
        uint8_t bcast[6];
        memset(bcast, ifa->ifa_flags & IFF_LOOPBACK ? 0 : 0xff, sizeof(bcast));
        reply_attr(r, IFLA_BROADCAST_, bcast, sizeof(bcast));
    }
    reply_end(r);
}

static int prefix_len(const uint8_t *mask, size_t len) {
    int bits = 0;
    for (size_t i = 0; i < len; i++)
        for (int b = 7; b >= 0 && (mask[i] >> b) & 1; b--)
            bits++;
    return bits;
}

static void dump_addr(struct nl_reply *r, struct ifaddrs *ifa, int family, uint16_t type, uint16_t flags, unsigned index) {
    const char *name = guest_ifname(ifa->ifa_name, ifa->ifa_flags);
    struct ifaddrmsg_ msg = {.flags = IFA_F_PERMANENT_, .index = index};
    reply_begin(r, type, flags, 128);
    if (family == AF_INET) {
        struct sockaddr_in *addr = (struct sockaddr_in *) ifa->ifa_addr;
        struct sockaddr_in *mask = (struct sockaddr_in *) ifa->ifa_netmask;
        msg.family = AF_INET_;
        msg.prefixlen = mask ? prefix_len((uint8_t *) &mask->sin_addr, 4) : 32;
        msg.scope = ifa->ifa_flags & IFF_LOOPBACK ? RT_SCOPE_HOST_ : RT_SCOPE_UNIVERSE_;
        reply_put(r, &msg, sizeof(msg));
        const struct in_addr *peer = &addr->sin_addr;
        if ((ifa->ifa_flags & IFF_POINTOPOINT) && ifa->ifa_dstaddr != NULL)
            peer = &((struct sockaddr_in *) ifa->ifa_dstaddr)->sin_addr;
        reply_attr(r, IFA_ADDRESS_, peer, 4);
        reply_attr(r, IFA_LOCAL_, &addr->sin_addr, 4);
        if ((ifa->ifa_flags & IFF_BROADCAST) && ifa->ifa_broadaddr != NULL)
            reply_attr(r, IFA_BROADCAST_, &((struct sockaddr_in *) ifa->ifa_broadaddr)->sin_addr, 4);
        reply_attr(r, IFA_LABEL_, name, strlen(name) + 1);
    } else {
        struct sockaddr_in6 *addr = (struct sockaddr_in6 *) ifa->ifa_addr;
        struct sockaddr_in6 *mask = (struct sockaddr_in6 *) ifa->ifa_netmask;
        struct in6_addr in6 = addr->sin6_addr;
        msg.family = AF_INET6_;
        msg.prefixlen = mask ? prefix_len((uint8_t *) &mask->sin6_addr, 16) : 128;
        if (IN6_IS_ADDR_LINKLOCAL(&in6)) {
            // KAME embeds the scope id in bytes 2-3 of link-local addresses
            in6.s6_addr[2] = in6.s6_addr[3] = 0;
            msg.scope = RT_SCOPE_LINK_;
        } else if (IN6_IS_ADDR_LOOPBACK(&in6)) {
            msg.scope = RT_SCOPE_HOST_;
        } else {
            msg.scope = RT_SCOPE_UNIVERSE_;
        }
        reply_put(r, &msg, sizeof(msg));
        reply_attr(r, IFA_ADDRESS_, &in6, 16);
    }
    reply_end(r);
}

static int handle_getlink(struct nl_reply *r, const struct nlmsghdr_ *req, const char *payload, size_t payload_len) {
    struct ifaddrs *ifas = ifaddrs_get();
    if (ifas == NULL) {
        ifaddrs_put();
        return _ENOBUFS;
    }
    int err = 0;
    if (req->flags & NLM_F_DUMP_) {
        for (struct ifaddrs *ifa = ifas; ifa != NULL; ifa = ifa->ifa_next)
            if (ifa_is_link(ifa))
                dump_link(r, ifa, RTM_NEWLINK_, NLM_F_MULTI_, cached_ifindex(ifa->ifa_name));
        reply_done(r);
    } else {
        struct ifinfomsg_ want = {0};
        memcpy(&want, payload, payload_len < sizeof(want) ? payload_len : sizeof(want));
        bool found = false;
        for (struct ifaddrs *ifa = ifas; ifa != NULL && !found; ifa = ifa->ifa_next) {
            if (ifa_is_link(ifa) && (int) cached_ifindex(ifa->ifa_name) == want.index) {
                dump_link(r, ifa, RTM_NEWLINK_, 0, want.index);
                found = true;
            }
        }
        if (!found)
            err = _ENODEV;
    }
    ifaddrs_put();
    return err;
}

static int handle_getaddr(struct nl_reply *r, const struct nlmsghdr_ *req, const char *payload, size_t payload_len) {
    if (!(req->flags & NLM_F_DUMP_))
        return _EOPNOTSUPP;
    struct ifaddrmsg_ want = {0};
    memcpy(&want, payload, payload_len < sizeof(want) ? payload_len : sizeof(want));
    if (want.family != AF_INET_ && want.family != AF_INET6_)
        want.family = 0; // like Linux, a dump for a family it has no table for dumps them all
    struct ifaddrs *ifas = ifaddrs_get();
    if (ifas == NULL) {
        ifaddrs_put();
        return _ENOBUFS;
    }
    // Linux lists all IPv4 addresses before the IPv6 ones
    static const int families[] = {AF_INET, AF_INET6};
    for (unsigned i = 0; i < sizeof(families) / sizeof(families[0]); i++) {
        int family = families[i];
        if (want.family != 0 && want.family != (family == AF_INET ? AF_INET_ : AF_INET6_))
            continue;
        for (struct ifaddrs *ifa = ifas; ifa != NULL; ifa = ifa->ifa_next)
            if (ifa->ifa_addr != NULL && ifa->ifa_addr->sa_family == family)
                dump_addr(r, ifa, family, RTM_NEWADDR_, NLM_F_MULTI_, cached_ifindex(ifa->ifa_name));
    }
    reply_done(r);
    ifaddrs_put();
    return 0;
}

// The main routing table, as far as a guest can see it: the host's default
// route and a connected route for each interface address.
struct route {
    int family; // the host's AF_INET or AF_INET6
    uint8_t dst[16];
    uint8_t dst_len;
    uint8_t gateway[16];
    bool has_gateway;
    uint8_t prefsrc[16];
    bool has_prefsrc;
    unsigned oif;
    uint8_t scope;
    uint8_t protocol;
};

static size_t family_addr_len(int family) {
    return family == AF_INET ? 4 : 16;
}

static const uint8_t *sockaddr_bytes(const struct sockaddr *sa) {
    if (sa->sa_family == AF_INET)
        return (const uint8_t *) &((const struct sockaddr_in *) sa)->sin_addr;
    return ((const struct sockaddr_in6 *) sa)->sin6_addr.s6_addr;
}

static bool bytes_zero(const uint8_t *bytes, size_t len) {
    for (size_t i = 0; i < len; i++)
        if (bytes[i] != 0)
            return false;
    return true;
}

// KAME embeds the scope id in bytes 2-3 of link-local addresses
static void clear_kame_scope(uint8_t *addr) {
    if (addr[0] == 0xfe && (addr[1] & 0xc0) == 0x80)
        addr[2] = addr[3] = 0;
}

#ifdef __APPLE__
// <net/route.h> is not in the iOS SDK; these are Darwin's.
struct darwin_rt_metrics {
    uint32_t locks, mtu, hopcount;
    int32_t expire;
    uint32_t recvpipe, sendpipe, ssthresh, rtt, rttvar, pksent, filler[4];
};
struct darwin_rt_msghdr {
    unsigned short msglen;
    unsigned char version, type;
    unsigned short index;
    int flags, addrs;
    pid_t pid;
    int seq, error, use;
    uint32_t inits;
    struct darwin_rt_metrics rmx;
};
#define DARWIN_RTF_UP 0x1
#define DARWIN_RTF_IFSCOPE 0x1000000
#define DARWIN_RTAX_DST 0
#define DARWIN_RTAX_GATEWAY 1
#define DARWIN_RTAX_NETMASK 2
#define DARWIN_RTAX_MAX 8
#define DARWIN_SA_SIZE(len) ((len) > 0 ? 1 + (((len) - 1) | (sizeof(uint32_t) - 1)) : sizeof(uint32_t))

// The host's unscoped default route for family, from its routing table.
static bool host_default_route(int family, struct route *rt) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, family, NET_RT_DUMP, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0)
        return false;
    len += len / 4; // routes can be added in between
    char *buf = malloc(len);
    if (buf == NULL)
        return false;
    if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
        free(buf);
        return false;
    }
    bool found = false;
    for (size_t off = 0; !found && off + sizeof(struct darwin_rt_msghdr) <= len;) {
        struct darwin_rt_msghdr *rtm = (struct darwin_rt_msghdr *) (buf + off);
        if (rtm->msglen == 0 || off + rtm->msglen > len)
            break;
        off += rtm->msglen;
        const struct sockaddr *sa[DARWIN_RTAX_MAX] = {NULL};
        size_t pos = sizeof(*rtm);
        for (int i = 0; i < DARWIN_RTAX_MAX && pos < rtm->msglen; i++) {
            if (!(rtm->addrs & (1 << i)))
                continue;
            sa[i] = (const struct sockaddr *) ((char *) rtm + pos);
            pos += DARWIN_SA_SIZE(sa[i]->sa_len);
        }
        const struct sockaddr *dst = sa[DARWIN_RTAX_DST], *mask = sa[DARWIN_RTAX_NETMASK];
        if (!(rtm->flags & DARWIN_RTF_UP) || (rtm->flags & DARWIN_RTF_IFSCOPE) || rtm->index == 0 ||
                dst == NULL || dst->sa_family != family || !bytes_zero(sockaddr_bytes(dst), family_addr_len(family)))
            continue;
        // a routing message's netmask is cut after its last nonzero byte
        if (mask != NULL && mask->sa_len > 2 && !bytes_zero((const uint8_t *) mask + 2, mask->sa_len - 2))
            continue;
        *rt = (struct route) {.family = family, .oif = rtm->index, .protocol = RTPROT_BOOT_};
        const struct sockaddr *gw = sa[DARWIN_RTAX_GATEWAY];
        if (gw != NULL && gw->sa_family == family) {
            memcpy(rt->gateway, sockaddr_bytes(gw), family_addr_len(family));
            if (family == AF_INET6)
                clear_kame_scope(rt->gateway);
            rt->has_gateway = true;
        }
        found = true;
    }
    free(buf);
    return found;
}
#else
static bool host_default_route(int family, struct route *rt) {
    (void) family;
    (void) rt;
    return false;
}
#endif

static bool global_address(const struct sockaddr *sa) {
    const uint8_t *a = sockaddr_bytes(sa);
    if (sa->sa_family == AF_INET)
        return !(a[0] == 169 && a[1] == 254) && a[0] != 127 && a[0] != 0;
    return (a[0] & 0xe0) == 0x20; // 2000::/3
}

// Without the host's table: the first interface with a global address,
// Wi-Fi or Ethernet before cellular before anything else. ifcache_lock held.
static bool guess_default_route(struct ifaddrs *ifas, int family, struct route *rt) {
    static const char *const prefixes[] = {"en", "pdp_ip", ""};
    for (unsigned p = 0; p < sizeof(prefixes) / sizeof(prefixes[0]); p++) {
        for (struct ifaddrs *ifa = ifas; ifa != NULL; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != family ||
                    (ifa->ifa_flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) != (IFF_UP | IFF_RUNNING) ||
                    strncmp(ifa->ifa_name, prefixes[p], strlen(prefixes[p])) != 0 || !global_address(ifa->ifa_addr))
                continue;
            *rt = (struct route) {.family = family, .oif = cached_ifindex(ifa->ifa_name), .protocol = RTPROT_BOOT_};
            return rt->oif != 0;
        }
    }
    return false;
}

#define MAX_ROUTES 64

// The table for family (the host's AF_INET or AF_INET6), default route
// first. ifcache_lock held.
static unsigned collect_routes(struct ifaddrs *ifas, int family, struct route *routes) {
    unsigned n = 0;
    if (host_default_route(family, &routes[n]) || guess_default_route(ifas, family, &routes[n]))
        n++;
    size_t alen = family_addr_len(family);
    for (struct ifaddrs *ifa = ifas; ifa != NULL && n < MAX_ROUTES; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != family ||
                !(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;
        struct route rt = {
            .family = family, .oif = cached_ifindex(ifa->ifa_name),
            .scope = RT_SCOPE_LINK_, .protocol = RTPROT_KERNEL_,
        };
        uint8_t addr[16];
        memcpy(addr, sockaddr_bytes(ifa->ifa_addr), alen);
        if (family == AF_INET6)
            clear_kame_scope(addr);
        if (family == AF_INET && (ifa->ifa_flags & IFF_POINTOPOINT) && ifa->ifa_dstaddr != NULL) {
            memcpy(rt.dst, sockaddr_bytes(ifa->ifa_dstaddr), alen);
            rt.dst_len = 32;
        } else {
            const uint8_t *mask = ifa->ifa_netmask ? sockaddr_bytes(ifa->ifa_netmask) : NULL;
            rt.dst_len = mask ? prefix_len(mask, alen) : alen * 8;
            for (size_t i = 0; i < alen; i++)
                rt.dst[i] = mask ? addr[i] & mask[i] : addr[i];
        }
        if (rt.dst_len == 0 || rt.oif == 0)
            continue;
        if (family == AF_INET) {
            memcpy(rt.prefsrc, addr, alen);
            rt.has_prefsrc = true;
        }
        bool seen = false;
        for (unsigned i = 0; i < n && !seen; i++)
            seen = routes[i].dst_len == rt.dst_len && routes[i].oif == rt.oif &&
                memcmp(routes[i].dst, rt.dst, alen) == 0;
        if (!seen)
            routes[n++] = rt;
    }
    return n;
}

static void dump_route(struct nl_reply *r, const struct route *rt, uint16_t type, uint16_t flags) {
    struct rtmsg_ msg = {
        .family = rt->family == AF_INET ? AF_INET_ : AF_INET6_,
        .dst_len = rt->dst_len, .table = RT_TABLE_MAIN_,
        .protocol = rt->protocol, .scope = rt->scope, .type = RTN_UNICAST_,
    };
    size_t alen = family_addr_len(rt->family);
    reply_begin(r, type, flags, 128);
    reply_put(r, &msg, sizeof(msg));
    uint32_t table = RT_TABLE_MAIN_;
    reply_attr(r, RTA_TABLE_, &table, sizeof(table));
    if (rt->dst_len != 0)
        reply_attr(r, RTA_DST_, rt->dst, alen);
    if (rt->has_prefsrc)
        reply_attr(r, RTA_PREFSRC_, rt->prefsrc, alen);
    if (rt->has_gateway)
        reply_attr(r, RTA_GATEWAY_, rt->gateway, alen);
    uint32_t oif = rt->oif;
    reply_attr(r, RTA_OIF_, &oif, sizeof(oif));
    reply_end(r);
}

static bool route_matches(const struct route *rt, const uint8_t *addr) {
    unsigned full = rt->dst_len / 8, rest = rt->dst_len % 8;
    if (memcmp(rt->dst, addr, full) != 0)
        return false;
    return rest == 0 || ((rt->dst[full] ^ addr[full]) & (0xff << (8 - rest))) == 0;
}

// A dump of the table, or (ip route get) the route a destination takes.
static int handle_getroute(struct nl_reply *r, const struct nlmsghdr_ *req, const char *payload, size_t payload_len) {
    struct rtmsg_ want = {0};
    memcpy(&want, payload, payload_len < sizeof(want) ? payload_len : sizeof(want));
    bool dump = (req->flags & NLM_F_DUMP_) == NLM_F_DUMP_;
    // Like Linux, a dump for a family it has no table for dumps them all. The
    // netlink library sing-box and Tailscale use asks for family 255.
    if (dump && want.family != AF_INET_ && want.family != AF_INET6_)
        want.family = 0;
    uint8_t dst[16] = {0};
    if (!dump) {
        if (want.family != AF_INET_ && want.family != AF_INET6_)
            return _EINVAL;
        size_t alen = want.family == AF_INET_ ? 4 : 16;
        for (size_t off = NL_ALIGN(sizeof(want)); off + sizeof(struct rtattr_) <= payload_len;) {
            struct rtattr_ attr;
            memcpy(&attr, payload + off, sizeof(attr));
            if (attr.len < sizeof(attr) || off + attr.len > payload_len)
                break;
            if (attr.type == RTA_DST_ && attr.len - sizeof(attr) >= alen)
                memcpy(dst, payload + off + sizeof(attr), alen);
            off += NL_ALIGN(attr.len);
        }
    }
    struct ifaddrs *ifas = ifaddrs_get();
    if (ifas == NULL) {
        ifaddrs_put();
        return _ENOBUFS;
    }
    struct route routes[MAX_ROUTES];
    int err = 0;
    static const int families[] = {AF_INET, AF_INET6};
    for (unsigned f = 0; f < sizeof(families) / sizeof(families[0]); f++) {
        int family = families[f];
        uint8_t guest_family = family == AF_INET ? AF_INET_ : AF_INET6_;
        if (want.family != 0 && want.family != guest_family)
            continue;
        unsigned n = collect_routes(ifas, family, routes);
        if (dump) {
            for (unsigned i = 0; i < n; i++)
                dump_route(r, &routes[i], RTM_NEWROUTE_, NLM_F_MULTI_);
            continue;
        }
        // the longest matching prefix; the default route matches everything
        const struct route *best = NULL;
        for (unsigned i = 0; i < n; i++)
            if (route_matches(&routes[i], dst) && (best == NULL || routes[i].dst_len > best->dst_len))
                best = &routes[i];
        if (best == NULL) {
            err = _ENETUNREACH;
            break;
        }
        struct route answer = *best;
        size_t alen = family_addr_len(family);
        memcpy(answer.dst, dst, alen);
        answer.dst_len = alen * 8;
        if (!answer.has_prefsrc) {
            for (struct ifaddrs *ifa = ifas; ifa != NULL; ifa = ifa->ifa_next) {
                if (ifa->ifa_addr != NULL && ifa->ifa_addr->sa_family == family &&
                        cached_ifindex(ifa->ifa_name) == answer.oif && global_address(ifa->ifa_addr)) {
                    memcpy(answer.prefsrc, sockaddr_bytes(ifa->ifa_addr), alen);
                    answer.has_prefsrc = true;
                    break;
                }
            }
        }
        dump_route(r, &answer, RTM_NEWROUTE_, 0);
    }
    if (dump)
        reply_done(r);
    ifaddrs_put();
    return err;
}

static void handle_request(struct nl_reply *r, const struct nlmsghdr_ *req, const char *payload, size_t payload_len) {
    r->seq = req->seq;
    if (req->type == NLMSG_NOOP_ || req->type == NLMSG_DONE_ || req->type == NLMSG_ERROR_)
        return;
    bool is_get = req->type >= RTM_BASE_ && req->type <= RTM_MAX_ && req->type % 4 == 2;
    bool is_dump = is_get && (req->flags & NLM_F_DUMP_) == NLM_F_DUMP_;
    int err;
    if (req->type == RTM_GETLINK_) {
        err = handle_getlink(r, req, payload, payload_len);
    } else if (req->type == RTM_GETADDR_) {
        err = handle_getaddr(r, req, payload, payload_len);
    } else if (req->type == RTM_GETROUTE_) {
        err = handle_getroute(r, req, payload, payload_len);
    } else if (is_dump) {
        // other dumps (neighbours, rules): an empty table
        reply_done(r);
        err = 0;
    } else if (req->type >= RTM_BASE_ && req->type <= RTM_MAX_ && !is_get) {
        err = _EPERM; // changing the host's network configuration
    } else {
        err = _EOPNOTSUPP;
    }
    // like netlink_rcv_skb: errors are always reported, successes only on
    // request, and a dump is acknowledged by its NLMSG_DONE
    if (err != 0 || ((req->flags & NLM_F_ACK_) && !is_dump))
        reply_error(r, err, req);
}

// ---- change notifications ----
// Sockets that joined RTMGRP_* groups (bind's nl_groups or
// NETLINK_ADD_MEMBERSHIP) get RTM_DELADDR/NEWADDR, RTM_NEWLINK/DELLINK and
// RTM_DELROUTE/NEWROUTE when the host's interfaces change, as the kernel sends
// them. Runtimes notice a network switch that way: Chromium (cronet, under
// sing-box's naive outbound) drops the connections made on the old network,
// sing-box and Tailscale move to the new default route. Without it they kept
// connections that would never answer again.
// Apple's peer-to-peer links (awdl, llw) and IPv6 link-local addresses come
// and go without the network changing, and are left out so as not to make
// runtimes drop good connections.

#define RTM_DELLINK_ 17
#define RTM_DELADDR_ 21
#define RTM_DELROUTE_ 25
#define RTMGRP_LINK_ 0x1
#define RTMGRP_IPV4_IFADDR_ 0x10
#define RTMGRP_IPV4_ROUTE_ 0x40
#define RTMGRP_IPV6_IFADDR_ 0x100
#define RTMGRP_IPV6_ROUTE_ 0x400
#define NETLINK_ADD_MEMBERSHIP_ 1
#define NETLINK_DROP_MEMBERSHIP_ 2
#define WATCH_INTERVAL_SECONDS 2

// The subscribed sockets; netlink_close takes a socket out before it is freed.
static pthread_mutex_t subscribers_lock = PTHREAD_MUTEX_INITIALIZER;
static struct fd **subscribers;
static size_t nsubscribers, capsubscribers;
static bool watcher_started;

static void *watch_interfaces(void *unused);

// subscribers_lock held
static void subscriber_remove(struct fd *sock) {
    for (size_t i = 0; i < nsubscribers; i++) {
        if (subscribers[i] == sock) {
            subscribers[i] = subscribers[--nsubscribers];
            return;
        }
    }
}

static void set_groups(struct fd *sock, uint32_t groups) {
    pthread_mutex_lock(&subscribers_lock);
    sock->socket.netlink_groups = groups;
    subscriber_remove(sock);
    if (groups != 0) {
        if (nsubscribers == capsubscribers) {
            size_t cap = capsubscribers ? capsubscribers * 2 : 8;
            struct fd **grown = realloc(subscribers, cap * sizeof(*grown));
            if (grown != NULL) {
                subscribers = grown;
                capsubscribers = cap;
            }
        }
        if (nsubscribers < capsubscribers)
            subscribers[nsubscribers++] = sock;
        if (!watcher_started) {
            pthread_t thread;
            if (pthread_create(&thread, NULL, watch_interfaces, NULL) == 0) {
                pthread_detach(thread);
                watcher_started = true;
            }
        }
    }
    pthread_mutex_unlock(&subscribers_lock);
}

void netlink_close(struct fd *sock) {
    pthread_mutex_lock(&subscribers_lock);
    subscriber_remove(sock);
    pthread_mutex_unlock(&subscribers_lock);
}

int netlink_setsockopt(struct fd *sock, int option, const void *value, size_t len) {
    if (option != NETLINK_ADD_MEMBERSHIP_ && option != NETLINK_DROP_MEMBERSHIP_)
        return 0; // the others change nothing that matters here
    int32_t group;
    if (len < sizeof(group))
        return _EINVAL;
    memcpy(&group, value, sizeof(group));
    if (group <= 0)
        return _EINVAL;
    if (group > 32)
        return 0; // nothing is sent to groups past the bitmask
    uint32_t bit = 1u << (group - 1);
    uint32_t groups = sock->socket.netlink_groups;
    set_groups(sock, option == NETLINK_ADD_MEMBERSHIP_ ? groups | bit : groups & ~bit);
    return 0;
}

#define WATCH_MAX 256

// The interfaces, their indexes and the default routes at one moment.
struct iface_state {
    struct ifaddrs *ifas;
    struct {
        char name[IFNAMSIZ];
        unsigned index;
    } index[64];
    unsigned nindex;
    struct route route[2]; // AF_INET, AF_INET6
    bool has_route[2];
};

static unsigned state_index(const struct iface_state *state, const char *name) {
    for (unsigned i = 0; i < state->nindex; i++)
        if (strncmp(state->index[i].name, name, IFNAMSIZ) == 0)
            return state->index[i].index;
    return 0;
}

static bool take_state(struct iface_state *state) {
    *state = (struct iface_state) {0};
    if (getifaddrs(&state->ifas) != 0)
        return false;
    for (struct ifaddrs *ifa = state->ifas; ifa != NULL; ifa = ifa->ifa_next) {
        if (state_index(state, ifa->ifa_name) != 0 || state->nindex == sizeof(state->index) / sizeof(state->index[0]))
            continue;
        strncpy(state->index[state->nindex].name, ifa->ifa_name, IFNAMSIZ - 1);
        state->index[state->nindex].index = if_nametoindex(ifa->ifa_name);
        state->nindex++;
    }
    state->has_route[0] = host_default_route(AF_INET, &state->route[0]);
    state->has_route[1] = host_default_route(AF_INET6, &state->route[1]);
    return true;
}

static void free_state(struct iface_state *state) {
    if (state->ifas != NULL)
        freeifaddrs(state->ifas);
    state->ifas = NULL;
}

static bool noisy_interface(const char *name) {
    return strncmp(name, "awdl", 4) == 0 || strncmp(name, "llw", 3) == 0;
}

static bool watched_addr(struct ifaddrs *ifa) {
    if (ifa->ifa_addr == NULL || (ifa->ifa_flags & IFF_LOOPBACK) || noisy_interface(ifa->ifa_name))
        return false;
    if (ifa->ifa_addr->sa_family == AF_INET)
        return true;
    return ifa->ifa_addr->sa_family == AF_INET6 &&
        !IN6_IS_ADDR_LINKLOCAL(&((struct sockaddr_in6 *) ifa->ifa_addr)->sin6_addr);
}

static bool watched_link(struct ifaddrs *ifa) {
    return ifa_is_link(ifa) && !(ifa->ifa_flags & IFF_LOOPBACK) && !noisy_interface(ifa->ifa_name);
}

static int addr_prefix(struct ifaddrs *ifa) {
    size_t len = family_addr_len(ifa->ifa_addr->sa_family);
    return ifa->ifa_netmask ? prefix_len(sockaddr_bytes(ifa->ifa_netmask), len) : (int) len * 8;
}

static bool same_addr(struct ifaddrs *a, struct ifaddrs *b) {
    return strcmp(a->ifa_name, b->ifa_name) == 0 && a->ifa_addr->sa_family == b->ifa_addr->sa_family &&
        memcmp(sockaddr_bytes(a->ifa_addr), sockaddr_bytes(b->ifa_addr), family_addr_len(a->ifa_addr->sa_family)) == 0 &&
        addr_prefix(a) == addr_prefix(b);
}

static struct ifaddrs *find_addr(struct ifaddrs *list, struct ifaddrs *want) {
    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next)
        if (watched_addr(ifa) && same_addr(ifa, want))
            return ifa;
    return NULL;
}

static struct ifaddrs *find_link(struct ifaddrs *list, const char *name) {
    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next)
        if (watched_link(ifa) && strcmp(ifa->ifa_name, name) == 0)
            return ifa;
    return NULL;
}

static bool same_route(const struct route *a, const struct route *b) {
    return a->oif == b->oif && a->has_gateway == b->has_gateway &&
        (!a->has_gateway || memcmp(a->gateway, b->gateway, family_addr_len(a->family)) == 0);
}

struct change {
    uint16_t type;
    uint32_t group;
    struct ifaddrs *ifa;          // addresses and links
    const struct route *route;    // routes
    unsigned index;
};

static unsigned diff_states(const struct iface_state *prev, const struct iface_state *cur, struct change *changes) {
    unsigned n = 0;
    for (struct ifaddrs *ifa = prev->ifas; ifa != NULL && n < WATCH_MAX; ifa = ifa->ifa_next)
        if (watched_addr(ifa) && find_addr(cur->ifas, ifa) == NULL)
            changes[n++] = (struct change) {RTM_DELADDR_, ifa->ifa_addr->sa_family == AF_INET ? RTMGRP_IPV4_IFADDR_ : RTMGRP_IPV6_IFADDR_,
                ifa, NULL, state_index(prev, ifa->ifa_name)};
    for (struct ifaddrs *ifa = prev->ifas; ifa != NULL && n < WATCH_MAX; ifa = ifa->ifa_next)
        if (watched_link(ifa) && find_link(cur->ifas, ifa->ifa_name) == NULL)
            changes[n++] = (struct change) {RTM_DELLINK_, RTMGRP_LINK_, ifa, NULL, state_index(prev, ifa->ifa_name)};
    for (struct ifaddrs *ifa = cur->ifas; ifa != NULL && n < WATCH_MAX; ifa = ifa->ifa_next) {
        if (!watched_link(ifa))
            continue;
        struct ifaddrs *before = find_link(prev->ifas, ifa->ifa_name);
        unsigned mask = IFF_UP | IFF_RUNNING;
        if (before == NULL || (before->ifa_flags & mask) != (ifa->ifa_flags & mask))
            changes[n++] = (struct change) {RTM_NEWLINK_, RTMGRP_LINK_, ifa, NULL, state_index(cur, ifa->ifa_name)};
    }
    for (struct ifaddrs *ifa = cur->ifas; ifa != NULL && n < WATCH_MAX; ifa = ifa->ifa_next)
        if (watched_addr(ifa) && find_addr(prev->ifas, ifa) == NULL)
            changes[n++] = (struct change) {RTM_NEWADDR_, ifa->ifa_addr->sa_family == AF_INET ? RTMGRP_IPV4_IFADDR_ : RTMGRP_IPV6_IFADDR_,
                ifa, NULL, state_index(cur, ifa->ifa_name)};
    for (int f = 0; f < 2 && n + 2 <= WATCH_MAX; f++) {
        uint32_t group = f == 0 ? RTMGRP_IPV4_ROUTE_ : RTMGRP_IPV6_ROUTE_;
        if (prev->has_route[f] == cur->has_route[f] && (!cur->has_route[f] || same_route(&prev->route[f], &cur->route[f])))
            continue;
        if (prev->has_route[f])
            changes[n++] = (struct change) {RTM_DELROUTE_, group, NULL, &prev->route[f], 0};
        if (cur->has_route[f])
            changes[n++] = (struct change) {RTM_NEWROUTE_, group, NULL, &cur->route[f], 0};
    }
    return n;
}

static void send_changes(const struct change *changes, unsigned n) {
    struct nl_reply *r = malloc(sizeof(*r));
    if (r == NULL)
        return;
    pthread_mutex_lock(&subscribers_lock);
    for (size_t s = 0; s < nsubscribers; s++) {
        struct fd *sock = subscribers[s];
        *r = (struct nl_reply) {.peer = sock->socket.netlink_peer};
        for (unsigned i = 0; i < n; i++) {
            const struct change *c = &changes[i];
            if (!(sock->socket.netlink_groups & c->group))
                continue;
            if (c->route != NULL)
                dump_route(r, c->route, c->type, 0);
            else if (c->type == RTM_NEWLINK_ || c->type == RTM_DELLINK_)
                dump_link(r, c->ifa, c->type, 0, c->index);
            else
                dump_addr(r, c->ifa, c->ifa->ifa_addr->sa_family, c->type, 0, c->index);
        }
        // a full receive queue loses the notification, as on Linux
        reply_flush(r);
    }
    pthread_mutex_unlock(&subscribers_lock);
    free(r);
}

static void *watch_interfaces(void *unused) {
    (void) unused;
    struct iface_state prev, cur;
    bool have_prev = take_state(&prev);
    struct change *changes = malloc(WATCH_MAX * sizeof(*changes));
    for (;;) {
        sleep(WATCH_INTERVAL_SECONDS);
        if (!take_state(&cur))
            continue;
        if (have_prev && changes != NULL) {
            unsigned n = diff_states(&prev, &cur, changes);
            if (n > 0)
                send_changes(changes, n);
            free_state(&prev);
        }
        prev = cur;
        have_prev = true;
    }
    return NULL;
}

int netlink_socket(int type, int protocol, int *real_fd) {
    if (protocol != NETLINK_ROUTE_)
        return _EAFNOSUPPORT;
    if (type != SOCK_RAW_ && type != SOCK_DGRAM_)
        return _ESOCKTNOSUPPORT;
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) < 0)
        return errno_map();
    int bufsize = 1024 * 1024;
    for (int i = 0; i < 2; i++) {
        setsockopt(sv[i], SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof(bufsize));
        setsockopt(sv[i], SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));
        fcntl(sv[i], F_SETFD, FD_CLOEXEC);
    }
    fcntl(sv[1], F_SETFL, O_NONBLOCK);
    *real_fd = sv[0];
    return sv[1];
}

static uint32_t netlink_port(struct fd *sock) {
    if (sock->socket.netlink_pid == 0)
        sock->socket.netlink_pid = current->tgid;
    return sock->socket.netlink_pid;
}

ssize_t netlink_send(struct fd *sock, const void *buf, size_t len) {
    struct nl_reply *r = malloc(sizeof(*r));
    if (r == NULL)
        return _ENOMEM;
    r->used = 0;
    r->peer = sock->socket.netlink_peer;
    r->pid = netlink_port(sock);
    size_t off = 0;
    while (off + sizeof(struct nlmsghdr_) <= len) {
        struct nlmsghdr_ req;
        memcpy(&req, (const char *) buf + off, sizeof(req));
        if (req.len < sizeof(req) || off + req.len > len)
            break;
        if (req.flags & NLM_F_REQUEST_)
            handle_request(r, &req, (const char *) buf + off + NL_ALIGN(sizeof(req)),
                    req.len - NL_ALIGN(sizeof(req)));
        off += NL_ALIGN(req.len);
    }
    reply_flush(r);
    free(r);
    return len;
}

int netlink_bind(struct fd *sock, const void *addr, size_t len) {
    struct sockaddr_nl_ nl;
    if (len < sizeof(nl))
        return _EINVAL;
    memcpy(&nl, addr, sizeof(nl));
    if (nl.family != AF_NETLINK_)
        return _EINVAL;
    if (nl.pid != 0)
        sock->socket.netlink_pid = nl.pid;
    netlink_port(sock);
    set_groups(sock, nl.groups);
    return 0;
}

void netlink_name(struct fd *sock, bool local, struct sockaddr_nl_ *addr) {
    *addr = (struct sockaddr_nl_) {.family = AF_NETLINK_};
    if (local) {
        addr->pid = netlink_port(sock);
        addr->groups = sock->socket.netlink_groups;
    }
}

bool netlink_sockopt_ignored(int level) {
    return level == SOL_NETLINK_;
}

// The SIOCGIF* socket ioctls (ifconfig, busybox ip, if_nametoindex), answered
// from the same host interface list as RTM_GETLINK/RTM_GETADDR.

#define SIOCGIFNAME_ 0x8910
#define SIOCGIFCONF_ 0x8912
#define SIOCGIFFLAGS_ 0x8913
#define SIOCSIFFLAGS_ 0x8914
#define SIOCGIFADDR_ 0x8915
#define SIOCSIFADDR_ 0x8916
#define SIOCGIFDSTADDR_ 0x8917
#define SIOCSIFDSTADDR_ 0x8918
#define SIOCGIFBRDADDR_ 0x8919
#define SIOCSIFBRDADDR_ 0x891a
#define SIOCGIFNETMASK_ 0x891b
#define SIOCSIFNETMASK_ 0x891c
#define SIOCGIFMETRIC_ 0x891d
#define SIOCSIFMETRIC_ 0x891e
#define SIOCGIFMTU_ 0x8921
#define SIOCSIFMTU_ 0x8922
#define SIOCSIFNAME_ 0x8923
#define SIOCSIFHWADDR_ 0x8924
#define SIOCGIFHWADDR_ 0x8927
#define SIOCGIFINDEX_ 0x8933
#define SIOCGIFTXQLEN_ 0x8942
#define SIOCSIFTXQLEN_ 0x8943
#define SIOCGIFMAP_ 0x8970
#define SIOCSIFMAP_ 0x8971

#define IFNAMSIZ_ 16
struct ifreq_ {
    char name[IFNAMSIZ_];
    union {
        struct sockaddr_ addr;
        int16_t flags;
        int32_t ivalue;
        // the union is as big as struct ifmap: two longs and a few bytes
        char map[sizeof(addr_t) == 8 ? 24 : 16];
    };
};

struct ifconf_ {
    int32_t len;
    addr_t buf;
};

ssize_t netlink_ifioctl_size(int cmd) {
    switch (cmd) {
        case SIOCGIFCONF_:
            return sizeof(struct ifconf_);
        case SIOCGIFNAME_: case SIOCGIFFLAGS_: case SIOCSIFFLAGS_:
        case SIOCGIFADDR_: case SIOCSIFADDR_: case SIOCGIFDSTADDR_:
        case SIOCSIFDSTADDR_: case SIOCGIFBRDADDR_: case SIOCSIFBRDADDR_:
        case SIOCGIFNETMASK_: case SIOCSIFNETMASK_: case SIOCGIFMETRIC_:
        case SIOCSIFMETRIC_: case SIOCGIFMTU_: case SIOCSIFMTU_:
        case SIOCSIFNAME_: case SIOCSIFHWADDR_: case SIOCGIFHWADDR_:
        case SIOCGIFINDEX_: case SIOCGIFTXQLEN_: case SIOCSIFTXQLEN_:
        case SIOCGIFMAP_: case SIOCSIFMAP_:
            return sizeof(struct ifreq_);
    }
    return -1;
}

static void put_inet(struct sockaddr_ *out, const struct sockaddr *in) {
    struct sockaddr_in addr = {0};
    if (in != NULL && in->sa_family == AF_INET)
        addr = *(const struct sockaddr_in *) in;
    struct sockaddr_in *guest = (struct sockaddr_in *) out;
    memset(out, 0, sizeof(*out));
    memcpy(&guest->sin_addr, &addr.sin_addr, sizeof(addr.sin_addr));
    out->family = AF_INET_;
}

static int ifconf(struct ifaddrs *ifas, struct ifconf_ *conf) {
    // one entry per interface with an IPv4 address, as Linux does
    int count = 0;
    for (struct ifaddrs *ifa = ifas; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        if (conf->buf == 0) {
            count++;
            continue;
        }
        if ((count + 1) * (int) sizeof(struct ifreq_) > conf->len)
            break;
        struct ifreq_ req = {0};
        strncpy(req.name, guest_ifname(ifa->ifa_name, ifa->ifa_flags), IFNAMSIZ_ - 1);
        put_inet(&req.addr, ifa->ifa_addr);
        if (user_write(conf->buf + count * sizeof(req), &req, sizeof(req)))
            return _EFAULT;
        count++;
    }
    conf->len = count * sizeof(struct ifreq_);
    return 0;
}

int netlink_ifioctl(int cmd, void *arg) {
    switch (cmd) {
        case SIOCSIFFLAGS_: case SIOCSIFADDR_: case SIOCSIFDSTADDR_:
        case SIOCSIFBRDADDR_: case SIOCSIFNETMASK_: case SIOCSIFMETRIC_:
        case SIOCSIFMTU_: case SIOCSIFNAME_: case SIOCSIFHWADDR_:
        case SIOCSIFTXQLEN_: case SIOCSIFMAP_:
            return _EPERM; // the host's network configuration is not ours
    }

    struct ifaddrs *ifas = ifaddrs_get();
    if (ifas == NULL) {
        ifaddrs_put();
        return _ENOBUFS;
    }
    int err = 0;
    if (cmd == SIOCGIFCONF_) {
        err = ifconf(ifas, arg);
        goto out;
    }

    struct ifreq_ *req = arg;
    // Find the interface's link entry, and its first IPv4 address.
    struct ifaddrs *link = NULL, *inet = NULL;
    for (struct ifaddrs *ifa = ifas; ifa != NULL; ifa = ifa->ifa_next) {
        if (cmd == SIOCGIFNAME_) {
            if (link == NULL && (int) cached_ifindex(ifa->ifa_name) == req->ivalue)
                link = ifa;
            continue;
        }
        if (strncmp(guest_ifname(ifa->ifa_name, ifa->ifa_flags), req->name, IFNAMSIZ_) != 0)
            continue;
        if (link == NULL && ifa_is_link(ifa))
            link = ifa;
        if (inet == NULL && ifa->ifa_addr != NULL && ifa->ifa_addr->sa_family == AF_INET)
            inet = ifa;
    }
    if (link == NULL)
        link = inet;
    err = _ENODEV;
    if (link == NULL)
        goto out;

    err = 0;
    switch (cmd) {
        case SIOCGIFNAME_:
            memset(req->name, 0, sizeof(req->name));
            strncpy(req->name, guest_ifname(link->ifa_name, link->ifa_flags), IFNAMSIZ_ - 1);
            break;
        case SIOCGIFINDEX_:
            req->ivalue = cached_ifindex(link->ifa_name);
            break;
        case SIOCGIFFLAGS_:
            req->flags = (int16_t) flags_from_real(link->ifa_flags);
            break;
        case SIOCGIFMETRIC_:
            req->ivalue = 0;
            break;
        case SIOCGIFTXQLEN_:
            req->ivalue = 1000;
            break;
        case SIOCGIFMAP_:
            memset(req->map, 0, sizeof(req->map));
            break;
        case SIOCGIFMTU_:
        case SIOCGIFHWADDR_: {
            struct link_info info = {.mtu = 1500};
            if (ifa_is_link(link))
                link_info(link, &info);
            if (cmd == SIOCGIFMTU_) {
                req->ivalue = info.mtu;
            } else {
                memset(&req->addr, 0, sizeof(req->addr));
                req->addr.family = info.type;
                memcpy(req->addr.data, info.mac, info.mac_len);
            }
            break;
        }
        case SIOCGIFADDR_:
        case SIOCGIFDSTADDR_:
        case SIOCGIFBRDADDR_:
        case SIOCGIFNETMASK_:
            if (inet == NULL) {
                err = _EADDRNOTAVAIL;
                break;
            }
            if (cmd == SIOCGIFADDR_)
                put_inet(&req->addr, inet->ifa_addr);
            else if (cmd == SIOCGIFNETMASK_)
                put_inet(&req->addr, inet->ifa_netmask);
            else if (cmd == SIOCGIFBRDADDR_)
                put_inet(&req->addr, inet->ifa_flags & IFF_BROADCAST ? inet->ifa_broadaddr : NULL);
            else
                put_inet(&req->addr, inet->ifa_flags & IFF_POINTOPOINT ? inet->ifa_dstaddr : inet->ifa_addr);
            break;
    }
out:
    ifaddrs_put();
    return err;
}

unsigned netlink_ifindex(const char *name) {
    unsigned index = 0;
    for (struct ifaddrs *ifa = ifaddrs_get(); ifa != NULL && index == 0; ifa = ifa->ifa_next)
        if (strncmp(guest_ifname(ifa->ifa_name, ifa->ifa_flags), name, IFNAMSIZ_) == 0)
            index = cached_ifindex(ifa->ifa_name);
    ifaddrs_put();
    return index;
}

bool netlink_ifname(unsigned index, char *name) {
    bool found = false;
    for (struct ifaddrs *ifa = ifaddrs_get(); ifa != NULL && !found; ifa = ifa->ifa_next) {
        if (cached_ifindex(ifa->ifa_name) != index)
            continue;
        memset(name, 0, IFNAMSIZ_);
        strncpy(name, guest_ifname(ifa->ifa_name, ifa->ifa_flags), IFNAMSIZ_ - 1);
        found = true;
    }
    ifaddrs_put();
    return found;
}

// /proc/net/dev from the host's interfaces and their counters
void netlink_proc_net_dev(struct proc_data *buf) {
    proc_printf(buf, "Inter-|   Receive                                                |  Transmit\n");
    proc_printf(buf, " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n");
    struct ifaddrs *ifas;
    if (getifaddrs(&ifas) < 0)
        return;
    for (struct ifaddrs *ifa = ifas; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa_is_link(ifa))
            continue;
        unsigned long long rx_bytes = 0, rx_packets = 0, rx_errs = 0, rx_drop = 0, rx_multi = 0;
        unsigned long long tx_bytes = 0, tx_packets = 0, tx_errs = 0, colls = 0;
#ifdef __APPLE__
        struct if_data *data = ifa->ifa_data;
        if (data != NULL) {
            rx_bytes = data->ifi_ibytes; rx_packets = data->ifi_ipackets;
            rx_errs = data->ifi_ierrors; rx_drop = data->ifi_iqdrops;
            rx_multi = data->ifi_imcasts;
            tx_bytes = data->ifi_obytes; tx_packets = data->ifi_opackets;
            tx_errs = data->ifi_oerrors; colls = data->ifi_collisions;
        }
#endif
        proc_printf(buf, "%6s: %7llu %7llu %4llu %4llu    0     0          0 %9llu %8llu %7llu %4llu    0    0 %5llu       0          0\n",
                guest_ifname(ifa->ifa_name, ifa->ifa_flags), rx_bytes, rx_packets, rx_errs, rx_drop, rx_multi,
                tx_bytes, tx_packets, tx_errs, colls);
    }
    freeifaddrs(ifas);
}
