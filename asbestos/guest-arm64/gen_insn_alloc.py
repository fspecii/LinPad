#!/usr/bin/env python3
"""Allocation tables for the A64 register-only AdvSIMD/FP/crypto classes and the
load/store classes, used by gen.c to decide which encodings exist.

An encoding is allocated if the reference host (Apple M4) executes it: the
'words' corpora below hold, for every class, each combination of the bits that
select the operation (with a few register/immediate fillers), and difffuzz
runs them natively. LLVM's disassembler then says which optional features each
allocated encoding needs (FEAT_FP16, FEAT_DotProd, FEAT_LSE, ...). gen.c runs an
encoding only if it is allocated and the host CPU has every feature it needs and
the emulator implements them; otherwise the guest gets SIGILL, as on hardware
without the feature. The JIT runs register-only SIMD/FP natively, so both engines
then expose the same instruction set.

  gen_insn_alloc.py words > w.txt          register-only and integer corpus (difffuzz)
  gen_insn_alloc.py words-mem > wm.txt     load/store corpus (difffuzz -m)
  gen_insn_alloc.py table native.txt native-mem.txt
      writes insn_alloc.inc and gadgets-aarch64/hostop_tables.inc (needs llvm-mc;
      the native files are difffuzz output for the two corpora on the reference
      Mac; commit the outputs)

LLVM_MC overrides the llvm-mc binary (default: Homebrew LLVM).
"""
import os
import subprocess
import sys
import tempfile

# Feature bits (INSN_FEAT_* in gen.c, same order) and their llvm-mc names.
FEATURES = [
    ("FP16", "fullfp16"),
    ("FHM", "fp16fml"),
    ("DOTPROD", "dotprod"),
    ("RDM", "rdm"),
    ("FCMA", "complxnum"),
    ("JSCVT", "jsconv"),
    ("FRINTTS", "fptoint"),
    ("BF16", "bf16"),
    ("I8MM", "i8mm"),
    ("AES", "aes"),
    ("SHA2", "sha2"),
    ("SHA3", "sha3"),
    ("SM4", "sm4"),
    ("LSE", "lse"),
    ("RCPC", "rcpc"),
    ("RCPC2", "rcpc-immo"),
    ("PAUTH", "pauth"),
    ("LOR", "lor"),
    ("CRC32", "crc"),
    ("FLAGM", "flagm"),
]
BASE_ONLY = 1 << 30   # classify(): allocated in ARMv8.0
UNSUPPORTED = 1 << 29  # classify(): allocated only with features not listed above
M_REGISTER = 1 << 28  # by-element forms whose M bit is Rm<4> rather than an index bit

# (name, mask, value, index fields as (lsb, width) from most to least significant)
# Bits that are neither fixed nor part of the index are register numbers or
# immediates; they are filled from a template when building sample encodings.
# A field (lsb, ONES5) is one index bit: whether the 5-bit field at lsb is 11111
# (the "should be one" Rs/Rt2 fields, which the hardware checks).
ONES5 = 0x85

