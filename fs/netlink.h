#ifndef FS_NETLINK_H
#define FS_NETLINK_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define PF_NETLINK_ 16
#define AF_NETLINK_ PF_NETLINK_

struct sockaddr_nl_ {
    uint16_t family;
    uint16_t pad;
    uint32_t pid;
    uint32_t groups;
};

struct fd;
// Returns the host fd replies are queued on and sets *real_fd to the end the
// guest reads, or returns an error.
int netlink_socket(int type, int protocol, int *real_fd);
ssize_t netlink_send(struct fd *sock, const void *buf, size_t len);
int netlink_bind(struct fd *sock, const void *addr, size_t len);
void netlink_name(struct fd *sock, bool local, struct sockaddr_nl_ *addr);
bool netlink_sockopt_ignored(int level);
// SIOCGIF* interface ioctls on any socket, from the host's interfaces
ssize_t netlink_ifioctl_size(int cmd);
int netlink_ifioctl(int cmd, void *arg);
struct proc_data;
void netlink_proc_net_dev(struct proc_data *buf);

#endif
