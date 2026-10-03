#!/bin/sh
# Guest half of the microphone test (run.sh starts fake_mic_host.py on the host).
# Records the iPad source three ways and leaves the files in /tmp/av for check_tone.py.
export PULSE_SERVER=unix:/tmp/ishaudio/native
[ -r /usr/local/lib/libishaudio-compat.so ] && export LD_PRELOAD=/usr/local/lib/libishaudio-compat.so
mkdir -p /tmp/av && cd /tmp/av && rm -f mic-*.wav
ishaudio-session
for i in $(seq 1 50); do pactl info >/dev/null 2>&1 && break; sleep 0.2; done
echo "@@ default source: $(pactl get-default-source)"
pactl list sources short
ls -l /tmp/ishaudio/

t0=$(date +%s%N 2>/dev/null || date +%s)
( sleep 2; pactl list source-outputs | grep -E "Latency|Sample Spec" ) &
timeout 4 parecord --device=ipad_mic --rate=48000 --channels=1 --format=s16le --file-format=wav mic-parecord.wav
echo "@@ parecord rc=$?"
sleep 1
timeout 4 arecord -q -f S16_LE -r 44100 -c 2 -d 3 mic-arecord.wav
echo "@@ arecord rc=$?"
sleep 1
timeout 20 ffmpeg -nostdin -hide_banner -loglevel error -f pulse -i ipad_mic -t 3 -y mic-ffmpeg.wav
echo "@@ ffmpeg rc=$?"
sleep 3
ls -l /tmp/av/mic-*.wav
tail -5 /tmp/ishaudio/pulse.log