# Register-only AdvSIMD/FP/crypto classes (gen_simd_fp).
REG_CLASSES = [
    # Advanced SIMD, vector
    ("three_same", 0x9F200400, 0x0E200400, [(30, 1), (29, 1), (22, 2), (11, 5)]),
    ("three_same_fp16", 0x9F60C400, 0x0E400400, [(30, 1), (29, 1), (23, 1), (11, 3)]),
    ("three_same_extra", 0x9F208400, 0x0E008400, [(30, 1), (29, 1), (22, 2), (11, 4)]),
    ("three_diff", 0x9F200C00, 0x0E200000, [(30, 1), (29, 1), (22, 2), (12, 4)]),
    ("misc2", 0x9F3E0C00, 0x0E200800, [(30, 1), (29, 1), (22, 2), (12, 5)]),
    ("misc2_fp16", 0x9F7E0C00, 0x0E780800, [(30, 1), (29, 1), (23, 1), (12, 5)]),
    ("across", 0x9F3E0C00, 0x0E300800, [(30, 1), (29, 1), (22, 2), (12, 5)]),
    ("permute", 0xBF208C00, 0x0E000800, [(30, 1), (22, 2), (12, 3)]),
    ("extract", 0xBF208400, 0x2E000000, [(30, 1), (22, 2), (11, 4)]),
    ("table", 0xBF208C00, 0x0E000000, [(30, 1), (22, 2), (13, 2), (12, 1)]),
    ("copy", 0x9FE08400, 0x0E000400, [(30, 1), (29, 1), (16, 5), (11, 4)]),
    ("modimm", 0x9FF80400, 0x0F000400, [(30, 1), (29, 1), (12, 4), (11, 1)]),
    ("shift_imm", 0x9F800400, 0x0F000400, [(30, 1), (29, 1), (19, 4), (11, 5)]),
    ("elem", 0x9F000400, 0x0F000000, [(30, 1), (29, 1), (22, 2), (21, 1), (20, 1), (12, 4), (11, 1)]),
    # Advanced SIMD, scalar
    ("s_copy", 0xDFE08400, 0x5E000400, [(29, 1), (16, 5), (11, 4)]),
    ("s_three_same_fp16", 0xDF60C400, 0x5E400400, [(29, 1), (23, 1), (11, 3)]),
    ("s_misc2_fp16", 0xDF7E0C00, 0x5E780800, [(29, 1), (23, 1), (12, 5)]),
    ("s_three_same_extra", 0xDF208400, 0x5E008400, [(29, 1), (22, 2), (11, 4)]),
    ("s_misc2", 0xDF3E0C00, 0x5E200800, [(29, 1), (22, 2), (12, 5)]),
    ("s_pairwise", 0xDF3E0C00, 0x5E300800, [(29, 1), (22, 2), (12, 5)]),
    ("s_three_diff", 0xDF200C00, 0x5E200000, [(29, 1), (22, 2), (12, 4)]),
    ("s_three_same", 0xDF200400, 0x5E200400, [(29, 1), (22, 2), (11, 5)]),
    ("s_shift_imm", 0xDF800400, 0x5F000400, [(29, 1), (19, 4), (11, 5)]),
    ("s_elem", 0xDF000400, 0x5F000000, [(29, 1), (22, 2), (21, 1), (20, 1), (12, 4), (11, 1)]),
    # Cryptographic
    ("aes", 0xFF3E0C00, 0x4E280800, [(22, 2), (12, 5)]),
    ("sha3reg", 0xFF208C00, 0x5E000000, [(22, 2), (12, 3)]),
    ("sha2reg", 0xFF3E0C00, 0x5E280800, [(22, 2), (12, 5)]),
    ("crypto3_imm2", 0xFFE0C000, 0xCE408000, [(10, 2)]),
    ("crypto3_sha512", 0xFFE0B000, 0xCE608000, [(14, 1), (10, 2)]),
    ("crypto4", 0xFF808000, 0xCE000000, [(21, 2)]),
    ("xar", 0xFFE00000, 0xCE800000, []),
    ("crypto2_sha512", 0xFFFFF000, 0xCEC08000, [(10, 2)]),
    # Scalar floating point
    ("fp_fixed", 0x5F200000, 0x1E000000, [(31, 1), (29, 1), (22, 2), (19, 2), (16, 3), (15, 1)]),
    ("fp_int", 0x5F20FC00, 0x1E200000, [(31, 1), (29, 1), (22, 2), (19, 2), (16, 3)]),
    ("fp1", 0x5F207C00, 0x1E204000, [(31, 1), (29, 1), (22, 2), (15, 6)]),
    ("fp_cmp", 0x5F203C00, 0x1E202000, [(31, 1), (29, 1), (22, 2), (14, 2), (0, 5)]),
    ("fp_imm", 0x5F201C00, 0x1E201000, [(31, 1), (29, 1), (22, 2), (5, 5)]),
    ("fp_ccmp", 0x5F200C00, 0x1E200400, [(31, 1), (29, 1), (22, 2), (4, 1)]),
    ("fp2", 0x5F200C00, 0x1E200800, [(31, 1), (29, 1), (22, 2), (12, 4)]),
    ("fp_csel", 0x5F200C00, 0x1E200C00, [(31, 1), (29, 1), (22, 2)]),
    ("fp3", 0x5F000000, 0x1F000000, [(31, 1), (29, 1), (22, 2), (21, 1), (15, 1)]),
]


