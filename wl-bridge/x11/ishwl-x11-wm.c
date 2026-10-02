/* The window manager of an ishwl-x11 server, which runs a single app: its
 * top-level windows fill the screen (the host window) instead of opening at the
 * size and place the app asked for. Dialogs and other transient windows keep their
 * size and are centred over the screen. Exits when the X server goes away. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>

static int ignore_error(Display *display, XErrorEvent *event) {
    (void) display;
    (void) event;
    return 0;
}

static void place(Display *display, Window window) {
    int screen = DefaultScreen(display);
    int width = DisplayWidth(display, screen), height = DisplayHeight(display, screen);
    Window parent;
    if (XGetTransientForHint(display, window, &parent)) {
        XWindowAttributes attributes;
        if (!XGetWindowAttributes(display, window, &attributes))
            return;
        XMoveWindow(display, window, (width - attributes.width) / 2, (height - attributes.height) / 2);
    } else {
        XMoveResizeWindow(display, window, 0, 0, (unsigned) width, (unsigned) height);
    }
}

int main(void) {
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        fprintf(stderr, "ishwl-x11-wm: cannot open display\n");
        return 1;
    }
    /* Windows can vanish between an event and the request answering it. */
    XSetErrorHandler(ignore_error);
    Window root = DefaultRootWindow(display);
    XSelectInput(display, root, SubstructureRedirectMask | SubstructureNotifyMask);
    XSync(display, False);

    for (;;) {
        XEvent event;
        XNextEvent(display, &event);
        switch (event.type) {
        case MapRequest:
            place(display, event.xmaprequest.window);
            XMapRaised(display, event.xmaprequest.window);
            XSetInputFocus(display, event.xmaprequest.window, RevertToPointerRoot, CurrentTime);
            break;
        case ConfigureRequest: {
            XConfigureRequestEvent *request = &event.xconfigurerequest;
            Window parent;
            XWindowAttributes attributes;
            /* A shown main window stays full screen whatever size it asks for. */
            if (XGetWindowAttributes(display, request->window, &attributes) && attributes.map_state == IsViewable &&
                !XGetTransientForHint(display, request->window, &parent))
                break;
            XWindowChanges changes = {
                .x = request->x, .y = request->y, .width = request->width, .height = request->height,
                .border_width = request->border_width, .sibling = request->above,
                .stack_mode = request->detail,
            };
            XConfigureWindow(display, request->window, (unsigned) request->value_mask, &changes);
            break;
        }
        default:
            break;
        }
    }
}
