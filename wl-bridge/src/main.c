/* ishwl: a Wayland compositor that runs inside the iSH guest and hands every
 * toplevel to the iOS DesktopKit desktop as its own native window. */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "ishwl.h"

#define TICK_MS 16
#define IDLE_TICK_MS 1000

static pid_t exit_with_pid = -1;
static int exit_with_status;

uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t) (ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

void log_msg(struct server *s, const char *fmt, ...) {
    if (!s->verbose) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "ishwl %u.%03u: ", now_ms() / 1000 % 100000, now_ms() % 1000);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

void spawn_command(struct server *s, const char *command) {
    pid_t pid = fork();
    if (pid < 0) {
        log_msg(s, "fork failed: %s", strerror(errno));
        return;
    }
    if (pid > 0) {
        log_msg(s, "spawned %d: %s", pid, command);
        return;
    }
    setsid();
    /* The launcher applies /etc/ishwl/apps (X11-only apps, compat preloads). */
    execl(ISHWL_PREFIX "/bin/ishwl-launch", "ishwl-launch", command, (char *) NULL);
    execl("/bin/sh", "sh", "-c", command, (char *) NULL);
    _exit(127);
}

/* libwayland's signal sources need signalfd, which iSH does not implement, so
 * children are reaped from the tick instead. */
static void reap_children(struct server *s) {
    int status;
    pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        log_msg(s, "child %d exited (%d)", pid, status);
        if (pid == exit_with_pid) {
            s->running = false;
            exit_with_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        }
    }
}

static void tick(struct server *s) {
    if (!wl_list_empty(&s->orphan_callbacks))
        surface_send_frame_done(&s->orphan_callbacks, now_ms());
    struct view *v;
    wl_list_for_each(v, &s->views, link) {
        if (v->png_dirty)
            view_flush_callbacks(v);
        view_check_ack(v);
    }
    text_input_tick(s);
    reap_children(s);
}

static bool tick_pending(struct server *s) {
    if (!wl_list_empty(&s->orphan_callbacks) || text_input_waiting(s))
        return true;
    struct view *v;
    wl_list_for_each(v, &s->views, link)
        if (v->png_dirty)
            return true;
    return false;
}

/* wl_display_run() would need wl_event_loop timers, which are timerfds armed
 * with TFD_TIMER_ABSTIME; under iSH those stall the whole loop. A dispatch
 * timeout gives the same tick without them. When idle the loop wakes once a
 * second, only to reap children. */
static void run(struct server *s) {
    uint32_t last_tick = now_ms();
    while (s->running) {
        wl_display_flush_clients(s->display);
        uint32_t period = tick_pending(s) ? TICK_MS : IDLE_TICK_MS;
        int32_t wait = (int32_t) (last_tick + period - now_ms());
        wl_event_loop_dispatch(s->loop, wait > 0 ? wait : 0);
        period = tick_pending(s) ? TICK_MS : IDLE_TICK_MS;
        if (now_ms() - last_tick >= period) {
            tick(s);
            last_tick = now_ms();
        }
    }
}

/* Commands started with the session so their app is already resident when the
 * user opens it (e.g. "thunar --daemon"); one per line, # for comments. */
static void run_prewarm(struct server *s, const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = '\0';
        const char *command = line + strspn(line, " \t");
        if (*command && *command != '#')
            spawn_command(s, command);
    }
    fclose(f);
}

/* Hosts give unix sockets small buffers (8 KiB on Darwin, against ~200 KiB on Linux)
 * and iSH's sockets are host sockets. A client that queues requests faster than
 * ishwl reads them then sees EAGAIN from wl_display_flush, which GDK treats as fatal
 * ("Error flushing display"); Firefox hits this right after its first frame. */
static void client_destroyed(struct wl_listener *listener, void *data) {
    pid_t pid;
    wl_client_get_credentials(data, &pid, NULL, NULL);
    fprintf(stderr, "ishwl: client %d disconnected\n", pid);
}

static void client_created(struct wl_listener *listener, void *data) {
    int fd = wl_client_get_fd(data);
    int size = 1 << 20;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    struct wl_listener *destroyed = calloc(1, sizeof(*destroyed));
    if (destroyed) {
        destroyed->notify = client_destroyed;
        wl_client_add_destroy_listener(data, destroyed);
    }
}

static struct wl_listener client_created_listener = {.notify = client_created};

static void usage(void) {
    fprintf(stderr,
            "usage: ishwl [options] [-- command...]\n"
            "  -s, --socket NAME       Wayland socket name (default wayland-0)\n"
            "  -r, --runtime-dir DIR   frame buffers and bridge FIFOs (default /tmp/ishwl)\n"
            "  -H, --headless          no host app; frames are acked locally\n"
            "  -p, --png-dir DIR       headless: write each view's latest frame as PNG\n"
            "  -g, --size WxH          advertised output size in points (default 1180x780)\n"
            "  -S, --scale N           output scale; 2 renders at Retina resolution (default 2)\n"
            "  -w, --prewarm FILE      commands to start with the session (default /etc/ishwl/prewarm)\n"
            "  -v, --verbose          repeat (-vv) to log every host message\n"
            "With a command, it runs as a client and ishwl exits when it does.\n");
}