# Load/store classes (gen_ldst). PC-relative literal loads are not included.
MEM_CLASSES = [
    ("ld_excl", 0x3F000000, 0x08000000, [(30, 2), (23, 1), (22, 1), (21, 1), (16, ONES5), (15, 1), (10, ONES5)]),
    ("ld_rcpc_unscaled", 0x3F200C00, 0x19000000, [(30, 2), (22, 2)]),
    ("ld_pair", 0x3A000000, 0x28000000, [(30, 2), (26, 1), (23, 2), (22, 1)]),
    ("ld_imm9", 0x3B200000, 0x38000000, [(30, 2), (26, 1), (22, 2), (10, 2)]),
    ("ld_uimm12", 0x3B000000, 0x39000000, [(30, 2), (26, 1), (22, 2)]),
    ("ld_regoff", 0x3B200C00, 0x38200800, [(30, 2), (26, 1), (22, 2), (13, 3)]),
    ("ld_atomic", 0x3B200C00, 0x38200000, [(30, 2), (26, 1), (23, 1), (22, 1), (16, ONES5), (15, 1), (12, 3)]),
    ("ld_pac", 0x3B200400, 0x38200400, [(30, 2), (26, 1), (23, 1), (22, 1), (11, 1)]),
    ("ld_tags", 0xFF200000, 0xD9200000, [(22, 2), (10, 2)]),
    ("ld_simd_mult", 0xBFBF0000, 0x0C000000, [(30, 1), (22, 1), (12, 4), (10, 2)]),
    ("ld_simd_mult_post", 0xBFA00000, 0x0C800000, [(30, 1), (22, 1), (12, 4), (10, 2)]),
    ("ld_simd_single", 0xBF9F0000, 0x0D000000, [(30, 1), (22, 1), (21, 1), (13, 3), (12, 1), (10, 2)]),
    ("ld_simd_single_post", 0xBF800000, 0x0D800000, [(30, 1), (22, 1), (21, 1), (13, 3), (12, 1), (10, 2)]),
]
# Integer data processing (gen_dp_imm, gen_dp_reg). PC-relative ADR/ADRP are left out.
DP_CLASSES = [
    ("dp_addsub_imm_tags", 0x1FC00000, 0x11800000, [(31, 1), (30, 1), (29, 1), (14, 2)]),
    ("dp_addsub_imm", 0x1F000000, 0x11000000, [(31, 1), (30, 1), (29, 1), (23, 1), (22, 1)]),
    ("dp_logic_imm", 0x1F800000, 0x12000000, [(31, 1), (29, 2), (22, 1), (10, 6)]),
    ("dp_movewide", 0x1F800000, 0x12800000, [(31, 1), (29, 2), (21, 2)]),
    ("dp_bitfield", 0x1F800000, 0x13000000, [(31, 1), (29, 2), (22, 1), (21, 1), (15, 1)]),
    ("dp_extract", 0x1F800000, 0x13800000, [(31, 1), (29, 2), (22, 1), (21, 1), (15, 1)]),
    ("dp_2src", 0x5FE00000, 0x1AC00000, [(31, 1), (29, 1), (10, 6)]),
    ("dp_1src", 0x5FE00000, 0x5AC00000, [(31, 1), (29, 1), (16, 5), (10, 6), (5, ONES5)]),
    ("dp_logic_reg", 0x1F000000, 0x0A000000, [(31, 1), (29, 2), (22, 2), (21, 1), (15, 1)]),
    ("dp_addsub_shift", 0x1F200000, 0x0B000000, [(31, 1), (30, 1), (29, 1), (22, 2), (15, 1)]),
    ("dp_addsub_ext", 0x1F200000, 0x0B200000, [(31, 1), (30, 1), (29, 1), (22, 2), (13, 3), (10, 3)]),
    ("dp_adc_flags", 0x1FE00000, 0x1A000000, [(31, 1), (30, 1), (29, 1), (10, 6), (4, 1)]),
    ("dp_ccmp", 0x1FE00000, 0x1A400000, [(31, 1), (30, 1), (29, 1), (11, 1), (10, 1), (4, 1)]),
    ("dp_csel", 0x1FE00000, 0x1A800000, [(31, 1), (30, 1), (29, 1), (10, 2)]),
    ("dp_3src", 0x1F000000, 0x1B000000, [(31, 1), (29, 2), (21, 3), (15, 1)]),
]
CLASSES = ([(n, m, v, f, "r") for n, m, v, f in REG_CLASSES] + [(n, m, v, f, "m") for n, m, v, f in MEM_CLASSES] +
           [(n, m, v, f, "i") for n, m, v, f in DP_CLASSES])

