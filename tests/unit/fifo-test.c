// util/fifo.c: reads (from the front and FIFO_LAST from the end) of a ring that
// has wrapped, against a model of what was written.
#include <stdio.h>
#include <string.h>
#include "util/fifo.h"

static int bad;
#define CHECK(c, ...) do { if (!(c)) { bad++; printf("BAD %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static char model[1 << 16];
static size_t model_len;

static void put(struct fifo *f, const char *data, size_t n) {
    fifo_write(f, data, n, FIFO_OVERWRITE);
    memcpy(model + model_len, data, n);
    model_len += n;
}

int main(void) {
    char storage[100];
    struct fifo f = FIFO_INIT(storage);
    char line[40], out[100];
    unsigned seq = 0;
    for (int round = 0; round < 200; round++) {
        int n = snprintf(line, sizeof(line), "line %u %.*s\n", seq, (int) (seq % 23), "abcdefghijklmnopqrstuvwxyz");
        seq++;
        put(&f, line, n);
        size_t have = fifo_size(&f);
        size_t expect = model_len < sizeof(storage) ? model_len : sizeof(storage);
        CHECK(have == expect, "size %zu, expected %zu", have, expect);
        // every suffix length, as dmesg (syslog READ_ALL) reads with FIFO_LAST | FIFO_PEEK
        for (size_t len = 1; len <= have; len++) {
            CHECK(fifo_read(&f, out, len, FIFO_LAST | FIFO_PEEK) == 0, "read last %zu", len);
            CHECK(memcmp(out, model + model_len - len, len) == 0, "round %d: last %zu bytes differ", round, len);
            CHECK(fifo_read(&f, out, len, FIFO_PEEK) == 0, "peek %zu", len);
            CHECK(memcmp(out, model + model_len - have, len) == 0, "round %d: first %zu bytes differ", round, len);
        }
    }
    // consuming reads
    size_t have = fifo_size(&f);
    CHECK(fifo_read(&f, out, 10, FIFO_LAST) == 0 && memcmp(out, model + model_len - 10, 10) == 0, "consume last 10");
    model_len -= 10;
    have -= 10;
    CHECK(fifo_size(&f) == have, "size after consuming the end");
    CHECK(fifo_read(&f, out, have, FIFO_PEEK) == 0 && memcmp(out, model + model_len - have, have) == 0,
          "front unchanged after consuming the end");
    CHECK(fifo_read(&f, out, 7, 0) == 0 && memcmp(out, model + model_len - have, 7) == 0, "consume first 7");
    have -= 7;
    CHECK(fifo_read(&f, out, have, FIFO_PEEK) == 0 && memcmp(out, model + model_len - have, have) == 0, "rest");
    CHECK(fifo_read(&f, out, have + 1, FIFO_PEEK) == 1, "reading more than the size fails");
    printf("fifo-test bad=%d\n", bad);
    return bad != 0;
}
