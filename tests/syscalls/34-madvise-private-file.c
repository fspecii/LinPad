// Checks: MADV_DONTNEED on a private file mapping shows the file again, it does not zero it.
// Expected (Linux, madvise(2) "MADV_DONTNEED"): private file pages, written or not, are
// refilled from the file on the next access; only private anonymous pages read as zero.
// Observed: iSH cleared private file pages in place. Bun single-file executables (the
// native Claude Code) keep their module sources in the writable data segment and drop
// most of it this way after startup, so modules loaded later read as NUL bytes
// ("SyntaxError: Invalid character '\0'", or `claude -p` exiting with no output).
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define PAGE 4096
#define BLOB_PAGES 32
// Writable, initialized: in the executable's RW PT_LOAD segment, like Bun's .bun section
static unsigned char blob[BLOB_PAGES * PAGE] __attribute__((aligned(16384))) = {
    [0 ... BLOB_PAGES * PAGE - 1] = 0x5a,
};

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
    volatile unsigned char sink = blob[0] + blob[5 * PAGE];  // some pages read, some untouched
    (void) sink;
    blob[3 * PAGE + 7] = 1;  // and one written
    int r = madvise(blob, sizeof(blob), MADV_DONTNEED);
    check(r == 0 && all(blob, sizeof(blob), 0x5a), "data segment reads its file contents after MADV_DONTNEED");

    // A file mapping at an offset that is not a 16 KB host page, ending past EOF
    const char *path = "madvise-private-file.tmp";
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    unsigned char page[PAGE];
    for (int i = 0; i < 8; i++) {
        memset(page, i + 1, PAGE);
        write(fd, page, i == 7 ? PAGE / 2 : PAGE);
    }
    unsigned char *map = mmap(NULL, 7 * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, PAGE);
    if (map == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    memset(map + PAGE, 0xee, PAGE);  // a private copy of file page 2
    sink = map[0];
    r = madvise(map, 7 * PAGE, MADV_DONTNEED);
    int ok = r == 0;
    for (int i = 0; i < 7; i++) {
        size_t n = i == 6 ? PAGE / 2 : PAGE;
        ok &= all(map + i * PAGE, n, i + 2);
    }
    check(ok, "private file mapping at offset 4096 reads the file again, written page too");
    check(all(map + 6 * PAGE + PAGE / 2, PAGE / 2, 0), "past the end of the file reads zero");
    munmap(map, 7 * PAGE);
    close(fd);
    unlink(path);

    unsigned char *anon = mmap(NULL, 4 * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    memset(anon, 0x77, 4 * PAGE);
    r = madvise(anon, 4 * PAGE, MADV_DONTNEED);
    check(r == 0 && all(anon, 4 * PAGE, 0), "private anonymous pages still read zero");
    return failed;
}