GADGETS = {
    "v": ("HOSTOP_V", ".Lhostop_done"),            # vector regs in, q0 out
    "nzcv": ("HOSTOP_NZCV", ".Lhostop_nzcv_done"),  # + guest NZCV in (FCSEL)
    "cmp": ("HOSTOP_CMP", ".Lhostop_cmp_done"),     # NZCV in and out, no vector result
    "f2g_nzcv": ("HOSTOP_F2G_NZCV", ".Lhostop_f2g_nzcv_done"),  # Wd/Xd and NZCV out
}
HOSTOPS = [
    ("three_same", 0x9F200400, 0x0E200400, [(30, 1), (29, 1), (22, 2), (11, 5)], "v"),
    ("three_same_fp16", 0x9F60C400, 0x0E400400, [(30, 1), (29, 1), (23, 1), (11, 3)], "v"),
    ("three_same_extra", 0x9F208400, 0x0E008400, [(30, 1), (29, 1), (22, 2), (11, 4)], "v"),
    ("three_diff", 0x9F200C00, 0x0E200000, [(30, 1), (29, 1), (22, 2), (12, 4)], "v"),
    ("misc2", 0x9F3E0C00, 0x0E200800, [(30, 1), (29, 1), (22, 2), (12, 5)], "v"),
    ("misc2_fp16", 0x9F7E0C00, 0x0E780800, [(30, 1), (29, 1), (23, 1), (12, 5)], "v"),
    ("across", 0x9F3E0C00, 0x0E300800, [(30, 1), (29, 1), (22, 2), (12, 5)], "v"),
    ("elem", 0x9F000400, 0x0F000000, [(30, 1), (29, 1), (22, 2), (21, 1), (20, 1), (12, 4), (11, 1)], "v"),
    ("fmov16_imm", 0x9FF8FC00, 0x0F00FC00, [(30, 1), (16, 3), (5, 5)], "v"),
    ("s_misc2", 0xDF3E0C00, 0x5E200800, [(29, 1), (22, 2), (12, 5)], "v"),
    ("s_misc2_fp16", 0xDF7E0C00, 0x5E780800, [(29, 1), (23, 1), (12, 5)], "v"),
    ("s_pairwise", 0xDF3E0C00, 0x5E300800, [(29, 1), (22, 2), (12, 5)], "v"),
    ("s_three_diff", 0xDF200C00, 0x5E200000, [(29, 1), (22, 2), (12, 4)], "v"),
    ("s_three_same", 0xDF200400, 0x5E200400, [(29, 1), (22, 2), (11, 5)], "v"),
    ("s_three_same_fp16", 0xDF60C400, 0x5E400400, [(29, 1), (23, 1), (11, 3)], "v"),
    ("s_three_same_extra", 0xDF208400, 0x5E008400, [(29, 1), (22, 2), (11, 4)], "v"),
    ("s_elem", 0xDF000400, 0x5F000000, [(29, 1), (22, 2), (21, 1), (20, 1), (12, 4), (11, 1)], "v"),
    # scalar shift by immediate, per opcode: index U:immh:immb
    ("s_rshr", 0xDF80FC00, 0x5F002400, [(29, 1), (16, 7)], "v"),
    ("s_qshrun", 0xDF80FC00, 0x5F008400, [(29, 1), (16, 7)], "v"),
    ("s_qrshrun", 0xDF80FC00, 0x5F008C00, [(29, 1), (16, 7)], "v"),
    ("s_qshrn", 0xDF80FC00, 0x5F009400, [(29, 1), (16, 7)], "v"),
    ("s_qrshrn", 0xDF80FC00, 0x5F009C00, [(29, 1), (16, 7)], "v"),
    ("fp1", 0xFF207C00, 0x1E204000, [(22, 2), (15, 6)], "v"),
    ("fp2", 0xFF200C00, 0x1E200800, [(22, 2), (12, 4)], "v"),
    ("fp3", 0xFF000000, 0x1F000000, [(22, 2), (21, 1), (15, 1)], "v"),
    ("fcmp16", 0xFFE03C07, 0x1EE02000, [(14, 2), (3, 2)], "cmp"),
    ("fccmp16", 0xFFE00C00, 0x1EE00400, [(12, 4), (4, 1), (0, 4)], "cmp"),
    ("fcsel16", 0xFFE00C00, 0x1EE00C00, [(12, 4)], "nzcv"),
    ("fjcvtzs", 0xFFFFFC00, 0x1E7E0000, [], "f2g_nzcv"),
    ("crypto4", 0xFF808000, 0xCE000000, [(21, 2)], "v"),
    ("crypto3_sha512", 0xFFE0B000, 0xCE608000, [(14, 1), (10, 2)], "v"),
    ("xar", 0xFFE00000, 0xCE800000, [(10, 6)], "v"),
    ("crypto2_sha512", 0xFFFFF000, 0xCEC08000, [(10, 2)], "v"),
]
HOSTOP_TEMPLATE = (0 << 0) | (1 << 5) | (3 << 10) | (2 << 16)

