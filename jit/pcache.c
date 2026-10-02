// Persistent translation cache.
//
// Translations of file-backed, read-only guest code are written to disk and
// reused by later processes and later runs (node, claude, Firefox and the
// shell start much faster when libnode/libxul/ld-musl aren't retranslated).
//
// The cache is content-addressed: a record is found by a hash of the page
// offset and the first guest instruction words, and is used only if the
// guest bytes it was translated from equal the current bytes exactly. So a
// different file, a different load address, or a stale/garbled record can
// never be executed; at worst it is a miss. Translations are position
// independent (translate.c: guest PCs come from a per-block literal), and
// chunk-relative branches are relocation records.
//
// Files (in ISH_JIT_PCACHE_DIR, default $HOME/Library/Caches/ish-jit; on iOS
// $HOME is the app container):
//   tcache.idx   1M slots x 16 bytes, open addressing, mmap'd MAP_SHARED
//   tcache.dat   append-only records
// When tcache.dat passes the size cap (ISH_JIT_PCACHE_MB, default 128 MB on
// macOS, 48 MB on iOS) both are reset. ISH_JIT_PCACHE=0 disables it.
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <TargetConditionals.h>
#include "jit/jit_internal.h"
#include "kernel/memory.h"

#define PCACHE_VERSION 3
#define REC_MAGIC 0x3143525054494a49ull   // "IJITPRC1"
#define IDX_SLOTS (1u << 20)
#define IDX_PROBE 16
#define KEY_WORDS 16

extern const char jit_translator_build[];
extern int jit_tier1_compact;

struct idx_slot {
    uint64_t key;
    uint64_t loc;          // file offset << 24 | record size (0 = empty)
};

struct rec_hdr {
    uint64_t magic;
    uint64_t key;
    uint64_t check;        // hash of the record after this field
    uint32_t total;        // record bytes, multiple of 8
    uint16_t off;          // pc & 0xfff
    uint16_t ninsn;
    uint32_t nwords, nhot, reentry, lit, nreloc, nmap, cnt_lit, pad;
    // u32 guest[ninsn], u32 words[nwords], u32 reloc[nreloc],
    // struct jit_map_entry map[nmap], pad to 8
};

static int state = -1;            // -1 uninitialized, 0 off, 1 on
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct idx_slot *idx;
static int dat_fd = -1;
static uint64_t dat_size;         // bytes in the file (flushed)
static uint64_t cap;
static uint64_t salt;
static char dir[1024];
static const uint8_t *dat_map;    // read-only view of tcache.dat, cap + slack long
static uint8_t *pend;             // records not yet written
static size_t pend_len, pend_cap;
static uint64_t stats_hit, stats_miss, stats_offer;

static uint64_t mix(uint64_t h, uint64_t v) {
    h ^= v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2);
    h *= 0xff51afd7ed558ccdull;
    return h ^ (h >> 33);
}
// Four independent lanes so the multiplies overlap (record checks hash a few
// hundred bytes per lookup).
static uint64_t hash_bytes(uint64_t h, const void *p, size_t n) {
    const uint8_t *b = p;
    size_t i = 0;
    if (n >= 32) {
        uint64_t a0 = h ^ 0x243f6a8885a308d3ull, a1 = h ^ 0x13198a2e03707344ull,
                 a2 = h ^ 0xa4093822299f31d0ull, a3 = h ^ 0x082efa98ec4e6c89ull;
        for (; i + 32 <= n; i += 32) {
            uint64_t v[4];
            memcpy(v, b + i, 32);
            a0 = (a0 ^ v[0]) * 0x9e3779b97f4a7c15ull;
            a1 = (a1 ^ v[1]) * 0xc2b2ae3d27d4eb4full;
            a2 = (a2 ^ v[2]) * 0x165667b19e3779f9ull;
            a3 = (a3 ^ v[3]) * 0xd6e8feb86659fd93ull;
            a0 ^= a0 >> 29; a1 ^= a1 >> 31; a2 ^= a2 >> 27; a3 ^= a3 >> 33;
        }
        h = mix(mix(mix(mix(h, a0), a1), a2), a3);
    }
    for (; i + 8 <= n; i += 8) {
        uint64_t v;
        memcpy(&v, b + i, 8);
        h = mix(h, v);
    }
    for (; i < n; i++)
        h = mix(h, b[i]);
    return mix(h, n);
}

