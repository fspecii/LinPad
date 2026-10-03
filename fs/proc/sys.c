#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/random.h"
#include "fs/proc.h"
#include "kernel/ipc.h"

// /proc/sys: read-only values that runtimes and tools commonly probe.

#define SYS_NUMBER(fn, value) \
    static int fn(struct proc_entry *UNUSED(entry), struct proc_data *buf) { \
        proc_printf(buf, "%lld\n", (long long) (value)); \
        return 0; \
    }

SYS_NUMBER(sys_inotify_max_user_watches, 524288)
SYS_NUMBER(sys_inotify_max_user_instances, 128)
SYS_NUMBER(sys_inotify_max_queued_events, 16384)
SYS_NUMBER(sys_fs_file_max, 1048576)
SYS_NUMBER(sys_fs_nr_open, 1048576)
SYS_NUMBER(sys_kernel_pid_max, MAX_PID)
SYS_NUMBER(sys_kernel_threads_max, MAX_PID)
SYS_NUMBER(sys_kernel_ngroups_max, 65536)
SYS_NUMBER(sys_vm_overcommit_memory, 0)
SYS_NUMBER(sys_vm_max_map_count, 65530)
SYS_NUMBER(sys_vm_swappiness, 60)
SYS_NUMBER(sys_net_somaxconn, 4096)

static int sys_kernel_osrelease(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    struct uname uts;
    do_uname(&uts);
    proc_printf(buf, "%s\n", uts.release);
    return 0;
}

static int sys_kernel_ostype(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "Linux\n");
    return 0;
}

static int sys_kernel_hostname(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    struct uname uts;
    do_uname(&uts);
    proc_printf(buf, "%s\n", uts.hostname);
    return 0;
}

static void print_uuid(struct proc_data *buf, const uint8_t b[16]) {
    proc_printf(buf, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n",
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
}

static void random_uuid(uint8_t b[16]) {
    get_random((char *) b, 16);
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
}

// a new random UUID on every read
static int sys_kernel_random_uuid(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    uint8_t b[16];
    random_uuid(b);
    print_uuid(buf, b);
    return 0;
}

// fixed for the lifetime of this emulator "boot"
static int sys_kernel_random_boot_id(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    static uint8_t boot_id[16];
    static lock_t boot_id_lock = LOCK_INITIALIZER;
    static bool have_boot_id = false;
    lock(&boot_id_lock);
    if (!have_boot_id) {
        random_uuid(boot_id);
        have_boot_id = true;
    }
    unlock(&boot_id_lock);
    print_uuid(buf, boot_id);
    return 0;
}

static int sys_ip_local_port_range(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "32768\t60999\n");
    return 0;
}

static struct proc_children sys_fs_inotify_children = PROC_CHILDREN({
    {"max_queued_events", .show = sys_inotify_max_queued_events},
    {"max_user_instances", .show = sys_inotify_max_user_instances},
    {"max_user_watches", .show = sys_inotify_max_user_watches},
});

static struct proc_children sys_fs_children = PROC_CHILDREN({
    {"file-max", .show = sys_fs_file_max},
    {"inotify", S_IFDIR, .children = &sys_fs_inotify_children},
    {"nr_open", .show = sys_fs_nr_open},
});

static struct proc_children sys_kernel_random_children = PROC_CHILDREN({
    {"boot_id", .show = sys_kernel_random_boot_id},
    {"uuid", .show = sys_kernel_random_uuid},
});

static struct proc_children sys_kernel_children = PROC_CHILDREN({
    {"hostname", .show = sys_kernel_hostname},
    {"msgmax", .show = proc_sys_kernel_msgmax},
    {"msgmnb", .show = proc_sys_kernel_msgmnb},
    {"msgmni", .show = proc_sys_kernel_msgmni},
    {"ngroups_max", .show = sys_kernel_ngroups_max},
    {"osrelease", .show = sys_kernel_osrelease},
    {"ostype", .show = sys_kernel_ostype},
    {"pid_max", .show = sys_kernel_pid_max},
    {"random", S_IFDIR, .children = &sys_kernel_random_children},
    {"sem", .show = proc_sys_kernel_sem},
    {"shmall", .show = proc_sys_kernel_shmall},
    {"shmmax", .show = proc_sys_kernel_shmmax},
    {"shmmni", .show = proc_sys_kernel_shmmni},
    {"threads-max", .show = sys_kernel_threads_max},
});

static struct proc_children sys_vm_children = PROC_CHILDREN({
    {"max_map_count", .show = sys_vm_max_map_count},
    {"overcommit_memory", .show = sys_vm_overcommit_memory},
    {"swappiness", .show = sys_vm_swappiness},
});

static struct proc_children sys_net_core_children = PROC_CHILDREN({
    {"somaxconn", .show = sys_net_somaxconn},
});

static struct proc_children sys_net_ipv4_children = PROC_CHILDREN({
    {"ip_local_port_range", .show = sys_ip_local_port_range},
});

static struct proc_children sys_net_children = PROC_CHILDREN({
    {"core", S_IFDIR, .children = &sys_net_core_children},
    {"ipv4", S_IFDIR, .children = &sys_net_ipv4_children},
});

struct proc_children proc_sys_children = PROC_CHILDREN({
    {"fs", S_IFDIR, .children = &sys_fs_children},
    {"kernel", S_IFDIR, .children = &sys_kernel_children},
    {"net", S_IFDIR, .children = &sys_net_children},
    {"vm", S_IFDIR, .children = &sys_vm_children},
});