# Register/immediate fillers: Rd/Rt = bits 4:0, Rn = 9:5, Ra/Rt2 = 14:10, Rm/Rs = 20:16.
# Register 18 is left to the host OS by difffuzz and 31 is SP/ZR, so neither is
# used. Memory forms use distinct registers (base/data overlaps are CONSTRAINED
# UNPREDICTABLE) and even data registers (CASP needs even pairs).
TEMPLATES = [
    (1 << 0) | (2 << 5) | (4 << 10) | (3 << 16),
    (20 << 0) | (17 << 5) | (25 << 10) | (29 << 16),
    (7 << 0) | (7 << 5) | (7 << 10) | (7 << 16),
]
MEM_TEMPLATES = [
    (2 << 0) | (5 << 5) | (4 << 10) | (6 << 16),
    (20 << 0) | (17 << 5) | (24 << 10) | (28 << 16),
]


def templates(kind):
    return MEM_TEMPLATES if kind == "m" else TEMPLATES


def width(w):
    return 1 if w == ONES5 else w


def index_bits(fields):
    return sum(width(w) for _, w in fields)


def encode(cls, idx, template):
    _, mask, value, fields, _ = cls
    word, shift, imask = value, index_bits(fields), 0
    for lsb, w in fields:
        shift -= width(w)
        bits = (idx >> shift) & ((1 << width(w)) - 1)
        if w == ONES5:
            # 11111, or the template's (never 31) register
            word |= (31 if bits else (template >> lsb) & 31) << lsb
            imask |= 31 << lsb
        else:
            word |= bits << lsb
            imask |= ((1 << w) - 1) << lsb
    free = ~(mask | imask) & 0xFFFFFFFF
    return word | (template & free)


def class_of(word):
    for i, (_, mask, value, _, _) in enumerate(CLASSES):
        if word & mask == value:
            return i
    return None


