#include <assert.h>
#include <stdio.h>
#include "app/TerminalKeyboardGeometry.h"

static void expect_padding(TerminalKeyboardGeometry geometry, CGFloat expected) {
    assert(isfinite(geometry.padding));
    assert(fabs(geometry.padding - expected) < 0.001);
}

int main(void) {
    CGRect screen = CGRectMake(0, 0, 1180, 760);
    CGRect keyboard = CGRectMake(0, 420, 1180, 340);
    CGRect liftedTerminal = CGRectMake(0, 0, 1000, 350);
    CGRect liftedLocalKeyboard = CGRectMake(-80, 350, 1180, 340);
    TerminalKeyboardState state = {0};

    // In landscape, desktop avoidance has already moved the terminal's bottom
    // to the keyboard's top. WillChange and repeated DidChange must retain focus.
    // The old controller classified this zero local overlap as accessory-only.
    assert(CGRectIsNull(CGRectIntersection(liftedLocalKeyboard, liftedTerminal)) ||
        CGRectIntersection(liftedLocalKeyboard, liftedTerminal).size.height < 100);
    for (int event = 0; event < 4; event++) {
        TerminalKeyboardGeometry geometry = TerminalKeyboardGeometryForFrames(
            keyboard, screen, liftedLocalKeyboard, liftedTerminal, 0, 43);
        assert(geometry.presence == TerminalKeyboardSoftware);
        expect_padding(geometry, 0);
        assert(!TerminalKeyboardCompletedDismissal(&state, geometry.presence, event != 0));
    }

    // A minimum-height terminal can still overlap 60 points. That is padding,
    // not evidence that the 340-point on-screen keyboard disappeared.
    TerminalKeyboardGeometry partial = TerminalKeyboardGeometryForFrames(
        keyboard, screen, CGRectMake(-80, 290, 1180, 340), liftedTerminal, 0, 43);
    assert(partial.presence == TerminalKeyboardSoftware);
    expect_padding(partial, 60);

    // Stage Manager may place the whole app window above the keyboard as well.
    TerminalKeyboardGeometry aboveApp = TerminalKeyboardGeometryForFrames(
        keyboard, screen, CGRectMake(0, 500, 1180, 340), CGRectMake(0, 0, 900, 400), 0, 43);
    assert(aboveApp.presence == TerminalKeyboardSoftware);
    expect_padding(aboveApp, 0);

    CGRect floating = CGRectMake(700, 430, 400, 280);
    TerminalKeyboardGeometry outsideFloating = TerminalKeyboardGeometryForFrames(
        floating, screen, floating, CGRectMake(0, 0, 500, 400), 0, 43);
    assert(outsideFloating.presence == TerminalKeyboardSoftware);
    expect_padding(outsideFloating, 0);
    expect_padding(TerminalKeyboardGeometryForFrames(floating, screen, floating, screen, 20, 43), 43);

    // Fullscreen docked and full-width undocked/split keyboard behavior remains.
    expect_padding(TerminalKeyboardGeometryForFrames(keyboard, screen, keyboard, screen, 20, 43), 340);
    CGRect split = CGRectMake(0, 320, 1180, 300);
    expect_padding(TerminalKeyboardGeometryForFrames(split, screen, split, screen, 20, 43), 440);

    CGRect accessory = CGRectMake(0, 717, 1180, 43);
    TerminalKeyboardGeometry strip = TerminalKeyboardGeometryForFrames(accessory, screen, accessory, screen, 20, 43);
    assert(strip.presence == TerminalKeyboardAccessoryOnly);
    expect_padding(strip, 43);
    // Only a completed transition from a full keyboard retains the deliberate
    // hide-key action that also dismisses the desktop's extra keys row.
    // WillChange must not remove that row via the external-keyboard style
    // update before the DidChange responder-dismissal check can see it.
    assert(!TerminalKeyboardShouldUpdateExternalState(strip.presence, false));
    assert(!TerminalKeyboardCompletedDismissal(&state, strip.presence, false));
    assert(state.completedPresence == TerminalKeyboardSoftware);
    assert(TerminalKeyboardShouldUpdateExternalState(strip.presence, true));
    assert(TerminalKeyboardCompletedDismissal(&state, strip.presence, true));
    assert(!TerminalKeyboardCompletedDismissal(&state, strip.presence, true));
    TerminalKeyboardState initial = {0};
    assert(!TerminalKeyboardCompletedDismissal(&initial, strip.presence, true));
    assert(TerminalKeyboardShouldUpdateExternalState(TerminalKeyboardSoftware, false));

    CGRect hidden = CGRectMake(0, 760, 1180, 340);
    TerminalKeyboardGeometry offscreen = TerminalKeyboardGeometryForFrames(hidden, screen, hidden, screen, 20, 43);
    assert(offscreen.presence == TerminalKeyboardHidden);
    expect_padding(offscreen, 0);
    TerminalKeyboardState hiding = {TerminalKeyboardSoftware};
    assert(!TerminalKeyboardShouldUpdateExternalState(offscreen.presence, false));
    assert(!TerminalKeyboardCompletedDismissal(&hiding, offscreen.presence, false));
    assert(hiding.completedPresence == TerminalKeyboardSoftware);
    assert(TerminalKeyboardShouldUpdateExternalState(offscreen.presence, true));
    assert(TerminalKeyboardCompletedDismissal(&hiding, offscreen.presence, true));
    assert(hiding.completedPresence == TerminalKeyboardHidden);
    assert(!TerminalKeyboardCompletedDismissal(&hiding, offscreen.presence, true));
    assert(!TerminalKeyboardCompletedDismissal(&hiding, strip.presence, true));

    CGRect invalid[] = {
        CGRectNull, CGRectInfinite, CGRectZero,
        CGRectMake(NAN, 0, 100, 200), CGRectMake(0, INFINITY, 100, 200),
        CGRectMake(0, 0, -100, 200), CGRectMake(0, 0, 100, -200),
        CGRectMake(0, 0, INFINITY, 200),
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        TerminalKeyboardGeometry badScreen = TerminalKeyboardGeometryForFrames(
            invalid[i], screen, keyboard, screen, 20, 43);
        assert(badScreen.presence == TerminalKeyboardUnknown);
        expect_padding(badScreen, 0);
        TerminalKeyboardState visible = {TerminalKeyboardSoftware};
        assert(!TerminalKeyboardShouldUpdateExternalState(badScreen.presence, false));
        assert(!TerminalKeyboardShouldUpdateExternalState(badScreen.presence, true));
        assert(!TerminalKeyboardCompletedDismissal(&visible, badScreen.presence, false));
        assert(!TerminalKeyboardCompletedDismissal(&visible, badScreen.presence, true));
        assert(visible.completedPresence == TerminalKeyboardSoftware);
        TerminalKeyboardGeometry badLocal = TerminalKeyboardGeometryForFrames(
            keyboard, screen, invalid[i], screen, 20, 43);
        assert(badLocal.presence == TerminalKeyboardSoftware);
        expect_padding(badLocal, 0);
        expect_padding(TerminalKeyboardGeometryForFrames(keyboard, screen, keyboard, invalid[i], 20, 43), 0);
        TerminalKeyboardGeometry badBounds = TerminalKeyboardGeometryForFrames(
            keyboard, invalid[i], keyboard, screen, 20, 43);
        assert(badBounds.presence == TerminalKeyboardUnknown);
        expect_padding(badBounds, 0);
        assert(!TerminalKeyboardShouldUpdateExternalState(badBounds.presence, true));
        assert(!TerminalKeyboardCompletedDismissal(&visible, badBounds.presence, true));
        assert(visible.completedPresence == TerminalKeyboardSoftware);
        // Invalid notifications must not prevent the next genuine hide from
        // relinquishing focus, so a later tap can show the keyboard again.
        assert(TerminalKeyboardCompletedDismissal(&visible, offscreen.presence, true));
    }
    // Even malformed optional inset values must never become constraints.
    expect_padding(TerminalKeyboardGeometryForFrames(floating, screen, floating, screen, NAN, INFINITY), 0);
    expect_padding(TerminalKeyboardGeometryForFrames(floating, screen, floating, screen, 900, 1200), 760);

    puts("terminal keyboard geometry: passed");
    return 0;
}
