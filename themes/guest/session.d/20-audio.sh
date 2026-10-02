# Sourced by ishwl-session: starts PulseAudio (ishaudio) and points every app at it.
# libishaudio-compat is preloaded session-wide because every libpulse client (VLC,
# Firefox, GStreamer apps) needs it under iSH; see themes/guest/audio/ishaudio-compat.c.
if command -v ishaudio-session >/dev/null 2>&1; then
    export PULSE_SERVER=unix:/tmp/ishaudio/native
    if [ -r /usr/local/lib/libishaudio-compat.so ]; then
        export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}/usr/local/lib/libishaudio-compat.so"
    fi
    ishaudio-session >/dev/null 2>&1 </dev/null || true
fi