// Record checksum: cheap (vectorizes), only meant to catch disk corruption
// and torn writes; the exact guest-byte comparison guards correctness.
static uint64_t checksum(uint64_t seed, const void *p, size_t n) {
    const uint64_t *w = p;
    uint64_t a = seed, b = ~seed;
    for (size_t i = 0; i < n / 8; i++) {
        a += w[i];
        b ^= w[i] + (a >> 7);
    }
    return mix(a, b);
}

static uint64_t key_for(addr_t pc, const uint32_t *code, int ncode) {
    int n = ncode < KEY_WORDS ? ncode : KEY_WORDS;
    uint64_t a = salt ^ PGOFFSET(pc), b = (uint64_t) n * 0x9e3779b97f4a7c15ull;
    for (int i = 0; i < n; i++) {
        a = (a ^ code[i]) * 0xff51afd7ed558ccdull;
        b += code[i];
    }
    return mix(a, b) | 1;   // never 0 (empty slot)
}

// Start over (at init only: the data file is nearly full, or the salt
// changed). The old
// files are unlinked, not truncated, so another ish process that still has
// them mapped keeps reading valid memory.
static void reset_files(void) {
    char p[1100];
    snprintf(p, sizeof(p), "%s/tcache.dat", dir);
    unlink(p);
    snprintf(p, sizeof(p), "%s/tcache.idx", dir);
    unlink(p);
}
static bool writes_off;

static bool init_locked(void) {
    const char *e = getenv("ISH_JIT_PCACHE");
    if (e && e[0] == '0')
        return false;
    const char *d = getenv("ISH_JIT_PCACHE_DIR");
    if (d) {
        snprintf(dir, sizeof(dir), "%s", d);
    } else {
        const char *home = getenv("HOME");
        if (!home)
            return false;
        snprintf(dir, sizeof(dir), "%s/Library/Caches/ish-jit", home);
    }
#if TARGET_OS_IPHONE
    uint64_t def_mb = 48;
#else
    uint64_t def_mb = 128;
#endif
    const char *c = getenv("ISH_JIT_PCACHE_MB");
    cap = (c ? (uint64_t) atol(c) : def_mb) << 20;
    mkdir(dir, 0755);
    // The salt changes with the translator build and its settings: records
    // of another salt can never hit, so a salt change starts over too.
    salt = hash_bytes(PCACHE_VERSION, jit_translator_build, strlen(jit_translator_build));
    salt = mix(salt, sizeof(struct jit_ctx));
    salt = mix(salt, jit_tier1_compact);
    {
        char p[1100];
        struct stat st0;
        bool reset = false;
        snprintf(p, sizeof(p), "%s/tcache.dat", dir);
        // nearly full (appends stop within a flush of the cap): start over
        if (stat(p, &st0) == 0 && (uint64_t) st0.st_size + (4 << 20) > cap)
            reset = true;
        snprintf(p, sizeof(p), "%s/tcache.salt", dir);
        uint64_t old_salt = 0;
        int sfd = open(p, O_RDONLY);
        if (sfd >= 0) {
            if (read(sfd, &old_salt, sizeof(old_salt)) != sizeof(old_salt))
                old_salt = 0;
            close(sfd);
        }
        if (old_salt != salt)
            reset = true;
        if (reset) {
            reset_files();
            char tmp[1100];
            snprintf(tmp, sizeof(tmp), "%s/tcache.salt.%d", dir, getpid());
            sfd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (sfd >= 0) {
                bool ok = write(sfd, &salt, sizeof(salt)) == sizeof(salt);
                close(sfd);
                if (!ok || rename(tmp, p) != 0)
                    unlink(tmp);
            }
        }
    }

    char p[1100];
    snprintf(p, sizeof(p), "%s/tcache.idx", dir);
    int ifd = open(p, O_RDWR | O_CREAT, 0644);
    if (ifd < 0)
        return false;
    if (ftruncate(ifd, sizeof(struct idx_slot) * IDX_SLOTS) != 0) {
        close(ifd);
        return false;
    }
    idx = mmap(NULL, sizeof(struct idx_slot) * IDX_SLOTS, PROT_READ | PROT_WRITE, MAP_SHARED, ifd, 0);
    close(ifd);
    if (idx == MAP_FAILED) {
        idx = NULL;
        return false;
    }
    snprintf(p, sizeof(p), "%s/tcache.dat", dir);
    dat_fd = open(p, O_RDWR | O_CREAT | O_APPEND, 0644);
    if (dat_fd < 0)
        return false;
    struct stat st;
    fstat(dat_fd, &st);
    dat_size = st.st_size;
    // Map the whole capped size once; only offsets below dat_size are read.
    dat_map = mmap(NULL, cap + (16 << 20), PROT_READ, MAP_SHARED, dat_fd, 0);
    if (dat_map == MAP_FAILED)
        return false;
    return true;
}

