#!/usr/bin/env python3
"""Host side of the LinPad microphone protocol with a sine wave instead of the mic.

usage: fake_mic_host.py FAKEFS_DATA_DIR [--freq HZ] [--log FILE]

Same protocol as app/Desktop/ISHMicBridge.swift:
  * The guest's PulseAudio (module-pipe-source) creates the FIFO
    <root>/tmp/ishaudio/mic and reads it only while a client records.
  * The host opens the FIFO twice: read-only (only for FIONREAD and draining;
    Darwin reports 0 for FIONREAD on an O_RDWR or write-only FIFO fd) and write-only.
  * Idle: the host keeps one 10 ms probe chunk of silence in the FIFO. When the
    FIFO is empty (FIONREAD == 0) a reader is running: start "capturing".
  * Capturing: write s16le mono 48 kHz in 10 ms chunks at real time. When more than
    BACKLOG_STOP of audio has stayed unread for BACKLOG_GRACE, the reader stopped:
    drain the FIFO, stop, and go back to idle.
"""
import argparse
import array
import fcntl
import math
import os
import stat
import struct
import sys
import termios
import time

RATE = 48000
CHUNK_FRAMES = RATE // 100
BYTES_PER_FRAME = 2
# A Darwin pipe holds 8 KB (~85 ms of s16 mono), so the threshold stays below that;
# the grace period rides out an emulated guest that is briefly too busy to read.
BACKLOG_STOP = 0.05
BACKLOG_GRACE = 1.0


def fionread(fd):
    buf = fcntl.ioctl(fd, termios.FIONREAD, b"\0\0\0\0")
    return struct.unpack("i", buf)[0]


def drain(fd):
    while True:
        try:
            if not os.read(fd, 65536):
                return
        except BlockingIOError:
            return


def write_some(fd, data):
    try:
        return os.write(fd, data)
    except BlockingIOError:
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--freq", type=float, default=1000.0)
    parser.add_argument("--log", default=None)
    args = parser.parse_args()
    fifo = os.path.join(args.root, "tmp/ishaudio/mic")
    log = open(args.log, "a", buffering=1) if args.log else sys.stderr

    def say(msg):
        log.write(f"{time.monotonic():.3f} {msg}\n")

    fd, rfd, inode = -1, -1, None
    capturing = False
    phase = 0
    next_time = 0.0
    backlog_since = None
    carry = b""
    silence = bytes(CHUNK_FRAMES * BYTES_PER_FRAME)
    while True:
        try:
            st = os.stat(fifo)
            exists = stat.S_ISFIFO(st.st_mode)
        except FileNotFoundError:
            exists = False
        if fd >= 0 and (not exists or st.st_ino != inode):
            os.close(fd)
            os.close(rfd)
            fd, capturing = -1, False
            say("fifo gone")
        if fd < 0:
            if not exists:
                time.sleep(0.2)
                continue
            rfd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
            fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
            inode = st.st_ino
            say("connected")
            write_some(fd, silence)

        pending = fionread(rfd)
        if not capturing:
            if pending == 0:
                capturing = True
                next_time = time.monotonic()
                backlog_since = None
                say("reader active: start")
                stats, stats_time = [], time.monotonic()
            else:
                time.sleep(0.05)
                continue

        stats.append(pending)
        if time.monotonic() - stats_time >= 1:
            ms = [p * 1000 / (RATE * BYTES_PER_FRAME) for p in stats]
            say(f"fifo backlog ms: avg {sum(ms) / len(ms):.1f} max {max(ms):.1f}")
            stats, stats_time = [], time.monotonic()

        if pending > BACKLOG_STOP * RATE * BYTES_PER_FRAME:
            backlog_since = backlog_since or time.monotonic()
            if time.monotonic() - backlog_since > BACKLOG_GRACE:
                drain(rfd)
                capturing = False
                say("reader stopped: stop")
                write_some(fd, silence)
                continue
        else:
            backlog_since = None

        samples = array.array("h", (
            int(12000 * math.sin(2 * math.pi * args.freq * (phase + i) / RATE))
            for i in range(CHUNK_FRAMES)))
        phase = (phase + CHUNK_FRAMES) % RATE
        # A full pipe drops the rest of the chunk, but a frame already half written
        # is finished next time so the stream stays sample-aligned.
        out = carry + samples.tobytes()
        written = write_some(fd, out)
        carry = out[written:written + (-written) % BYTES_PER_FRAME]
        next_time += CHUNK_FRAMES / RATE
        delay = next_time - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            next_time = time.monotonic()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
