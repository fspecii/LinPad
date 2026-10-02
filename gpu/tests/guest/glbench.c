// Offscreen GLES2 benchmark on EGL (surfaceless platform, FBO target).
// usage: glbench [frames] [width] [height] [triangles] [out.ppm]
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *vs_src =
    "attribute float idx;\n"
    "uniform float t; uniform float tris;\n"
    "varying vec3 color;\n"
    "void main() {\n"
    "  float tri = floor(idx / 3.0); float corner = idx - tri * 3.0;\n"
    "  float a = tri * 2.399963 + t * (0.2 + mod(tri, 7.0) * 0.05);\n"
    "  float r = 0.95 * sqrt(tri / tris);\n"
    "  vec2 center = vec2(cos(a), sin(a)) * r;\n"
    "  float ca = t * 2.0 + tri;\n"
    "  vec2 o = corner < 0.5 ? vec2(0.0, -1.0) : (corner < 1.5 ? vec2(0.866, 0.5) : vec2(-0.866, 0.5));\n"
    "  vec2 ro = vec2(o.x * cos(ca) - o.y * sin(ca), o.x * sin(ca) + o.y * cos(ca));\n"
    "  gl_Position = vec4(center + ro * 0.05, 0.0, 1.0);\n"
    "  color = vec3(0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a * 1.3), corner * 0.5);\n"
    "}\n";
static const char *fs_src =
    "precision highp float;\n"
    "uniform float t;\n"
    "varying vec3 color;\n"
    "void main() {\n"
    "  vec2 p = gl_FragCoord.xy / 300.0; float v = 0.0;\n"
    "  for (int i = 0; i < 16; i++) v += sin(p.x * float(i + 1) + t) * cos(p.y * float(i + 2) - t);\n"
    "  gl_FragColor = vec4(color * (0.75 + 0.25 * sin(v)), 1.0);\n"
    "}\n";

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "shader: %s\n", log);
        exit(1);
    }
    return s;
}

int main(int argc, char **argv) {
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    int width = argc > 2 ? atoi(argv[2]) : 1280;
    int height = argc > 3 ? atoi(argv[3]) : 720;
    int tris = argc > 4 ? atoi(argv[4]) : 20000;
    const char *out = argc > 5 ? argv[5] : "/tmp/glbench.ppm";

    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC) eglGetProcAddress("eglGetPlatformDisplayEXT");
    // GLBENCH_PLATFORM=wayland goes through the Wayland platform (zink uses
    // kopper there and needs no DRM fd); the default is surfaceless.
    const char *platform = getenv("GLBENCH_PLATFORM");
    EGLDisplay dpy = platform && !strcmp(platform, "wayland")
        ? get_platform_display(EGL_PLATFORM_WAYLAND_EXT, EGL_DEFAULT_DISPLAY, NULL)
        : get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint major, minor;
    if (!eglInitialize(dpy, &major, &minor)) {
        fprintf(stderr, "eglInitialize failed: %#x\n", eglGetError());
        return 1;
    }
    static const EGLint cfg_attr[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
    EGLConfig cfg;
    EGLint n = 0;
    eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n);
    eglBindAPI(EGL_OPENGL_ES_API);
    static const EGLint ctx_attr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, n ? cfg : EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attr);
    if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
        fprintf(stderr, "context failed: %#x\n", eglGetError());
        return 1;
    }
    printf("GL_RENDERER: %s\nGL_VERSION: %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

    GLuint tex, fbo;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "fbo incomplete\n");
        return 1;
    }

    GLuint prog = glCreateProgram();
    glAttachShader(prog, compile(GL_VERTEX_SHADER, vs_src));
    glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fs_src));
    glBindAttribLocation(prog, 0, "idx");
    glLinkProgram(prog);
    glUseProgram(prog);
    GLint ut = glGetUniformLocation(prog, "t"), utris = glGetUniformLocation(prog, "tris");

    float *idx = malloc(sizeof(float) * tris * 3);
    for (int i = 0; i < tris * 3; i++)
        idx[i] = i;
    GLuint vbo;
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(float) * tris * 3, idx, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, 0);
    glViewport(0, 0, width, height);

    double start = 0;
    for (int f = 0; f <= frames; f++) {
        if (f == 1)
            start = now();
        glClearColor(0.05f, 0.05f, 0.1f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glUniform1f(ut, f / 60.0f);
        glUniform1f(utris, tris);
        glDrawArrays(GL_TRIANGLES, 0, tris * 3);
        glFinish();
    }
    double secs = now() - start;
    printf("render %dx%d, %d triangles: %d frames in %.2f s = %.1f FPS\n", width, height, tris, frames, secs, frames / secs);

    unsigned char *px = malloc((size_t) width * height * 4);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, px);
    FILE *fp = fopen(out, "wb");
    if (fp) {
        fprintf(fp, "P6\n%d %d\n255\n", width, height);
        for (int y = height - 1; y >= 0; y--)
            for (int x = 0; x < width; x++)
                fwrite(px + ((size_t) y * width + x) * 4, 1, 3, fp);
        fclose(fp);
        printf("wrote %s\n", out);
    }
    eglTerminate(dpy);
    return 0;
}
