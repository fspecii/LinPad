#!/usr/bin/env python3
"""Host side of LinPad audio output for tests: what ISHAudioBridge.swift reads.

usage: fake_speaker_host.py FAKEFS_DATA_DIR OUT.wav [--seconds N]

Reads the guest PulseAudio pipe sink's FIFO <root>/tmp/ishaudio/pcm (s16le, 48 kHz,
stereo) and writes everything that arrives to OUT.wav, so check_tone.py can analyse
what Linux apps played.
"""
import argparse
import os
import select
import stat
import time
import wave


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("out")
    parser.add_argument("--seconds", type=float, default=600)
    args = parser.parse_args()
    fifo = os.path.join(args.root, "tmp/ishaudio/pcm")
    end = time.monotonic() + args.seconds
    with wave.open(args.out, "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(48000)
        fd, inode, carry = -1, None, b""
        while time.monotonic() < end:
            try:
                st = os.stat(fifo)
                exists = stat.S_ISFIFO(st.st_mode)
            except FileNotFoundError:
                exists = False
            if fd >= 0 and (not exists or st.st_ino != inode):
                os.close(fd)
                fd = -1
            if fd < 0:
                if not exists:
                    time.sleep(0.2)
                    continue
                fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
                inode = st.st_ino
            if not select.select([fd], [], [], 0.25)[0]:
                continue
            try:
                data = carry + os.read(fd, 65536)
            except BlockingIOError:
                continue
            usable = len(data) - len(data) % 4
            out.writeframes(data[:usable])
            carry = data[usable:]


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
