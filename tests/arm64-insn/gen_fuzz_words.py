#!/usr/bin/env python3
"""Deterministic smoke corpus for difffuzz.c: random register-only AdvSIMD/FP
encodings drawn from fixed instruction classes (no loads, stores or branches).
Unallocated encodings are kept on purpose: the guest must raise SIGILL exactly
where the host CPU does. Encodings with a register field of 18 are dropped
because difffuzz leaves x18 to the host OS.
    python3 gen_fuzz_words.py [per_class] [seed] > words.txt"""
import random
import sys

# (name, fixed-bit mask, fixed-bit value, extra predicate)
CLASSES = [
    ("simd-three-same", 0x9F200400, 0x0E200400, None),
    ("simd-three-diff", 0x9F200C00, 0x0E200000, None),
    ("simd-two-reg-misc", 0x9F3E0C00, 0x0E200800, None),
    ("simd-across-lanes", 0x9F3E0C00, 0x0E300800, None),
    ("simd-shift-imm", 0x9F800400, 0x0F000400, lambda w: (w >> 19) & 0xF != 0),
    ("simd-scalar-three-same", 0xDF200400, 0x5E200400, None),
    ("fp-1-source", 0xFF207C00, 0x1E204000, None),
    ("fp-2-source", 0xFF200C00, 0x1E200800, None),
    ("fp-3-source", 0xFF000000, 0x1F000000, None),
]


def touches_x18(w):
    return any((w >> shift) & 0x1F == 18 for shift in (0, 5, 10, 16))


def main():
    per_class = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 20261003)
    for _, mask, value, pred in CLASSES:
        seen = set()
        while len(seen) < per_class:
            w = (rng.getrandbits(32) & ~mask) | value
            if touches_x18(w) or (pred and not pred(w)):
                continue
            seen.add(w)
        for w in sorted(seen):
            print(f"{w:08x}")


if __name__ == "__main__":
    main()
