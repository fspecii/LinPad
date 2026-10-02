#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <virglrenderer.h>

static void wcf(void *c, uint32_t ctx, uint32_t ring, uint64_t id) { printf("fence ctx=%u ring=%u id=%llu\n", ctx, ring, (unsigned long long)id); }
static void logcb(enum virgl_log_level_flags l, const char *m, void *d) { fprintf(stderr, "virgl[%d]: %s", l, m); }

int main(void) {
    static struct virgl_renderer_callbacks cbs = { .version = 3, .write_context_fence = wcf };
    virgl_set_log_callback(logcb, NULL, NULL);
    int flags = VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL | VIRGL_RENDERER_RENDER_SERVER |
                VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB;
    int r = virgl_renderer_init(NULL, flags, &cbs);
    printf("init %d\n", r);
    uint32_t maxver = 0, maxsize = 0;
    virgl_renderer_get_cap_set(4, &maxver, &maxsize);
    printf("venus capset ver %u size %u\n", maxver, maxsize);
    if (!maxsize) return 1;
    uint32_t *caps = calloc(1, maxsize);
    virgl_renderer_fill_caps(4, 0, caps);
    printf("wire_format_version %u vk_xml %x\n", caps[0], caps[1]);
    r = virgl_renderer_context_create_with_flags(1, 4, 4, "smoke");
    printf("ctx create %d\n", r);
    virgl_renderer_context_destroy(1);
    virgl_renderer_cleanup(NULL);
    return 0;
}
