// cbench_lite.c — lightweight C benchmark for emulators
// Reduced workloads to finish in ~30s under emulation
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static volatile long long sink_i;
static volatile double sink_f;
static volatile int sink_c;

// Integer: 2M ops (vs 10M in full)
void bench_integer(void) {
    long long a = 1234567890LL, b = 987654321LL, c = 0;
    for (int i = 0; i < 2000000; i++) {
        c += a * b; c ^= (c >> 7);
        a += c & 0xFF; b -= (a << 3) ^ c;
        c = c + (a % (b | 1));
    }
    sink_i = c;
}

// Float: 1M ops (vs 5M)
void bench_float(void) {
    double a = 1.23, b = 9.87, c = 0.0;
    for (int i = 0; i < 1000000; i++) {
        c += a * b; a = c / (b + 0.001);
        b = a - c * 0.5; c = a * a + b * b;
    }
    sink_f = c;
}

// Memory sequential: 4MB (vs 64MB)
void bench_mem_seq(void) {
    int size = 1024 * 1024; // 4MB
    int *buf = malloc(size * sizeof(int));
    if (!buf) return;
    for (int i = 0; i < size; i++) buf[i] = i;
    long long sum = 0;
    for (int i = 0; i < size; i++) sum += buf[i];
    sink_i = sum;
    free(buf);
}

// Memory random: 1MB, 500K accesses (vs 4MB, 2M)
void bench_mem_rand(void) {
    int size = 256 * 1024;
    int *buf = malloc(size * sizeof(int));
    if (!buf) return;
    for (int i = 0; i < size; i++) buf[i] = i;
    unsigned int rng = 12345;
    long long sum = 0;
    for (int i = 0; i < 500000; i++) {
        rng = rng * 1103515245 + 12345;
        sum += buf[(rng >> 16) & (size - 1)];
    }
    sink_i = sum;
    free(buf);
}

// Function call: 2M (vs 10M)
int __attribute__((noinline)) add_func(int a, int b) { return a + b; }
void bench_call(void) {
    int r = 0;
    for (int i = 0; i < 2000000; i++) r = add_func(r, i);
    sink_c = r;
}

// Branch: 2M (vs 10M)
void bench_branch(void) {
    unsigned int rng = 67890;
    int count = 0;
    for (int i = 0; i < 2000000; i++) {
        rng = rng * 1103515245 + 12345;
        if ((rng & 0xFF) < 128) count++; else count--;
    }
    sink_c = count;
}

// Matrix: 64x64 (vs 128x128)
void bench_matrix(void) {
    int N = 64;
    double *A = malloc(N*N*sizeof(double));
    double *B = malloc(N*N*sizeof(double));
    double *C = calloc(N*N, sizeof(double));
    if (!A||!B||!C) return;
    for (int i = 0; i < N*N; i++) { A[i] = i*0.01; B[i] = i*0.02; }
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            double s = 0;
            for (int k = 0; k < N; k++) s += A[i*N+k] * B[k*N+j];
            C[i*N+j] = s;
        }
    sink_f = C[0];
    free(A); free(B); free(C);
}

// String: 200K ops (vs 1M)
void bench_string(void) {
    char buf1[256], buf2[256];
    memset(buf1, 'A', 255); buf1[255] = 0;
    memset(buf2, 'A', 255); buf2[255] = 0;
    int count = 0;
    for (int i = 0; i < 200000; i++) {
        buf1[i % 255] = 'A' + (i % 26);
        count += strlen(buf1) + strcmp(buf1, buf2);
        buf1[i % 255] = 'A';
    }
    sink_c = count;
}

int main(void) {
    struct { const char *name; void (*fn)(void); } tests[] = {
        {"int_arith_2M",  bench_integer},
        {"float_arith_1M", bench_float},
        {"mem_seq_4MB",   bench_mem_seq},
        {"mem_rand_500K", bench_mem_rand},
        {"func_call_2M",  bench_call},
        {"branch_2M",     bench_branch},
        {"matrix_64x64",  bench_matrix},
        {"string_200K",   bench_string},
    };
    int n = sizeof(tests)/sizeof(tests[0]);
    for (int i = 0; i < n; i++) {
        long long t0 = now_ms();
        tests[i].fn();
        long long t1 = now_ms();
        printf("%-18s %6lld ms\n", tests[i].name, t1 - t0);
    }
    return 0;
}
