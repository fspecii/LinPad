// Host-side memory sampler for the low-memory runs (devtools/bench/lowmem.sh).
//   memsample PID INTERVAL_MS LIMIT_MB > samples.tsv
// One line per sample: seconds, phys_footprint MB, lifetime max footprint MB, MB written
// to disk by the process. proc_pid_rusage needs no task port, so it works on any
// process of the same user. LIMIT_MB counts "kills": each time the footprint goes from
// below the emulated limit to at or above it, which is when iPadOS would have killed
// the app. The summary is printed to stderr when PID exits.
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: memsample PID INTERVAL_MS LIMIT_MB\n");
        return 2;
    }
    int pid = atoi(argv[1]);
    useconds_t interval = (useconds_t) atoi(argv[2]) * 1000;
    double limit = atof(argv[3]);
    struct timespec t0, t;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    double peak = 0, written = 0;
    int kills = 0, above = 0;
    for (;;) {
        struct rusage_info_v4 ri;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *) &ri) != 0)
            break;
        clock_gettime(CLOCK_MONOTONIC, &t);
        double fp = ri.ri_phys_footprint / 1048576.0;
        double life = ri.ri_lifetime_max_phys_footprint / 1048576.0;
        written = ri.ri_diskio_byteswritten / 1048576.0;
        if (fp > peak)
            peak = fp;
        if (limit > 0 && fp >= limit && !above)
            kills++;
        above = limit > 0 && fp >= limit;
        printf("%.2f\t%.0f\t%.0f\t%.0f\n", (t.tv_sec - t0.tv_sec) + (t.tv_nsec - t0.tv_nsec) / 1e9,
               fp, life, written);
        fflush(stdout);
        usleep(interval);
    }
    fprintf(stderr, "memsample: peak %.0f MB, would-be kills %d (limit %.0f MB), disk written %.0f MB\n",
            peak, kills, limit, written);
    return 0;
}
