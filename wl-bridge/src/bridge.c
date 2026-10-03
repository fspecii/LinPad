/* The host channel: two FIFOs in runtime_dir, which in iSH are real host FIFOs
 * inside the fakefs data directory, so the iOS app opens them directly.
 *   events  host → ishwl   input, configure, acks
 *   notify  ishwl → host   views, titles, frames
 * One message per line, space separated; strings are percent-encoded.
 * See DESIGN.md for the full message list. */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ishwl.h"

char *bridge_escape(const char *text) {
    size_t len = strlen(text);
    char *out = malloc(len * 3 + 2), *o = out;
    if (!out) return NULL;
    for (const unsigned char *p = (const unsigned char *) text; *p; p++) {
        if (*p <= ' ' || *p == '%' || *p == 0x7f)
            o += sprintf(o, "%%%02X", *p);
        else
            *o++ = *p;
    }
    if (o == out)
        *o++ = '-';  /* keeps the field count fixed for empty strings */
    else if (o == out + 1 && out[0] == '-')
        o += sprintf(out, "%%2D") - 1;  /* a lone "-" would read back as empty */
    *o = '\0';
    return out;
}

static void unescape(char *s) {
    if (strcmp(s, "-") == 0) {
        *s = '\0';
        return;
    }
    char *o = s;
    for (char *p = s; *p; p++) {
        if (p[0] == '%' && p[1] && p[2]) {
            char hex[3] = {p[1], p[2], 0};
            *o++ = (char) strtol(hex, NULL, 16);
            p += 2;
        } else {
            *o++ = *p;
        }
    }
    *o = '\0';
}

void bridge_send(struct server *s, const char *fmt, ...) {
    if (s->notify_fd < 0) return;
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n >= (int) sizeof(line)) {
        n = sizeof(line) - 1;
        line[n - 1] = '\n';
    }
    /* Lines are below PIPE_BUF, so each write is atomic and never interleaves. */
    if (write(s->notify_fd, line, n) != n)
        log_msg(s, "notify write failed (%s), host not reading?", strerror(errno));
}

static void resend_views(struct server *s) {
    struct view *v;
    wl_list_for_each(v, &s->views, link) {
        if (!v->mapped) continue;
        view_announce(v);
        v->awaiting_ack = false;
        view_damage(v, FULL_DAMAGE);
    }
}

static void handle_line(struct server *s, char *line) {
    if (s->verbose > 1 && strncmp(line, "ack ", 4) != 0)
        log_msg(s, "host: %s", line);
    char *argv[12];
    int argc = 0;
    for (char *tok = strtok(line, " "); tok && argc < 12; tok = strtok(NULL, " "))
        argv[argc++] = tok;
    if (argc == 0) return;
    const char *cmd = argv[0];
    struct view *v = argc > 1 ? view_by_id(s, (uint32_t) strtoul(argv[1], NULL, 10)) : NULL;
#define ARGF(i) (argc > (i) ? strtod(argv[i], NULL) : 0.0)
#define ARGI(i) (argc > (i) ? (int32_t) strtol(argv[i], NULL, 10) : 0)

    if (strcmp(cmd, "ack") == 0) {
        if (v) view_ack(v, (uint32_t) strtoul(argc > 2 ? argv[2] : "0", NULL, 10));
    } else if (strcmp(cmd, "motion") == 0) {
        if (v) seat_pointer_motion(s, v, ARGF(2), ARGF(3));
    } else if (strcmp(cmd, "button") == 0) {
        seat_pointer_button(s, v, ARGF(2), ARGF(3), (uint32_t) ARGI(4), ARGI(5) != 0);
    } else if (strcmp(cmd, "axis") == 0) {
        seat_pointer_axis(s, v, ARGF(2), ARGF(3),
                          argc > 4 ? (uint32_t) ARGI(4) : WL_POINTER_AXIS_SOURCE_CONTINUOUS);
    } else if (strcmp(cmd, "axis_stop") == 0) {
        seat_pointer_axis_stop(s);
    } else if (strcmp(cmd, "leave") == 0) {
        seat_pointer_leave(s);
    } else if (strcmp(cmd, "key") == 0) {
        text_input_key(s, (uint32_t) strtoul(argv[1], NULL, 10), ARGI(2) != 0);
    } else if (strcmp(cmd, "text") == 0 && argc > 1) {
        unescape(argv[1]);
        text_input_type(s, argv[1]);
    } else if (strcmp(cmd, "ime") == 0 && argc > 6) {
        unescape(argv[3]);
        unescape(argv[4]);
        text_input_apply(s, (uint32_t) ARGI(1), (uint32_t) ARGI(2), argv[3], argv[4], ARGI(5), ARGI(6));
    } else if (strcmp(cmd, "keymap") == 0 && argc > 3) {
        for (int i = 1; i <= 3; i++) unescape(argv[i]);
        text_input_set_keymap(s, argv[1], argv[2], argv[3]);
    } else if (strcmp(cmd, "focus") == 0) {
        seat_focus_view(s, v);
    } else if (strcmp(cmd, "configure") == 0) {
        if (v && v->kind == VIEW_TOPLEVEL) {
            v->host_width = ARGI(2);
            v->host_height = ARGI(3);
            if (argc > 4) v->maximized = ARGI(4) != 0;
            view_configure(v);
        }
    } else if (strcmp(cmd, "close") == 0) {
        if (v) view_send_close(v);
    } else if (strcmp(cmd, "selection") == 0) {
        clipboard_set_from_host(s);
    } else if (strcmp(cmd, "dismiss") == 0) {
        view_dismiss_popups(s, NULL);
    } else if (strcmp(cmd, "spawn") == 0 && argc > 1) {
        unescape(argv[1]);
        spawn_command(s, argv[1]);
    } else if (strcmp(cmd, "hello") == 0) {
        resend_views(s);
    } else if (strcmp(cmd, "quit") == 0) {
        s->running = false;
    } else if (strncmp(cmd, "dnd_", 4) == 0) {
        dnd_handle(s, argc, argv);
    } else {
        log_msg(s, "unknown bridge message '%s'", cmd);
    }
    wl_display_flush_clients(s->display);
#undef ARGF
#undef ARGI
}