int main(int argc, char **argv) {
    struct server s = {
        .socket_name = "wayland-0",
        .runtime_dir = "/tmp/ishwl",
        .output_width = 1180,
        .output_height = 780,
        .output_scale = 2,
        .next_view_id = 1,
        .events_fd = -1,
        .notify_fd = -1,
    };
    static const struct option options[] = {
        {"socket", required_argument, NULL, 's'},
        {"runtime-dir", required_argument, NULL, 'r'},
        {"headless", no_argument, NULL, 'H'},
        {"png-dir", required_argument, NULL, 'p'},
        {"size", required_argument, NULL, 'g'},
        {"scale", required_argument, NULL, 'S'},
        {"prewarm", required_argument, NULL, 'w'},
        {"verbose", no_argument, NULL, 'v'},
        {"help", no_argument, NULL, 'h'},
        {0},
    };
    const char *prewarm = "/etc/ishwl/prewarm";
    int opt;
    while ((opt = getopt_long(argc, argv, "+s:r:Hp:g:S:w:vh", options, NULL)) != -1) {
        switch (opt) {
        case 's': s.socket_name = optarg; break;
        case 'r': s.runtime_dir = optarg; break;
        case 'H': s.headless = true; break;
        case 'p': s.png_dir = optarg; s.headless = true; break;
        case 'g': sscanf(optarg, "%dx%d", &s.output_width, &s.output_height); break;
        case 'S': s.output_scale = atoi(optarg) > 0 ? atoi(optarg) : 1; break;
        case 'w': prewarm = optarg; break;
        case 'v': s.verbose++; break;
        default: usage(); return opt == 'h' ? 0 : 1;
        }
    }

    signal(SIGPIPE, SIG_IGN);
    if (!getenv("XDG_RUNTIME_DIR"))
        setenv("XDG_RUNTIME_DIR", "/tmp/xdg-runtime", 1);
    mkdir(getenv("XDG_RUNTIME_DIR"), 0700);
    /* musl's shm_open (GTK's fallback when memfd_create is missing, as in iSH) needs it. */
    mkdir("/dev/shm", 01777);

    wl_list_init(&s.views);
    wl_list_init(&s.output_resources);
    wl_list_init(&s.orphan_callbacks);
    s.display = wl_display_create();
    s.loop = wl_display_get_event_loop(s.display);
    if (wl_display_add_socket(s.display, s.socket_name) < 0) {
        fprintf(stderr, "ishwl: cannot create socket %s/%s: %s\n", getenv("XDG_RUNTIME_DIR"),
                s.socket_name, strerror(errno));
        return 1;
    }

    wl_display_add_client_created_listener(s.display, &client_created_listener);
    /* libwayland drops a client whose unsent events exceed this; the default (4 KiB)
     * is too small once the host socket buffer is full as well. */
    wl_display_set_default_max_buffer_size(s.display, 1 << 20);
    compositor_init(&s);
    shm_init(&s);
    xdg_init(&s);
    seat_init(&s);
    text_input_init(&s);
    misc_globals_init(&s);
    bridge_init(&s);
    clipboard_init(&s);
    dnd_init(&s);
    dmabuf_init(&s);

    const char *scm_compat = ISHWL_PREFIX "/lib/libishwl-scm.so";
    if (access(scm_compat, R_OK) == 0 && !strstr(getenv("LD_PRELOAD") ? getenv("LD_PRELOAD") : "", scm_compat)) {
        const char *preload = getenv("LD_PRELOAD");
        char value[1024];
        snprintf(value, sizeof(value), "%s%s%s", scm_compat, preload ? ":" : "", preload ? preload : "");
        setenv("LD_PRELOAD", value, 1);
    }
    setenv("WAYLAND_DISPLAY", s.socket_name, 1);
    setenv("GDK_BACKEND", "wayland", 1);
    setenv("MOZ_ENABLE_WAYLAND", "1", 1);
    setenv("QT_QPA_PLATFORM", "wayland", 1);
    unsetenv("DISPLAY");

    bridge_send(&s, "hello 1 %s\n", s.socket_name);
    log_msg(&s, "listening on %s/%s, runtime %s%s", getenv("XDG_RUNTIME_DIR"), s.socket_name,
            s.runtime_dir, s.headless ? " (headless)" : "");
    log_msg(&s, "scm-compat: %s", scm_compat_mode());

    if (!s.headless)
        run_prewarm(&s, prewarm);

    if (optind < argc) {
        exit_with_pid = fork();
        if (exit_with_pid == 0) {
            setsid();
            execvp(argv[optind], argv + optind);
            fprintf(stderr, "ishwl: %s: %s\n", argv[optind], strerror(errno));
            _exit(127);
        }
    }

    s.running = true;
    run(&s);
    bridge_send(&s, "bye\n");
    wl_display_destroy_clients(s.display);
    wl_display_destroy(s.display);
    return exit_with_status;
}
