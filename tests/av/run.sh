#!/bin/sh
# Camera and microphone bridge tests with fake sources, on the Mac CLI emulator.
#   ISH=build/ish FAKEFS=/path/to/fakefs tests/av/run.sh [camera] [mic] [firefox]
# With no arguments all three run. The fakefs needs ffmpeg, v4l-utils (v4l2-ctl,
# v4l2-compliance), pulseaudio + pulseaudio-utils + alsa-plugins-pulse with the ishaudio
# files from themes/guest/audio, and firefox-esr for the getUserMedia test. The host
# needs python3 with Pillow and numpy.
#   camera:  ISH_FAKECAM=1 test pattern -> v4l2-ctl --stream-mmap, v4l2-compliance -s,
#            ffmpeg -f v4l2 PNGs (YUYV, NV12, scaled, front camera, portrait-cropped)
#            compared with the pattern; ISH_FAKECAM=stall gives black frames
#   mic:     fake_mic_host.py sine -> ipad_mic; parecord, arecord and ffmpeg -f pulse
#            recordings checked for the frequency
#   firefox: getUserMedia (camera + microphone) and two Web Audio contexts in a row
#            (fake_speaker_host.py reads the speaker FIFO) in headless Firefox, with
#            its default sandboxed cubeb
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ISH=${ISH:?set ISH to the ish binary}
FAKEFS=${FAKEFS:?set FAKEFS to the guest fakefs directory}
TESTS=${*:-camera mic firefox}
DATA=$FAKEFS/data
failed=0

guest() { "$ISH" -f "$FAKEFS" /bin/sh -c "$1"; }
check() { # description, command...
    desc=$1
    shift
    if "$@"; then echo "PASS $desc"; else echo "FAIL $desc"; failed=1; fi
}

install_audio_config() {
    guest 'mkdir -p /etc/ishaudio && cat > /etc/ishaudio/ishaudio.pa' < "$HERE/../../themes/guest/audio/ishaudio.pa"
    guest 'cat > /usr/local/bin/ishaudio-session && chmod 755 /usr/local/bin/ishaudio-session' \
        < "$HERE/../../themes/guest/audio/ishaudio-session"
}