static bool enabled(void) {
    if (__builtin_expect(state >= 0, 1))
        return state;
    pthread_mutex_lock(&lock);
    if (state < 0)
        state = init_locked();
    pthread_mutex_unlock(&lock);
    return state;
}

// Is pc in code that comes straight from a file and can't be written (no
// CoW copy, not a JIT region)? Only such translations are worth keeping,
// and translate.c also uses it to pick the first tier.
bool jit_pcache_wanted(struct jit_ctx *ctx, addr_t pc) {
    struct mem *mem = container_of(ctx->mm->mmu, struct mem, mmu);
    struct pt_entry *pt = mem_pt(mem, PAGE(pc));
    return pt != NULL && pt->data != NULL && pt->data->fd != NULL && !(pt->flags & P_WRITE);
}

bool jit_pcache_lookup(addr_t pc, const uint32_t *code, int ncode, struct jit_image *img) {
    if (!enabled())
        return false;
    uint64_t key = key_for(pc, code, ncode);
    uint32_t h = (uint32_t) (key >> 20) & (IDX_SLOTS - 1);
    for (int i = 0; i < IDX_PROBE; i++) {
        struct idx_slot *s = &idx[(h + i) & (IDX_SLOTS - 1)];
        uint64_t k = __atomic_load_n(&s->key, __ATOMIC_ACQUIRE);
        if (k == 0)
            break;
        if (k != key)
            continue;
        uint64_t loc = __atomic_load_n(&s->loc, __ATOMIC_ACQUIRE);
        uint64_t off = loc >> 24, len = loc & 0xffffff;
        if (len < sizeof(struct rec_hdr) || off + len > __atomic_load_n(&dat_size, __ATOMIC_ACQUIRE))
            continue;
        const uint8_t *rbuf = dat_map + off;
        struct rec_hdr *r = (struct rec_hdr *) rbuf;
        if (r->magic != REC_MAGIC || r->key != key || r->total != len || r->off != PGOFFSET(pc))
            continue;
        if (r->ninsn == 0 || r->ninsn > ncode)
            continue;
        size_t need = sizeof(*r) + 4 * ((size_t) r->ninsn + r->nwords + r->nreloc) +
                      sizeof(struct jit_map_entry) * r->nmap;
        if (need > len || r->lit + 2 > r->nwords || r->reentry >= r->nwords || r->nhot > r->nwords)
            continue;
        if (checksum(salt, rbuf + 24, len - 24) != r->check)
            continue;
        const uint32_t *g = (const uint32_t *) (r + 1);
        if (memcmp(g, code, 4 * r->ninsn) != 0)
            continue;
        img->ninsn = r->ninsn;
        img->nwords = r->nwords;
        img->nhot = r->nhot;
        img->reentry = r->reentry;
        img->lit = r->lit;
        img->cnt_lit = r->cnt_lit;
        if (r->cnt_lit && r->cnt_lit + 2 > r->nwords)
            continue;
        img->nreloc = r->nreloc;
        img->nmap = r->nmap;
        img->words = (uint32_t *) (g + r->ninsn);
        img->reloc = img->words + r->nwords;
        img->map = (struct jit_map_entry *) (img->reloc + r->nreloc);
        bool bad = false;
        for (uint32_t k = 0; k < img->nreloc && !bad; k++)
            bad = JREL_IDX(img->reloc[k]) >= img->nwords ||
                  !((JREL_KIND(img->reloc[k]) >= 1 && JREL_KIND(img->reloc[k]) <= 3) ||
                    (JREL_KIND(img->reloc[k]) >= JREL_STUB && JREL_KIND(img->reloc[k]) < JREL_STUB + JIT_NSTUBS));
        if (bad)
            continue;
        __atomic_fetch_add(&stats_hit, 1, __ATOMIC_RELAXED);
        return true;
    }
    __atomic_fetch_add(&stats_miss, 1, __ATOMIC_RELAXED);
    return false;
}