def llvm_valid(words, attrs):
    """{word: disassembly} for the words llvm-mc decodes with the given -mattr string."""
    mc = os.environ.get("LLVM_MC", "/opt/homebrew/opt/llvm/bin/llvm-mc")
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        for w in words:
            f.write(" ".join(f"0x{(w >> (8 * i)) & 0xff:02x}" for i in range(4)) + "\n")
        path = f.name
    r = subprocess.run([mc, "--disassemble", "-triple=aarch64", f"-mattr={attrs}", path],
                       capture_output=True, text=True)
    os.unlink(path)
    bad = set()
    for line in r.stderr.splitlines():
        if "invalid instruction encoding" in line:
            bad.add(int(line.split(":")[1]) - 1)
    text = [l.strip() for l in r.stdout.splitlines() if l.startswith("\t") and not l.strip().startswith(".")]
    good = [w for i, w in enumerate(words) if i not in bad]
    if len(text) != len(good):
        raise SystemExit(f"llvm-mc output out of step ({len(text)} lines for {len(good)} words)")
    return dict(zip(good, text))


BASE = "-all,+v8a,+fp-armv8,+neon"
DISASM = {}


def samples():
    for ci, cls in enumerate(CLASSES):
        for idx in range(1 << index_bits(cls[3])):
            yield ci, idx, [w for w in (encode(cls, idx, t) for t in templates(cls[4])) if class_of(w) == ci]


def classify():
    """{(class index, op index): {feature mask | BASE_ONLY | UNSUPPORTED, 0 = not decoded}
    for each template}"""
    allw = list(samples())
    words = sorted({w for _, _, ws in allw for w in ws})
    base = llvm_valid(words, BASE)
    single = [llvm_valid(words, f"{BASE},+{attr}") for _, attr in FEATURES]
    pairs = {}
    every = llvm_valid(words, "+all")
    DISASM.update(every)

    def features_of(w):
        if w in base:
            return BASE_ONLY
        for i, ok in enumerate(single):
            if w in ok:
                return 1 << i
        if w not in every:
            return 0
        for i in range(len(FEATURES)):
            for j in range(i + 1, len(FEATURES)):
                if (i, j) not in pairs:
                    pairs[(i, j)] = llvm_valid(words, f"{BASE},+{FEATURES[i][1]},+{FEATURES[j][1]}")
                if w in pairs[(i, j)]:
                    return (1 << i) | (1 << j)
        return UNSUPPORTED

    return {(ci, idx): {features_of(w) for w in ws} for ci, idx, ws in allw}


def host_executes(*paths):
    """{word: True if the host CPU decoded it (ran it or took a memory fault)}"""
    ran = {}
    for path in paths:
        for line in open(path):
            w, _, h = line.split()
            ran.setdefault(int(w, 16), h != "ILL")
    return ran


def m_is_register(ci, idx):
    """For the by-element classes: does M (bit 20) select a register (v16-v31)?"""
    name, _, _, fields, _ = CLASSES[ci]
    if name not in ("elem", "s_elem"):
        return False
    shift = index_bits(fields)
    for lsb, w in fields:
        shift -= width(w)
        if lsb == 20:
            mbit = 1 << shift
    w = encode(CLASSES[ci], idx | mbit, TEMPLATES[0])  # Rm field = 3
    return "v19" in DISASM.get(w, "")


def c_fields(fields):
    return ", ".join(f"{{{lsb}, {w}}}" for lsb, w in fields) or "{0, 0}"


