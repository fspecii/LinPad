#!/usr/bin/env python3
"""Checks that a recording holds the fake mic's sine wave.

usage: check_tone.py FILE.wav EXPECTED_HZ [--min-seconds S]

Finds the dominant frequency of the recording (first channel, after skipping the
first 0.2 s) and fails unless it is within 2 % of EXPECTED_HZ, the signal is not
near-silent, and the file holds at least --min-seconds of audio.
"""
import sys
import wave

import numpy as np


def main():
    path, expected = sys.argv[1], float(sys.argv[2])
    min_seconds = float(sys.argv[sys.argv.index("--min-seconds") + 1]) if "--min-seconds" in sys.argv else 0.5
    with wave.open(path) as w:
        rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        frames = w.readframes(w.getnframes())
    assert width == 2, f"expected 16-bit samples, got {width * 8}-bit"
    samples = np.frombuffer(frames, dtype="<i2").reshape(-1, channels)[:, 0].astype(np.float64)
    seconds = len(samples) / rate
    body = samples[int(rate * 0.2):]
    rms = float(np.sqrt(np.mean(body ** 2))) if len(body) else 0.0
    spectrum = np.abs(np.fft.rfft(body * np.hanning(len(body)))) if len(body) else np.zeros(1)
    peak = float(np.argmax(spectrum[1:]) + 1) * rate / max(len(body), 1)
    ok = seconds >= min_seconds and rms > 500 and abs(peak - expected) <= expected * 0.02
    print(f"{path}: {rate} Hz x{channels}, {seconds:.2f} s, rms {rms:.0f}, peak {peak:.1f} Hz "
          f"(expected {expected:.0f}) {'OK' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
