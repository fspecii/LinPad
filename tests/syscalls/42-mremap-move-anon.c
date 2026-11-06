// Checks: mremap grows an anonymous mapping that has something right after it by moving it
// (MREMAP_MAYMOVE), as Linux does: the contents come along, the new tail is zeroed and usable,
// and the moved pages still copy on write after a fork. Without MREMAP_MAYMOVE it is ENOMEM.
// Observed: an anonymous mapping only grew in place, otherwise ENOMEM, MAYMOVE or not. apt
// grows its package cache with mremap and failed with "NewVersion2" while reading the lists;
// and a mapping whose pages a fork had left partly copy-on-write could not grow at all (EFAULT).
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define PAGE 4096
#define OLD 16
#define NEW 64

static int failed;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    failed |= !ok;
}

static int all(const unsigned char *p, size_t n, unsigned char c) {
    for (size_t i = 0; i < n; i++)
        if (p[i] != c)
            return 0;
    return 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    // reserve OLD + 1 pages, then keep the last one mapped right after the region
    unsigned char *map = mmap(NULL, (OLD + 1) * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (map == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    memset(map, 0x3c, OLD * PAGE);
    map[OLD * PAGE] = 1;  // the page in the way

    errno = 0;
    check(mremap(map, OLD * PAGE, NEW * PAGE, 0) == MAP_FAILED && errno == ENOMEM,
            "growing into a mapped page without MREMAP_MAYMOVE is ENOMEM");

    unsigned char *moved = mremap(map, OLD * PAGE, NEW * PAGE, MREMAP_MAYMOVE);
    check(moved != MAP_FAILED && moved != map, "MREMAP_MAYMOVE moves the mapping");
    if (moved == MAP_FAILED)
        return failed;
    check(all(moved, OLD * PAGE, 0x3c), "the contents move with it");
    check(all(moved + OLD * PAGE, (NEW - OLD) * PAGE, 0), "the new tail reads zero");
    memset(moved + (NEW - 1) * PAGE, 0x5e, PAGE);
    check(moved[(NEW - 1) * PAGE] == 0x5e, "the new tail is writable");
    check(map[OLD * PAGE] == 1, "the page that was in the way is untouched");

    pid_t child = fork();
    if (child == 0) {
        memset(moved, 0x77, OLD * PAGE);
        _exit(all(moved, OLD * PAGE, 0x77) ? 0 : 1);
    }
    int status = -1;
    waitpid(child, &status, 0);
    check(WIFEXITED(status) && WEXITSTATUS(status) == 0 && all(moved, OLD * PAGE, 0x3c),
            "moved pages still copy on write after a fork");

    // After a fork, written pages are private again and the rest still copy on write: the
    // pages of one mapping differ, which mremap took for a mapping it could not grow (EFAULT)
    unsigned char *mixed = mmap(NULL, (OLD + 1) * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    memset(mixed, 0x11, (OLD + 1) * PAGE);
    child = fork();
    if (child == 0)
        _exit(0);
    waitpid(child, &status, 0);
    for (int i = 0; i < OLD; i += 2)
        mixed[i * PAGE] = 0x22;
    unsigned char *grown = mremap(mixed, OLD * PAGE, NEW * PAGE, MREMAP_MAYMOVE);
    int ok = grown != MAP_FAILED;
    for (int i = 0; ok && i < OLD; i++)
        ok = grown[i * PAGE] == (i % 2 ? 0x11 : 0x22) && all(grown + i * PAGE + 1, PAGE - 1, 0x11);
    check(ok && all(grown + OLD * PAGE, (NEW - OLD) * PAGE, 0), "a mapping partly copy-on-write after a fork grows too");
    return failed;
}
