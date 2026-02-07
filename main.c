#include <stdlib.h>
#include <string.h>
#include "kernel/calls.h"
#include "kernel/task.h"
#include "xX_main_Xx.h"

int main(int argc, char *const argv[]) {
    char envp[200] = {0};
    size_t p = 0;
    if (getenv("TERM")) {
        const char *term = getenv("TERM");
        p += snprintf(envp + p, sizeof(envp) - p, "TERM=%s", term) + 1;
    }
#ifdef GUEST_ARM64
    // Disable SHA256 (bit 3) and SHA512 (bit 5) hardware acceleration in OpenSSL.
    // The emulator produces wrong results for these instructions.
    // 0x17 = NEON | AES | SHA1 | PMULL
    // OpenSSL armcap bits: 0=NEON, 1=TICK, 2=AES, 3=SHA1, 4=SHA256, 5=PMULL, 6=SHA512
    // Disable all hardware crypto acceleration for now.
    // Some NEON-optimized paths use vector instructions we haven't fully implemented.
    p += snprintf(envp + p, sizeof(envp) - p, "OPENSSL_armcap=0") + 1;
#endif
    int err = xX_main_Xx(argc, argv, envp);
    if (err < 0) {
        fprintf(stderr, "xX_main_Xx: %s\n", strerror(-err));
        return err;
    }
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    task_run_current();
}