static void flush_locked(void) {
    if (pend_len == 0 || dat_fd < 0)
        return;
    if (writes_off || dat_size + pend_len > cap) {
        writes_off = true;   // full: keep using it, reset at the next start
        pend_len = 0;
        return;
    }
    ssize_t w = write(dat_fd, pend, pend_len);   // O_APPEND: lands at the real end of file
    if (w != (ssize_t) pend_len) {
        pend_len = 0;
        return;
    }
    off_t end = lseek(dat_fd, 0, SEEK_CUR);
    uint64_t base = (uint64_t) end - pend_len;
    // Index the records just written (data first, then the slots).
    for (size_t p = 0; p < pend_len;) {
        struct rec_hdr *r = (struct rec_hdr *) (pend + p);
        uint32_t h = (uint32_t) (r->key >> 20) & (IDX_SLOTS - 1);
        struct idx_slot *victim = &idx[h];
        for (int i = 0; i < IDX_PROBE; i++) {
            struct idx_slot *s = &idx[(h + i) & (IDX_SLOTS - 1)];
            if (s->key == 0 || s->key == r->key) {
                victim = s;
                break;
            }
        }
        __atomic_store_n(&victim->key, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&victim->loc, ((base + p) << 24) | r->total, __ATOMIC_RELEASE);
        __atomic_store_n(&victim->key, r->key, __ATOMIC_RELEASE);
        p += r->total;
    }
    __atomic_store_n(&dat_size, (uint64_t) end, __ATOMIC_RELEASE);
    pend_len = 0;
}

void jit_pcache_offer(addr_t pc, const uint32_t *code, const struct jit_image *img) {
    if (!enabled() || img->ninsn > 0xffff)
        return;
    int ncode = (int) ((PAGE_SIZE - PGOFFSET(pc)) / 4);
    if (ncode > 200)
        ncode = 200;
    size_t len = sizeof(struct rec_hdr) + 4 * ((size_t) img->ninsn + img->nwords + img->nreloc) +
                 sizeof(struct jit_map_entry) * img->nmap;
    len = (len + 7) & ~(size_t) 7;
    if (len >= (1 << 24))
        return;
    pthread_mutex_lock(&lock);
    if (pend_len + len > pend_cap) {
        pend_cap = (pend_len + len) * 2 + (256 << 10);
        pend = realloc(pend, pend_cap);
    }
    struct rec_hdr *r = (struct rec_hdr *) (pend + pend_len);
    memset(r, 0, len);
    r->magic = REC_MAGIC;
    r->key = key_for(pc, code, ncode);
    r->total = (uint32_t) len;
    r->off = PGOFFSET(pc);
    r->ninsn = img->ninsn;
    r->nwords = img->nwords;
    r->nhot = img->nhot;
    r->reentry = img->reentry;
    r->lit = img->lit;
    r->cnt_lit = img->cnt_lit;
    r->nreloc = img->nreloc;
    r->nmap = img->nmap;
    uint8_t *p = (uint8_t *) (r + 1);
    memcpy(p, code, 4 * img->ninsn);
    p += 4 * img->ninsn;
    memcpy(p, img->words, 4 * img->nwords);
    p += 4 * img->nwords;
    memcpy(p, img->reloc, 4 * img->nreloc);
    p += 4 * img->nreloc;
    memcpy(p, img->map, sizeof(struct jit_map_entry) * img->nmap);
    r->check = checksum(salt, (uint8_t *) r + 24, len - 24);
    pend_len += len;
    stats_offer++;
    if (pend_len >= (1 << 20))
        flush_locked();
    pthread_mutex_unlock(&lock);
}

// Called by the ticker about once a second: guest processes are often
// killed (and ish leaves with _exit), so don't rely on exits to flush.
void jit_pcache_tick(void) {
    if (state != 1 || pend_len == 0)
        return;
    pthread_mutex_lock(&lock);
    flush_locked();
    pthread_mutex_unlock(&lock);
}

void jit_pcache_save(void) {
    if (state != 1)
        return;
    pthread_mutex_lock(&lock);
    flush_locked();
    pthread_mutex_unlock(&lock);
}

void jit_pcache_stats(uint64_t *hit, uint64_t *miss, uint64_t *offer) {
    *hit = stats_hit;
    *miss = stats_miss;
    *offer = stats_offer;
}
