// Windowed GLES2 test on Wayland: xdg toplevel + EGL window surface + swaps.
// usage: glwin [frames] [width] [height]
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct xdg_wm_base *wm_base;
static struct wl_subcompositor *subcomp;
static struct wl_shm *shm;
static int configured;

static void registry_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    if (!strcmp(iface, wl_compositor_interface.name))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (!strcmp(iface, wl_subcompositor_interface.name))
        subcomp = wl_registry_bind(reg, name, &wl_subcompositor_interface, 1);
    else if (!strcmp(iface, wl_shm_interface.name))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, xdg_wm_base_interface.name))
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
}
static void registry_remove(void *data, struct wl_registry *reg, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

static void wm_ping(void *data, struct xdg_wm_base *b, uint32_t serial) { xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_listener = {wm_ping};
static void surf_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    xdg_surface_ack_configure(s, serial);
    configured = 1;
}
static const struct xdg_surface_listener surf_listener = {surf_configure};
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {}
static void top_close(void *d, struct xdg_toplevel *t) {}
static const struct xdg_toplevel_listener top_listener = {top_configure, top_close};

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *vs = "attribute vec2 p; uniform float t; varying vec3 c;\n"
    "void main(){ float a=t; mat2 r=mat2(cos(a),sin(a),-sin(a),cos(a));\n"
    " gl_Position=vec4(r*p*0.8,0.0,1.0); c=vec3(p*0.5+0.5,0.5+0.5*sin(t)); }\n";
static const char *fs = "precision mediump float; varying vec3 c; void main(){ gl_FragColor=vec4(c,1.0); }\n";

int main(int argc, char **argv) {
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    int width = argc > 2 ? atoi(argv[2]) : 640;
    int height = argc > 3 ? atoi(argv[3]) : 480;

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "no wayland display\n");
        return 1;
    }
    struct wl_registry *reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(display);
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xsurf = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xsurf, &surf_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xsurf);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "glwin");
    xdg_toplevel_set_app_id(top, "glwin");
    wl_surface_commit(surface);
    while (!configured)
        wl_display_dispatch(display);

    struct wl_surface *gl_surface = surface;
    if (getenv("GLWIN_SUB")) {
        /* Like Firefox: toplevel with an shm buffer, GL in a desync subsurface on top. */
        int stride = width * 4, size = stride * height;
        int fd = memfd_create("glwin-bg", 0);
        ftruncate(fd, size);
        uint32_t *px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        for (int i = 0; i < width * height; i++) px[i] = 0xffffffff;
        struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
        struct wl_buffer *bg = wl_shm_pool_create_buffer(pool, 0, width, height, stride, WL_SHM_FORMAT_XRGB8888);
        wl_surface_attach(surface, bg, 0, 0);
        wl_surface_damage(surface, 0, 0, width, height);
        gl_surface = wl_compositor_create_surface(compositor);
        struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcomp, gl_surface, surface);
        wl_subsurface_set_position(sub, 20, 20);
        wl_subsurface_set_desync(sub);
        wl_surface_commit(surface);
        width -= 40; height -= 40;
    }
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, display, NULL);
    eglInitialize(dpy, NULL, NULL);
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint cattr[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, getenv("GLWIN_ALPHA") ? 8 : 0, EGL_NONE};
    EGLConfig cfg;
    EGLint n;
    eglChooseConfig(dpy, cattr, &cfg, 1, &n);
    static const EGLint xattr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, xattr);
    struct wl_egl_window *win = wl_egl_window_create(gl_surface, width, height);
    EGLSurface esurf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType) win, NULL);
    if (esurf == EGL_NO_SURFACE || !eglMakeCurrent(dpy, esurf, esurf, ctx)) {
        fprintf(stderr, "egl surface/context failed: %#x\n", eglGetError());
        return 1;
    }
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    fflush(stdout);

    GLuint prog = glCreateProgram();
    GLuint s1 = glCreateShader(GL_VERTEX_SHADER), s2 = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(s1, 1, &vs, NULL);
    glCompileShader(s1);
    glShaderSource(s2, 1, &fs, NULL);
    glCompileShader(s2);
    glAttachShader(prog, s1);
    glAttachShader(prog, s2);
    glBindAttribLocation(prog, 0, "p");
    glLinkProgram(prog);
    glUseProgram(prog);
    GLint ut = glGetUniformLocation(prog, "t");
    static const float tri[] = {0.0f, 1.0f, -0.866f, -0.5f, 0.866f, -0.5f};
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
    glEnableVertexAttribArray(0);
    glViewport(0, 0, width, height);

    double start = now();
    for (int f = 0; f < frames; f++) {
        glClearColor(0.1f, 0.1f, 0.15f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glUniform1f(ut, f / 60.0f);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        eglSwapBuffers(dpy, esurf);
        wl_display_dispatch_pending(display);
    }
    double secs = now() - start;
    printf("presented %d frames %dx%d in %.2f s = %.1f FPS\n", frames, width, height, secs, frames / secs);
    eglTerminate(dpy);
    return 0;
}
