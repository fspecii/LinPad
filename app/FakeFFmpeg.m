// Fake ffmpeg handler for the iSH-ARM64-ffmpeg test target.
// Only compiled when ISH_FFMPEG_TEST=1 (set in AppARM64-ffmpeg.xcconfig).
// Demonstrates native offload by simulating ffmpeg encoding with real file I/O.

#ifdef ISH_FFMPEG_TEST

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
#include "kernel/native_offload.h"

static int fake_ffmpeg_main(int argc, char **argv,
                            int stdin_fd, int stdout_fd, int stderr_fd) {
    (void)stdin_fd;
    const char *input_path = NULL;
    const char *output_path = NULL;

    // Parse args: find -i INPUT and last positional arg as OUTPUT
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) {
            input_path = argv[++i];
        } else if (argv[i][0] != '-') {
            output_path = argv[i];
        }
    }

    // ffmpeg -version: real ffmpeg outputs to stdout
    if (argc >= 2 && strcmp(argv[1], "-version") == 0) {
        dprintf(stdout_fd, "ffmpeg version 8.0-fake (iSH native builtin)\n");
        dprintf(stdout_fd, "built with Apple clang, native offload handler\n");
        dprintf(stdout_fd, "configuration: --enable-native-offload\n");
        dprintf(stdout_fd, "libavutil      59.  0.100\n");
        dprintf(stdout_fd, "libavcodec     61.  0.100\n");
        dprintf(stdout_fd, "libavformat    61.  0.100\n");
        return 0;
    }

    if (!input_path) {
        dprintf(stderr_fd, "fake_ffmpeg: missing -i input\n");
        dprintf(stderr_fd, "Usage: ffmpeg -i input.mp4 [-b:v 1M] output.mp4\n");
        return 1;
    }
    if (!output_path) {
        dprintf(stderr_fd, "fake_ffmpeg: missing output file\n");
        return 1;
    }

    // Open input file
    int in_fd = open(input_path, O_RDONLY);
    if (in_fd < 0) {
        dprintf(stderr_fd, "fake_ffmpeg: %s: %s\n", input_path, strerror(errno));
        return 1;
    }

    // Get input file size
    struct stat st;
    if (fstat(in_fd, &st) < 0) {
        dprintf(stderr_fd, "fake_ffmpeg: fstat: %s\n", strerror(errno));
        close(in_fd);
        return 1;
    }
    off_t input_size = st.st_size;

    // Read and display first 100 bytes (hex dump) to confirm file access
    unsigned char header[100];
    ssize_t hdr_len = read(in_fd, header, sizeof(header));
    if (hdr_len <= 0) {
        dprintf(stderr_fd, "fake_ffmpeg: cannot read input header\n");
        close(in_fd);
        return 1;
    }

    // Stream info to stderr (like real ffmpeg)
    dprintf(stderr_fd, "Input #0, mov, from '%s':\n", input_path);
    dprintf(stderr_fd, "  Duration: 00:00:10.00, start: 0.000000, bitrate: %lld kb/s\n",
            (long long)(input_size * 8 / 10 / 1000));
    dprintf(stderr_fd, "  Stream #0:0: Video: h264 (High), yuv420p, 1920x1080, 30 fps\n");
    dprintf(stderr_fd, "  Stream #0:1: Audio: aac (LC), 44100 Hz, stereo, 128 kb/s\n");
    dprintf(stderr_fd, "Output #0, mp4, to '%s':\n", output_path);
    dprintf(stderr_fd, "  Stream #0:0: Video: h264, 1920x1080, q=2-31, 1000 kb/s\n");
    dprintf(stderr_fd, "  Stream #0:1: Audio: aac, 44100 Hz, stereo, 128 kb/s\n");

    // Header hex dump to stdout (confirms file I/O works)
    dprintf(stdout_fd, "[input] %s (%lld bytes)\n", input_path, (long long)input_size);
    dprintf(stdout_fd, "[header] %zd bytes:", hdr_len);
    for (ssize_t i = 0; i < hdr_len && i < 32; i++)
        dprintf(stdout_fd, " %02x", header[i]);
    dprintf(stdout_fd, " ...\n");
    dprintf(stdout_fd, "[output] %s\n", output_path);

    // Simulate encoding progress (10 lines, 1 per second)
    for (int i = 1; i <= 10; i++) {
        usleep(1000000); // 1 second
        int pct = i * 10;
        double time_s = (double)i / 10.0 * ((double)input_size / 1000000.0);
        dprintf(stderr_fd,
                "frame=%4d fps=30.0 q=28.0 size=%6lldKiB time=00:00:%05.2f "
                "bitrate=1000kbits/s speed=1.00x progress=%d%%\n",
                i * 30, (long long)(input_size * pct / 100 / 1024),
                time_s, pct);
    }

    // Copy input to output (simulating "transcoding")
    lseek(in_fd, 0, SEEK_SET);
    int out_fd = open(output_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        dprintf(stderr_fd, "fake_ffmpeg: %s: %s\n", output_path, strerror(errno));
        close(in_fd);
        return 1;
    }

    char buf[65536];
    ssize_t n;
    off_t copied = 0;
    while ((n = read(in_fd, buf, sizeof(buf))) > 0) {
        ssize_t w = 0;
        while (w < n) {
            ssize_t ret = write(out_fd, buf + w, n - w);
            if (ret < 0) {
                if (errno == EINTR) continue;
                dprintf(stderr_fd, "fake_ffmpeg: write error: %s\n", strerror(errno));
                close(in_fd);
                close(out_fd);
                return 1;
            }
            w += ret;
        }
        copied += n;
    }

    close(in_fd);
    close(out_fd);

    // Completion summary to stderr (like real ffmpeg)
    dprintf(stderr_fd, "video:%lldKiB audio:%lldKiB subtitle:0KiB global headers:0KiB "
            "muxing overhead: 0.000%%\n",
            (long long)(copied * 80 / 100 / 1024),
            (long long)(copied * 20 / 100 / 1024));

    // Completion confirmation to stdout (verifies both fd paths work)
    dprintf(stdout_fd, "[done] Converted %lld bytes: %s -> %s\n",
            (long long)copied, input_path, output_path);

    return 0;
}

void native_builtins_init(void) {
    native_offload_add_handler("ffmpeg", fake_ffmpeg_main);
}

#endif // ISH_FFMPEG_TEST
