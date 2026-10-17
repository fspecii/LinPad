// Keyboard visibility belongs to the screen; terminal padding belongs to the view.
#ifndef TERMINAL_KEYBOARD_GEOMETRY_H
#define TERMINAL_KEYBOARD_GEOMETRY_H

#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>

typedef enum {
    TerminalKeyboardUnknown,
    TerminalKeyboardHidden,
    TerminalKeyboardAccessoryOnly,
    TerminalKeyboardSoftware,
} TerminalKeyboardPresence;

typedef struct {
    TerminalKeyboardPresence presence;
    CGFloat padding;
} TerminalKeyboardGeometry;

typedef struct {
    TerminalKeyboardPresence completedPresence;
} TerminalKeyboardState;

static inline bool TerminalKeyboardHasFiniteArea(CGRect rect) {
    return !CGRectIsNull(rect) && !CGRectIsInfinite(rect) &&
        isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height) &&
        rect.size.width > 0 && rect.size.height > 0 &&
        isfinite(CGRectGetMaxX(rect)) && isfinite(CGRectGetMaxY(rect));
}

static inline TerminalKeyboardGeometry TerminalKeyboardGeometryForFrames(
    CGRect screenKeyboardFrame, CGRect screenBounds,
    CGRect localKeyboardFrame, CGRect viewBounds,
    CGFloat safeAreaBottom, CGFloat accessoryHeight) {
    TerminalKeyboardGeometry result = {TerminalKeyboardUnknown, 0};
    if (!TerminalKeyboardHasFiniteArea(screenKeyboardFrame) ||
        !TerminalKeyboardHasFiniteArea(screenBounds))
        return result;

    CGRect visibleKeyboard = CGRectIntersection(screenKeyboardFrame, screenBounds);
    if (!TerminalKeyboardHasFiniteArea(visibleKeyboard)) {
        result.presence = TerminalKeyboardHidden;
        return result;
    }
    // Retain the existing accessory-strip threshold, but never classify a
    // keyboard using an embedded terminal that desktop avoidance has moved.
    result.presence = visibleKeyboard.size.height < 100
        ? TerminalKeyboardAccessoryOnly : TerminalKeyboardSoftware;

    if (!TerminalKeyboardHasFiniteArea(localKeyboardFrame) ||
        !TerminalKeyboardHasFiniteArea(viewBounds))
        return result;
    CGRect overlap = CGRectIntersection(localKeyboardFrame, viewBounds);
    if (!TerminalKeyboardHasFiniteArea(overlap))
        return result;

    CGFloat padding = CGRectGetMaxY(viewBounds) - CGRectGetMinY(overlap);
    bool undocked = fabs(padding - overlap.size.height) > 0.5;
    bool fullWidth = fabs(visibleKeyboard.size.width - screenBounds.size.width) <= 0.5;
    // A full-width undocked keyboard may be split. Keep its bottom padding;
    // a floating keyboard only needs the accessory/safe-area reservation.
    if (undocked && !fullWidth) {
        CGFloat safeArea = isfinite(safeAreaBottom) ? fmax(safeAreaBottom, 0) : 0;
        CGFloat accessory = isfinite(accessoryHeight) ? fmax(accessoryHeight, 0) : 0;
        padding = fmax(safeArea, accessory);
    }
    result.padding = fmin(fmax(padding, 0), viewBounds.size.height);
    return result;
}

static inline bool TerminalKeyboardCompletedDismissal(
    TerminalKeyboardState *state, TerminalKeyboardPresence presence,
    bool completedFrameChange) {
    if (!completedFrameChange || presence == TerminalKeyboardUnknown)
        return false;
    bool dismissed = state->completedPresence == TerminalKeyboardSoftware &&
        (presence == TerminalKeyboardAccessoryOnly || presence == TerminalKeyboardHidden);
    state->completedPresence = presence;
    return dismissed;
}

static inline bool TerminalKeyboardShouldUpdateExternalState(
    TerminalKeyboardPresence presence, bool completedFrameChange) {
    // Keep the input accessory attached until a hide transition completes.
    return presence != TerminalKeyboardUnknown &&
        (presence == TerminalKeyboardSoftware || completedFrameChange);
}

#endif
