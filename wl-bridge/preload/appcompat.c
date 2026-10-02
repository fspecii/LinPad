/* Preloaded by ishwl-launch into the apps /etc/ishwl/apps marks "compat".
 *
 * Everything in iSH runs as root, and some apps refuse to (VLC: "VLC is not
 * supposed to be run as root"). Only the program's own geteuid() calls are
 * answered with an unprivileged id: libraries keep seeing root, because libdbus
 * authenticates with the real socket credentials and Qt aborts when the effective
 * and real ids differ ("running setuid").
 *
 * musl implements PTHREAD_PRIO_INHERIT by probing FUTEX_LOCK_PI, which iSH does not
 * implement, so pthread_mutexattr_setprotocol() fails with ENOSYS. libpulse (in
 * VLC, and any app with PulseAudio output) asserts that it got 0 or ENOTSUP and
 * aborts otherwise; ENOTSUP makes it fall back to a plain mutex. */
#include <dlfcn.h>
#include <errno.h>
#include <link.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <unistd.h>

#define UNPRIVILEGED_ID 1000

static int find_executable(struct dl_phdr_info *info, size_t size, void *data) {
    (void) size;
    /* The first object dl_iterate_phdr reports is the program itself; dladdr()
     * reports where its first segment is mapped. */
    for (ElfW(Half) i = 0; i < info->dlpi_phnum; i++) {
        if (info->dlpi_phdr[i].p_type == PT_LOAD) {
            *(ElfW(Addr) *) data = info->dlpi_addr + (info->dlpi_phdr[i].p_vaddr & ~(ElfW(Addr)) 0xfff);
            break;
        }
    }
    return 1;
}

static int called_from_executable(const void *caller) {
    static ElfW(Addr) executable_base;
    static int known;
    if (!known) {
        dl_iterate_phdr(find_executable, &executable_base);
        known = 1;
    }
    Dl_info info;
    return dladdr(caller, &info) && (ElfW(Addr)) info.dli_fbase == executable_base;
}

uid_t geteuid(void) {
    uid_t euid = (uid_t) syscall(SYS_geteuid);
    if (euid == 0 && called_from_executable(__builtin_return_address(0)))
        return UNPRIVILEGED_ID;
    return euid;
}

int pthread_mutexattr_setprotocol(pthread_mutexattr_t *attr, int protocol) {
    (void) attr;
    return protocol == PTHREAD_PRIO_NONE ? 0 : ENOTSUP;
}
