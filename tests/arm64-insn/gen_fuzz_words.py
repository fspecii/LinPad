#!/usr/bin/env python3
"""Deterministic smoke corpus for difffuzz.c: random register-only AdvSIMD/FP
encodings drawn from fixed instruction classes (no loads, stores or branches).
Unallocated encodings are kept on purpose: the guest must raise SIGILL exactly
where the host CPU does. Encodings with a register field of 18 are dropped
because difffuzz leaves x18 to the host OS.
    python3 gen_fuzz_words.py [per_class] [seed] [focus] > words.txt
focus is "default" (the smoke corpus) or one of the extra sets below; "mem" words
must be run with difffuzz -m. The exhaustive per-opcode corpus for the AdvSIMD/FP
classes is asbestos/guest-arm64/gen_simd_alloc.py words."""
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


# Extra focus sets. FP16 forms fix the type/size bits to half precision.
FOCUS = {
    "fp16": [
        ("simd-three-same-fp16", 0x9F60C400, 0x0E400400, None),
        ("simd-two-reg-misc-fp16", 0x9F7E0C00, 0x0E780800, None),
        ("simd-scalar-three-same-fp16", 0xDF60C400, 0x5E400400, None),
        ("simd-scalar-two-reg-misc-fp16", 0xDF7E0C00, 0x5E780800, None),
        ("simd-elem-fp16", 0x9FC00400, 0x0F000000, None),
        ("fp-1-source-h", 0xFFE07C00, 0x1EE04000, None),
        ("fp-2-source-h", 0xFFE00C00, 0x1EE00800, None),
        ("fp-3-source-h", 0xFFC00000, 0x1FC00000, None),
        ("fp-compare-h", 0xFFE03C00, 0x1EE02000, None),
        ("fp-cond-compare-h", 0xFFE00C00, 0x1EE00400, None),
        ("fp-cond-select-h", 0xFFE00C00, 0x1EE00C00, None),
        ("fp-int-h", 0x7FE0FC00, 0x1EE00000, None),
        ("fp-fixed-h", 0x7FE00000, 0x1EC00000, None),
        ("fp-imm-h", 0xFFE01C00, 0x1EE01000, None),
    ],
    "across": [
        ("simd-across-lanes", 0x9F3E0C00, 0x0E300800, None),
        ("simd-scalar-pairwise", 0xDF3E0C00, 0x5E300800, None),
        ("simd-three-same-pairwise", 0x9F20E400, 0x0E20A400, None),
    ],
    "fcvt": [
        ("fp-int", 0x5F20FC00, 0x1E200000, None),
        ("fp-fixed", 0x5F200000, 0x1E000000, None),
        ("fp-1-source", 0x5F207C00, 0x1E204000, None),
        ("simd-two-reg-misc-fp", 0x9F3C0C00, 0x0E3C0800, None),
        ("simd-two-reg-misc-cvt", 0x9F3E8C00, 0x0E200800, lambda w: (w >> 12) & 0x1f >= 0x16),
        ("simd-scalar-two-reg-misc", 0xDF3E0C00, 0x5E200800, None),
        ("simd-shift-imm-cvt", 0x9F80E400, 0x0F00E400, lambda w: (w >> 19) & 0xF != 0),
        ("simd-scalar-shift-imm", 0xDF800400, 0x5F000400, None),
    ],
    "crypto": [
        ("crypto-aes", 0xFF3E0C00, 0x4E280800, None),
        ("crypto-sha-3reg", 0xFF208C00, 0x5E000000, None),
        ("crypto-sha-2reg", 0xFF3E0C00, 0x5E280800, None),
        ("crypto-3reg-imm2", 0xFFE0C000, 0xCE408000, None),
        ("crypto-3reg-sha512", 0xFFE0B000, 0xCE608000, None),
        ("crypto-4reg", 0xFF808000, 0xCE000000, None),
        ("crypto-xar", 0xFFE00000, 0xCE800000, None),
        ("crypto-2reg-sha512", 0xFFFFF000, 0xCEC08000, None),
        ("simd-pmull", 0xBF20FC00, 0x0E20E000, None),
    ],
    "simd-other": [
        ("simd-three-same-extra", 0x9F208400, 0x0E008400, None),
        ("simd-scalar-three-same-extra", 0xDF208400, 0x5E008400, None),
        ("simd-elem", 0x9F000400, 0x0F000000, None),
        ("simd-scalar-elem", 0xDF000400, 0x5F000000, None),
        ("simd-copy", 0x9FE08400, 0x0E000400, None),
        ("simd-scalar-copy", 0xDFE08400, 0x5E000400, None),
        ("simd-permute", 0xBF208C00, 0x0E000800, None),
        ("simd-extract", 0xBF208400, 0x2E000000, None),
        ("simd-table", 0xBF208C00, 0x0E000000, None),
        ("simd-modified-imm", 0x9FF80400, 0x0F000400, None),
        ("simd-scalar-three-diff", 0xDF200C00, 0x5E200000, None),
        ("simd-scalar-two-reg-misc", 0xDF3E0C00, 0x5E200800, None),
        ("fp-compare", 0x5F203C00, 0x1E202000, None),
        ("fp-cond-compare", 0x5F200C00, 0x1E200400, None),
        ("fp-cond-select", 0x5F200C00, 0x1E200C00, None),
        ("fp-imm", 0x5F201C00, 0x1E201000, None),
    ],
    # Run with difffuzz -m. Rn (bits 9:5) is the base; SP-based and the
    # CONSTRAINED UNPREDICTABLE register overlaps (writeback base = Rt/Rt2,
    # exclusive status = Rt/Rt2/Rn) are left out.
    "mem": [
        ("ldst-exclusive-ordered", 0x3F000000, 0x08000000, None),
        ("ldst-rcpc-unscaled", 0x3F200C00, 0x19000000, None),
        ("ldst-pair", 0x38000000, 0x28000000, None),
        ("ldst-imm9", 0x3B200000, 0x38000000, None),
        ("ldst-uimm12", 0x3B000000, 0x39000000, None),
        ("ldst-regoffset", 0x3B200C00, 0x38200800, None),
        ("ldst-atomic", 0x3B200C00, 0x38200000, None),
        ("ldst-pac", 0x3B200400, 0x38200400, None),
        ("simd-ldst-multiple", 0xBFBF0000, 0x0C000000, None),
        ("simd-ldst-multiple-post", 0xBFA00000, 0x0C800000, None),
        ("simd-ldst-single", 0xBF9F0000, 0x0D000000, None),
        ("simd-ldst-single-post", 0xBF800000, 0x0D800000, None),
    ],
    # Must all raise SIGILL: SVE and SME are not implemented (not advertised).
    "sve": [
        ("sve", 0x1E000000, 0x04000000, None),
        ("sme", 0x9E000000, 0x80000000, None),
    ],
}


def mem_ok(w):
    rt, rn, rt2, rs = w & 31, (w >> 5) & 31, (w >> 10) & 31, (w >> 16) & 31
    if rn == 31:
        return False
    if rt == rn or rt2 == rn:   # writeback base overlap
        return False
    if (w & 0x3F000000) == 0x08000000 and rs in (rt, rt2, rn):  # STXR status overlap
        return False
    if (w & 0xBF000000) in (0x0C000000, 0x0D000000):  # SIMD structure ops: Rm = base
        return ((w >> 16) & 31) != rn
    return True


def touches_x18(w):
    return any((w >> shift) & 0x1F == 18 for shift in (0, 5, 10, 16))


def main():
    per_class = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 20261003)
    focus = sys.argv[3] if len(sys.argv) > 3 else "default"
    classes = CLASSES if focus == "default" else FOCUS[focus]
    if focus == "mem":
        classes = [(n, m, v, lambda w, p=p: mem_ok(w) and (p is None or p(w))) for n, m, v, p in classes]
    for _, mask, value, pred in classes:
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