camera() {
    export ISH_FAKECAM=1
    out=$(guest 'v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=30 --stream-to=/tmp/av-v.raw 2>&1 >/dev/null;
        wc -c < /tmp/av-v.raw; rm -f /tmp/av-v.raw')
    check "v4l2-ctl --stream-mmap --stream-count=30 (30 x 614400 bytes)" [ "$(echo "$out" | tail -1)" = 18432000 ]
    for dev in 0 1; do
        total=$(guest "v4l2-compliance -d /dev/video$dev -s 10 2>&1 | grep '^Total'")
        echo "     $total"
        check "v4l2-compliance /dev/video$dev" sh -c "echo '$total' | grep -q 'Failed: 0'"
    done
    guest 'mkdir -p /tmp/av && cd /tmp/av && rm -f cam-*.png
        f() { out=$1; shift; ffmpeg -nostdin -hide_banner -loglevel error -f v4l2 "$@" -frames 1 -update 1 -y "$out"; }
        f cam-yuyv-640.png -i /dev/video0
        f cam-nv12-1280.png -input_format nv12 -video_size 1280x720 -i /dev/video0
        f cam-yuyv-320.png -video_size 320x240 -i /dev/video0
        f cam-back.png -i /dev/video1'
    for png in cam-yuyv-640 cam-nv12-1280 cam-yuyv-320; do
        check "ffmpeg -f v4l2 $png matches the pattern" python3 "$HERE/check_pattern.py" "$DATA/tmp/av/$png.png"
    done
    check "ffmpeg -f v4l2 /dev/video1 matches the mirrored pattern" \
        python3 "$HERE/check_pattern.py" "$DATA/tmp/av/cam-back.png" --mirrored
    names=$(guest 'for d in 0 1; do v4l2-ctl -d /dev/video$d -D | sed -n "s/.*Card type *: //p"; done' | tr '\n' '|')
    check "/dev/video0 is the front camera, /dev/video1 the back one ($names)" \
        [ "$names" = "Test Pattern (Front)|Test Pattern (Back)|" ]
    ISH_FAKECAM_SIZE=480x640 guest 'cd /tmp/av && ffmpeg -nostdin -hide_banner -loglevel error -f v4l2 -i /dev/video0 -frames 1 -update 1 -y cam-portrait.png'
    check "portrait host frames are cropped to 640x480" \
        python3 "$HERE/check_pattern.py" "$DATA/tmp/av/cam-portrait.png"
    # A camera that never delivers (taken by another app): black frames, no stall.
    out=$(ISH_FAKECAM=stall guest 'cd /tmp/av && timeout 20 v4l2-ctl -d0 --stream-mmap --stream-count=20 --stream-to=stall.raw >/dev/null 2>&1;
        wc -c < stall.raw; ffmpeg -nostdin -hide_banner -loglevel error -f v4l2 -i /dev/video0 -frames 1 -update 1 -y cam-stall.png')
    check "a stalled camera streams black frames (20 x 614400 bytes)" [ "$(echo "$out" | tail -1)" = 12288000 ]
    check "a stalled camera's frame is black" python3 -c "
from PIL import Image
import sys
sys.exit(0 if Image.open('$DATA/tmp/av/cam-stall.png').convert('L').getextrema()[1] < 8 else 1)"
    unset ISH_FAKECAM
}

with_fake_mic() { # freq, guest script
    log=$(mktemp)
    python3 "$HERE/fake_mic_host.py" "$DATA" --freq "$1" --log "$log" &
    host=$!
    guest "$2"
    kill $host 2>/dev/null
    wait $host 2>/dev/null
    echo "     fake mic host:"
    sed 's/^/       /' "$log"
    rm -f "$log"
}

mic() {
    install_audio_config
    with_fake_mic 1000 "$(cat "$HERE/mic-guest.sh")" | grep -v 'SO_PRIORITY\|personality'
    for wav in parecord arecord ffmpeg; do
        check "$wav records the 1 kHz fake microphone" python3 "$HERE/check_tone.py" "$DATA/tmp/av/mic-$wav.wav" 1000
    done
}

firefox() {
    # Firefox's default audio path: cubeb in the parent, reached from the content
    # process over AudioIPC (media.cubeb.sandbox=true).
    install_audio_config
    guest 'mkdir -p /tmp/av && cat > /tmp/av/gum.html' < "$HERE/gum.html"
    guest 'cat > /tmp/av/webaudio.html' < "$HERE/webaudio.html"
    result=$(ISH_FAKECAM=1 with_fake_mic 440 "$(cat "$HERE/gum-guest.sh")" 2>&1)
    echo "$result" | grep '^GUM'
    check "Firefox getUserMedia picks the front camera by default" sh -c "echo '$result' | grep -q 'GUM tracks.*video:Test Pattern (Front)'"
    check "Firefox getUserMedia video shows the pattern" sh -c "echo '$result' | grep -q 'GUM video 640x480 bars \[\[2[45][0-9],2[45][0-9],2[45][0-9]\]'"
    freq=$(echo "$result" | sed -n 's/.*zero-crossing frequency \([0-9.]*\) Hz.*/\1/p')
    check "Firefox getUserMedia audio is the 440 Hz fake microphone (got ${freq:-none})" \
        python3 -c "import sys; sys.exit(0 if 420 <= float('${freq:-0}') <= 460 else 1)"

    wav=$(mktemp -t av-speaker)
    python3 "$HERE/fake_speaker_host.py" "$DATA" "$wav" &
    speaker=$!
    result=$(guest "export GUM_PAGE=webaudio.html; $(cat "$HERE/gum-guest.sh")" 2>&1)
    kill $speaker 2>/dev/null
    wait $speaker 2>/dev/null
    echo "$result" | grep '^WEBAUDIO'
    check "Firefox Web Audio: a second AudioContext starts after the first is closed" \
        sh -c "echo '$result' | grep -q 'WEBAUDIO DONE'"
    check "Firefox Web Audio reaches the iPad speaker FIFO (660 Hz then 880 Hz)" \
        python3 "$HERE/check_tone.py" "$wav" 660,880
    rm -f "$wav"
}

for t in $TESTS; do
    echo "== $t"
    $t
done
[ $failed = 0 ] && echo "av tests: all passed" || echo "av tests: FAILED"
exit $failed