static int events_readable(int fd, uint32_t mask, void *data) {
    struct server *s = data;
    for (;;) {
        ssize_t n = read(fd, s->event_buf + s->event_len, sizeof(s->event_buf) - 1 - s->event_len);
        if (n <= 0)
            break;
        s->event_len += n;
        s->event_buf[s->event_len] = '\0';
        char *start = s->event_buf, *nl;
        while ((nl = strchr(start, '\n'))) {
            *nl = '\0';
            handle_line(s, start);
            start = nl + 1;
        }
        s->event_len -= start - s->event_buf;
        memmove(s->event_buf, start, s->event_len);
        if (s->event_len == sizeof(s->event_buf) - 1)
            s->event_len = 0; /* an absurdly long line: drop it */
    }
    return 0;
}

static int open_fifo(struct server *s, const char *name) {
    char path[256];
    snprintf(path, sizeof(path), "%s/%s", s->runtime_dir, name);
    struct stat st;
    if (stat(path, &st) == 0 && !S_ISFIFO(st.st_mode))
        unlink(path);
    if (mkfifo(path, 0600) < 0 && errno != EEXIST) {
        fprintf(stderr, "ishwl: mkfifo %s: %s\n", path, strerror(errno));
        exit(1);
    }
    /* O_RDWR keeps the FIFO open on our side, so neither end sees EOF or
     * ENXIO when the other comes and goes. */
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "ishwl: open %s: %s\n", path, strerror(errno));
        exit(1);
    }
    return fd;
}

/* Held for ishwl's lifetime. The host app tests it with flock(LOCK_NB) on the same
 * file to tell whether ishwl is alive (guest flock is a host flock in iSH), and a
 * second ishwl refuses to start. */
static void take_alive_lock(struct server *s) {
    char path[256];
    snprintf(path, sizeof(path), "%s/alive", s->runtime_dir);
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) < 0) {
        fprintf(stderr, "ishwl: another ishwl is using %s\n", s->runtime_dir);
        exit(1);
    }
}

void bridge_init(struct server *s) {
    mkdir(s->runtime_dir, 0700);
    take_alive_lock(s);
    s->events_fd = open_fifo(s, "events");
    wl_event_loop_add_fd(s->loop, s->events_fd, WL_EVENT_READABLE, events_readable, s);
    s->notify_fd = s->headless ? -1 : open_fifo(s, "notify");
}
