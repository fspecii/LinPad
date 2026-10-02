/*
 * Preloaded into VLC only (by ish-vlc).
 *
 * getuid/geteuid: the iSH desktop session runs as root, and Alpine's /usr/bin/vlc
 * refuses to start when geteuid() == 0. Both are faked (Qt aborts when the real and
 * effective uids differ); the kernel still treats the process as root.
 *
 * XOpenDisplay/XCloseDisplay: Alpine builds VLC's Qt interface with X11 support only,
 * so it refuses to start unless XOpenDisplay(NULL) succeeds, and then asks Qt for the
 * "xcb" platform. build-vlc-wayland.sh patches that request away (Qt then follows
 * QT_QPA_PLATFORM=wayland); this answers the probe with a placeholder that is never
 * used for anything but the matching XCloseDisplay. Only calls made from the Qt
 * plugin with no $DISPLAY are faked; everything else reaches libX11.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

uid_t geteuid(void)
{
    return 65534;
}

uid_t getuid(void)
{
    return 65534;
}

static char placeholder_display[4096];

static int called_from_qt_plugin(void *caller)
{
    Dl_info info;
    return dladdr(caller, &info) && info.dli_fname && strstr(info.dli_fname, "libqt_plugin");
}

void *XOpenDisplay(const char *name)
{
    if (name == NULL && getenv("DISPLAY") == NULL && called_from_qt_plugin(__builtin_return_address(0)))
        return placeholder_display;
    void *(*real)(const char *) = (void *(*)(const char *))dlsym(RTLD_NEXT, "XOpenDisplay");
    return real ? real(name) : NULL;
}

int XCloseDisplay(void *display)
{
    if (display == placeholder_display)
        return 0;
    int (*real)(void *) = (int (*)(void *))dlsym(RTLD_NEXT, "XCloseDisplay");
    return real ? real(display) : 0;
}
