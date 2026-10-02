#include <stddef.h>
#include <stdbool.h>
#include "fs/proc.h"
#include "fs/netlink.h"

// /proc/net/dev - network device statistics
// Format: Interface|Receive|Transmit
static int proc_show_net_dev(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    netlink_proc_net_dev(buf);
    return 0;
}

// /proc/net directory entries
struct proc_dir_entry proc_net_entries[] = {
    {"dev", .show = proc_show_net_dev},
};
#define PROC_NET_LEN (sizeof(proc_net_entries)/sizeof(proc_net_entries[0]))

static bool proc_net_readdir(struct proc_entry *UNUSED(entry), unsigned long *index, struct proc_entry *next_entry) {
    if (*index < PROC_NET_LEN) {
        *next_entry = (struct proc_entry) {&proc_net_entries[*index], *index, NULL, NULL, 0, 0};
        (*index)++;
        return true;
    }
    return false;
}

// Exported /proc/net directory entry
struct proc_children proc_net_children = PROC_CHILDREN({
    {"dev", .show = proc_show_net_dev},
});
