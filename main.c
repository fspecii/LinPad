#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <setjmp.h>
#include <execinfo.h>
#include <termios.h>
#include <unistd.h>
#include <mach/mach.h>
#include <pthread.h>
#include "kernel/calls.h"
#include "kernel/task.h"
#include "emu/cpu.h"
#include "emu/tlb.h"
#include "xX_main_Xx.h"

// Thread-local JIT recovery state (defined in asbestos.c)
extern __thread jmp_buf jit_recover_buf;
extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile uintptr_t jit_crash_host_addr;
extern __thread volatile uint64_t jit_crash_segfault_addr;
extern __thread volatile int jit_crash_segfault_was_write;

static void crash_handler(int sig, siginfo_t *info, void *ctx) {
#ifdef __aarch64__
    // If we're inside JIT code and got SIGSEGV/SIGBUS, recover via siglongjmp.
    // This handles stale TLB pointers from concurrent CoW resolution.
    if ((sig == SIGSEGV || sig == SIGBUS) && in_jit) {
        ucontext_t *uc = (ucontext_t *)ctx;
        // Save host fault address for recovery logic in asbestos.c
        jit_crash_host_addr = (uintptr_t)info->si_addr;
        // Reconstruct guest segfault_addr from ucontext registers.
        // At fault point: x7 = host_addr (data_minus_addr + guest_addr),
        //                 x10 = data_minus_addr (from TLB entry).
        // Guest addr = (x7 - x10) & 0xffffffffffff.
        uint64_t x7 = uc->uc_mcontext->__ss.__x[7];
        uint64_t x10 = uc->uc_mcontext->__ss.__x[10];
        jit_crash_segfault_addr = (x7 - x10) & 0xffffffffffffULL;
        // Determine read/write from the host ESR (Exception Syndrome Register).
        // Bit 6 (WnR): 0 = read fault, 1 = write fault.
        uint64_t esr = uc->uc_mcontext->__es.__esr;
        jit_crash_segfault_was_write = (esr & 0x40) != 0;
        // We use _longjmp (no signal mask restore) for performance.
        // Must manually unblock the signal so the handler can fire again.
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
        _longjmp(jit_recover_buf, 1);
        // not reached
    }
#endif

    // Non-JIT crash: dump state and exit
    char buf[512];
    int len;
    ucontext_t *uc = (ucontext_t *)ctx;
    len = snprintf(buf, sizeof(buf), "\n=== HOST CRASH: signal %d ===\nfault addr: %p\n", sig, info->si_addr);
    write(STDERR_FILENO, buf, len);
#ifdef __aarch64__
    len = snprintf(buf, sizeof(buf),
        "pc:  0x%llx\nlr:  0x%llx\nsp:  0x%llx\n"
        "x0:  0x%llx\nx1:  0x%llx\nx2:  0x%llx\n"
        "x7:  0x%llx\nx28: 0x%llx\n",
        uc->uc_mcontext->__ss.__pc, uc->uc_mcontext->__ss.__lr,
        uc->uc_mcontext->__ss.__sp,
        uc->uc_mcontext->__ss.__x[0], uc->uc_mcontext->__ss.__x[1],
        uc->uc_mcontext->__ss.__x[2],
        uc->uc_mcontext->__ss.__x[7], uc->uc_mcontext->__ss.__x[28]);
    write(STDERR_FILENO, buf, len);
#endif
    void *bt[20];
    int n = backtrace(bt, 20);
    backtrace_symbols_fd(bt, n, STDERR_FILENO);
    _exit(139);
}

static struct termios saved_termios;
static int saved_termios_valid;

void restore_termios(void) {
    if (saved_termios_valid)
        tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
}

int main(int argc, char *const argv[]) {
    // Save host terminal settings so we can restore on exit
    if (isatty(STDIN_FILENO)) {
        if (tcgetattr(STDIN_FILENO, &saved_termios) == 0) {
            saved_termios_valid = 1;
            atexit(restore_termios);
        }
    }

    // Redirect printk output (fd 666) to stderr
    dup2(STDERR_FILENO, 666);

    static char altstack[SIGSTKSZ];
    stack_t ss = {.ss_sp = altstack, .ss_size = SIGSTKSZ};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    char envp[512] = {0};
    size_t p = 0;
    if (getenv("TERM")) {
        const char *term = getenv("TERM");
        p += snprintf(envp + p, sizeof(envp) - p, "TERM=%s", term) + 1;
    }
    p += snprintf(envp + p, sizeof(envp) - p, "HOME=/root") + 1;
    p += snprintf(envp + p, sizeof(envp) - p, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") + 1;
#ifdef GUEST_ARM64
    p += snprintf(envp + p, sizeof(envp) - p, "PYTHONMALLOC=malloc") + 1;
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
