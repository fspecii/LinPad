// Guest-only (needs libpcre2-16): gcc -O1 -o pcre_jit_reuse pcre_jit_reuse.c /usr/lib/libpcre2-16.so.0
// Expected: "checks=2400 bad=0". Before IC IVAU invalidation this segfaulted at it=1.
// Repeatedly JIT-compile, run and free different patterns so sljit reuses executable
// memory; compare each JIT result with the interpreter.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
void *pcre2_compile_16(const uint16_t *, size_t, uint32_t, int *, size_t *, void *);
int pcre2_jit_compile_16(void *, uint32_t);
void pcre2_code_free_16(void *);
void *pcre2_match_data_create_from_pattern_16(const void *, void *);
void pcre2_match_data_free_16(void *);
int pcre2_match_16(const void *, const uint16_t *, size_t, size_t, uint32_t, void *, void *);
static uint16_t *u16(const char *c, uint16_t *b) { size_t i; for (i = 0; c[i]; i++) b[i] = (unsigned char) c[i]; b[i] = 0; return b; }
static const char *pats[] = { "\\A(?:[^/]*\\.pem)\\z", "\\A(?:[^/]*\\.cnf)\\z", "^qt\\.(\\w+)$", "(a|b)+c", "\\A(?:.*\\.so(\\.\\d+)*)\\z", "[0-9a-f]{8}\\.\\d", "x*y", "\\A(?:[^/]*\\.dist)\\z" };
static const char *subs[] = { "878d9bca.0", "ct_log_list.cnf.dist", "openssl.cnf", "cert.pem", "qt.qpa", "aabbc", "libfoo.so.1.2", "xxxy" };
int main(void) {
  uint16_t pb[256], sb[256]; int e; size_t eo; int bad = 0, n = 0;
  for (int it = 0; it < 300; it++) {
    const char *pat = pats[it % 8];
    unsigned opts = (it / 8) % 2 ? 0x80008 : 0x80000;
    void *ri = pcre2_compile_16(u16(pat, pb), strlen(pat), opts, &e, &eo, NULL);
    void *rj = pcre2_compile_16(u16(pat, pb), strlen(pat), opts, &e, &eo, NULL);
    pcre2_jit_compile_16(rj, 1);
    void *mi = pcre2_match_data_create_from_pattern_16(ri, NULL), *mj = pcre2_match_data_create_from_pattern_16(rj, NULL);
    for (int s = 0; s < 8; s++) {
      int a = pcre2_match_16(ri, u16(subs[s], sb), strlen(subs[s]), 0, 0x00002000 /* PCRE2_NO_JIT */, mi, NULL);
      int b = pcre2_match_16(rj, u16(subs[s], sb), strlen(subs[s]), 0, 0, mj, NULL);
      n++;
      if (a != b) { if (bad++ < 10) printf("it=%d pat=%s sub=%s interp=%d jit=%d\n", it, pat, subs[s], a, b); }
    }
    pcre2_match_data_free_16(mi); pcre2_match_data_free_16(mj);
    pcre2_code_free_16(ri); pcre2_code_free_16(rj);
  }
  printf("checks=%d bad=%d\n", n, bad);
  return 0;
}
