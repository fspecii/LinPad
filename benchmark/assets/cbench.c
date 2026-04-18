// cbench.c - 纯 C 性能基准测试
// 测试: 整数计算, 浮点计算, 内存顺序读写, 内存随机读写, 函数调用, 分支预测
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// 精确计时 (毫秒)
static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ─── 1. 整数运算: 加减乘除移位 ───
static volatile long long int_sink;
void bench_integer(void) {
    long long a = 1234567890LL, b = 987654321LL, c = 0;
    for (int i = 0; i < 10000000; i++) {
        c += a * b;
        c ^= (c >> 7);
        a += c & 0xFF;
        b -= (a << 3) ^ c;
        c = c + (a % (b | 1));
    }
    int_sink = c;
}

// ─── 2. 浮点运算 ───
static volatile double fp_sink;
void bench_float(void) {
    double a = 1.23456789, b = 9.87654321, c = 0.0;
    for (int i = 0; i < 5000000; i++) {
        c += a * b;
        a = c / (b + 0.001);
        b = a - c * 0.5;
        c = a * a + b * b;
    }
    fp_sink = c;
}

// ─── 3. 内存顺序写 (64MB) ───
void bench_mem_seq_write(void) {
    int size = 16 * 1024 * 1024; // 16M ints = 64MB
    int *buf = malloc(size * sizeof(int));
    if (!buf) { printf("malloc failed\n"); return; }
    for (int i = 0; i < size; i++) {
        buf[i] = i;
    }
    free(buf);
}

// ─── 4. 内存顺序读 (64MB) ───
static volatile long long mem_read_sink;
void bench_mem_seq_read(void) {
    int size = 16 * 1024 * 1024;
    int *buf = malloc(size * sizeof(int));
    if (!buf) { printf("malloc failed\n"); return; }
    for (int i = 0; i < size; i++) buf[i] = i;

    long long sum = 0;
    for (int i = 0; i < size; i++) {
        sum += buf[i];
    }
    mem_read_sink = sum;
    free(buf);
}

// ─── 5. 内存随机读 (4MB buffer, 2M次随机访问) ───
void bench_mem_random_read(void) {
    int size = 1024 * 1024; // 4MB
    int *buf = malloc(size * sizeof(int));
    if (!buf) { printf("malloc failed\n"); return; }
    for (int i = 0; i < size; i++) buf[i] = i;

    // 简单 LCG 伪随机
    unsigned int rng = 12345;
    long long sum = 0;
    for (int i = 0; i < 2000000; i++) {
        rng = rng * 1103515245 + 12345;
        int idx = (rng >> 16) & (size - 1);
        sum += buf[idx];
    }
    mem_read_sink = sum;
    free(buf);
}

// ─── 6. 内存拷贝 (memcpy 16MB x 4) ───
void bench_memcpy(void) {
    int size = 16 * 1024 * 1024;
    char *src = malloc(size);
    char *dst = malloc(size);
    if (!src || !dst) { printf("malloc failed\n"); return; }
    memset(src, 0xAA, size);
    for (int i = 0; i < 4; i++) {
        memcpy(dst, src, size);
    }
    free(src);
    free(dst);
}

// ─── 7. 函数调用开销 ───
static volatile int call_sink;
int __attribute__((noinline)) add_func(int a, int b) {
    return a + b;
}
void bench_function_call(void) {
    int r = 0;
    for (int i = 0; i < 10000000; i++) {
        r = add_func(r, i);
    }
    call_sink = r;
}

// ─── 8. 分支密集 ───
void bench_branch(void) {
    unsigned int rng = 67890;
    int count = 0;
    for (int i = 0; i < 10000000; i++) {
        rng = rng * 1103515245 + 12345;
        if ((rng & 0xFF) < 128)
            count++;
        else
            count--;
    }
    call_sink = count;
}

// ─── 9. 嵌套循环 (矩阵乘法 128x128) ───
void bench_matmul(void) {
    int N = 128;
    double *A = malloc(N * N * sizeof(double));
    double *B = malloc(N * N * sizeof(double));
    double *C = calloc(N * N, sizeof(double));
    if (!A || !B || !C) { printf("malloc failed\n"); return; }

    for (int i = 0; i < N * N; i++) { A[i] = i * 0.01; B[i] = i * 0.02; }
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            double s = 0;
            for (int k = 0; k < N; k++)
                s += A[i*N+k] * B[k*N+j];
            C[i*N+j] = s;
        }
    fp_sink = C[0];
    free(A); free(B); free(C);
}

// ─── 10. 字符串操作 (strlen + strcmp 密集) ───
void bench_string(void) {
    char buf1[256], buf2[256];
    memset(buf1, 'A', 255); buf1[255] = 0;
    memset(buf2, 'A', 255); buf2[255] = 0;

    int count = 0;
    for (int i = 0; i < 1000000; i++) {
        buf1[i % 255] = 'A' + (i % 26);
        count += strlen(buf1);
        count += strcmp(buf1, buf2);
        buf1[i % 255] = 'A';
    }
    call_sink = count;
}

typedef struct {
    const char *name;
    void (*func)(void);
} Benchmark;

int main(int argc, char *argv[]) {
    Benchmark benches[] = {
        {"integer_arith",    bench_integer},
        {"float_arith",      bench_float},
        {"mem_seq_write",    bench_mem_seq_write},
        {"mem_seq_read",     bench_mem_seq_read},
        {"mem_random_read",  bench_mem_random_read},
        {"memcpy_64MB",      bench_memcpy},
        {"function_call",    bench_function_call},
        {"branch_heavy",     bench_branch},
        {"matmul_128",       bench_matmul},
        {"string_ops",       bench_string},
    };
    int n = sizeof(benches) / sizeof(benches[0]);

    // 可指定单个测试
    const char *filter = (argc > 1) ? argv[1] : NULL;

    for (int i = 0; i < n; i++) {
        if (filter && strcmp(filter, benches[i].name) != 0)
            continue;

        long long t0 = now_ms();
        benches[i].func();
        long long t1 = now_ms();

        printf("%-20s %6lld ms\n", benches[i].name, t1 - t0);
    }
    return 0;
}
