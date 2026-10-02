// LD_PRELOAD: on SIGSEGV print pc/lr/fault address and the mapping they fall in.
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>
static void where(const char *what, unsigned long a) {
    FILE *f = fopen("/proc/self/maps", "r"); char line[512];
    while (f && fgets(line, sizeof line, f)) { unsigned long lo, hi, off; char perm[8], path[256] = "";
        if (sscanf(line, "%lx-%lx %7s %lx %*s %*s %255s", &lo, &hi, perm, &off, path) >= 4 && a >= lo && a < hi) {
            fprintf(stderr, "segv: %s %#lx in %s (+%#lx, map off %#lx)\n", what, a, path, a - lo, off); break; } }
    if (f) fclose(f);
}
static void h(int sig, siginfo_t *si, void *uc_) {
    ucontext_t *uc = uc_;
    fprintf(stderr, "segv: sig %d addr %p\n", sig, si->si_addr);
    where("pc", uc->uc_mcontext.pc); where("lr", uc->uc_mcontext.regs[30]);
    unsigned long fp = uc->uc_mcontext.regs[29];
    for (int i = 0; i < 12 && fp; i++) { unsigned long *p = (unsigned long *) fp; where("frame", p[1]); fp = p[0]; }
    _exit(139);
}
__attribute__((constructor)) static void init(void) {
    struct sigaction sa = {0}; sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO; sigaction(SIGSEGV, &sa, 0); sigaction(SIGBUS, &sa, 0);
}