def emit_table(native_paths):
    table = classify()
    ran = host_executes(*native_paths)
    combos = []
    problems = []
    arrays = []
    for ci, (name, mask, value, fields, kind) in enumerate(CLASSES):
        vals = []
        for idx in range(1 << index_bits(fields)):
            ws = [w for w in (encode(CLASSES[ci], idx, t) for t in templates(kind)) if class_of(w) == ci]
            runs = {ran[w] for w in ws}
            fs = table[(ci, idx)]
            f = max(fs) if fs else 0
            if not ws or runs == {False}:
                vals.append(0xFF)
                if ws and f not in (0, UNSUPPORTED):
                    print(f"note: {name} {ws[0]:08x}: LLVM decodes it (features {f:#x}), the host does not",
                          file=sys.stderr)
                continue
            if len(runs) != 1 or len(fs) != 1:
                problems.append(f"{name} {ws[0]:08x}: result depends on registers (host {runs}, LLVM {fs})")
                continue
            if f == BASE_ONLY:
                v = 0
            elif f in (0, UNSUPPORTED):
                problems.append(f"{name} {ws[0]:08x}: host runs it, LLVM can't attribute it ({DISASM.get(ws[0])})")
                continue
            else:
                v = f
            if m_is_register(ci, idx):
                v |= M_REGISTER
            if v not in combos:
                combos.append(v)
            vals.append(combos.index(v))
        arrays.append((name, vals))
    if problems:
        raise SystemExit("\n".join(problems))
    if len(combos) >= 0xFF:
        raise SystemExit("too many feature combinations for a uint8_t table")

    out = [
        "// Generated by gen_insn_alloc.py; do not edit. Included by gen.c.",
        "// Per class, one byte per operation index: 0xff = unallocated (the reference",
        "// host, an Apple M4, raises SIGILL), otherwise an index into insn_alloc_combos:",
        "// the INSN_FEAT_* bits the encoding needs (0 = ARMv8.0), plus INSN_M_REGISTER",
        "// for by-element forms whose M bit is Rm<4>.",
        "",
        "static const uint32_t insn_alloc_combos[] = {",
        "    " + ", ".join(f"0x{c:08x}" for c in combos) + ",",
        "};",
        "",
    ]
    for name, vals in arrays:
        out.append(f"static const uint8_t alloc_{name}[{len(vals)}] = {{")
        for i in range(0, len(vals), 24):
            out.append("    " + ", ".join(f"{v}" for v in vals[i:i + 24]) + ",")
        out.append("};")
    for kind, var in (("r", "simd_alloc_classes"), ("m", "ldst_alloc_classes"), ("i", "dp_alloc_classes")):
        out.append("")
        out.append(f"static const struct insn_alloc_class {var}[] = {{")
        for name, mask, value, fields, k in CLASSES:
            if k == kind:
                out.append(f"    {{0x{mask:08x}, 0x{value:08x}, {len(fields)}, {{{c_fields(fields)}}}, alloc_{name}}},")
        out.append("};")
    out.append("")
    for name, *_ in HOSTOPS:
        out.append(f"extern const uint64_t hostop_g_{name}[];")
    out.append("static const struct simd_hostop_table simd_hostops[] = {")
    for name, mask, value, fields, gadget in HOSTOPS:
        out.append(f"    {{0x{mask:08x}, 0x{value:08x}, {GADGETS[gadget][0]}, {len(fields)}, {{{c_fields(fields)}}}, "
                   f"hostop_g_{name}}},")
    out.append("};")
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "insn_alloc.inc"), "w") as f:
        f.write("\n".join(out) + "\n")

    asm = [
        "// Generated by gen_insn_alloc.py; do not edit. Included at the end of math.S:",
        "// generic hostop tables, one entry (instruction, branch back) per index.",
    ]
    for name, mask, value, fields, gadget in HOSTOPS:
        asm += ["", "    .p2align 3", f"    .global NAME(hostop_g_{name})", f"NAME(hostop_g_{name}):"]
        for idx in range(1 << index_bits(fields)):
            w = encode((name, mask, value, fields, "r"), idx, HOSTOP_TEMPLATE)
            asm += [f"    .inst 0x{w:08x}", f"    b {GADGETS[gadget][1]}"]
    with open(os.path.join(here, "gadgets-aarch64", "hostop_tables.inc"), "w") as f:
        f.write("\n".join(asm) + "\n")


def emit_words(kinds):
    for name, mask, value, fields, k in CLASSES:
        if k in kinds:
            for idx in range(1 << index_bits(fields)):
                for t in templates(k):
                    print(f"{encode((name, mask, value, fields, k), idx, t):08x}")


if __name__ == "__main__":
    if len(sys.argv) > 3 and sys.argv[1] == "table":
        emit_table(sys.argv[2:4])
    elif len(sys.argv) > 1 and sys.argv[1] in ("words", "words-mem"):
        emit_words("ri" if sys.argv[1] == "words" else "m")
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
