#!/usr/bin/env python3
"""Allocation table for the register-only AdvSIMD/FP encoding classes.

For every class below, each combination of the bits that select the operation
(everything except register numbers and immediates that never affect
decoding) is classified with LLVM's disassembler: unallocated, base ARMv8.0,
or the set of optional features it needs (FEAT_FP16, FEAT_DotProd, ...).
gen.c consults the generated table before decoding any of these classes, so
an encoding is executed only if it is allocated and every feature it needs is
present on the host CPU (asbestos_host_features()); otherwise the guest gets
SIGILL, as it would on hardware without that feature.

  gen_simd_alloc.py table native.txt   writes simd_alloc.inc and
      gadgets-aarch64/hostop_tables.inc (needs llvm-mc and native.txt, a difffuzz
      run of the 'words' corpus on the reference Mac; commit the outputs)
  gen_simd_alloc.py words [templates] > w.txt  exhaustive difffuzz corpus

LLVM_MC overrides the llvm-mc binary (default: Homebrew LLVM).
"""
import os
import subprocess
import sys
import tempfile

# Feature bits, shared with asbestos_host_features() in gen.c.
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
]
BASE_ONLY = 1 << 30   # classify(): allocated in ARMv8.0
UNSUPPORTED = 1 << 29  # classify(): allocated only with features not listed above

# (name, mask, value, index fields as (lsb, width) from most to least significant)
# Bits that are neither fixed nor part of the index are register numbers or
# immediates; they are filled from a template when building sample encodings.
CLASSES = [
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

# Generic hostop tables: encodings that gen.c has no dedicated gadget for are run
# on the host from these tables (see gadget_hostop in math.S). Each entry is the
# operation with Rd=0, Rn=1, Rm=2, Ra=3; the gadget maps guest registers onto them.
# (name, mask, value, index fields, gadget). A table covers insn & mask == value.
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


# Register/immediate fillers: Rd=bits 4:0, Rn=9:5, Ra=14:10, Rm=20:16. Register 18
# is left to the host OS by difffuzz and 31 is SP/ZR for GPR forms, so neither is used.
TEMPLATES = [
    (1 << 0) | (2 << 5) | (4 << 10) | (3 << 16),
    (20 << 0) | (17 << 5) | (25 << 10) | (29 << 16),
    (7 << 0) | (7 << 5) | (7 << 10) | (7 << 16),
]


def index_bits(fields):
    return sum(w for _, w in fields)


def encode(cls, idx, template):
    _, mask, value, fields = cls
    word, shift = value, index_bits(fields)
    imask = 0
    for lsb, width in fields:
        shift -= width
        word |= ((idx >> shift) & ((1 << width) - 1)) << lsb
        imask |= ((1 << width) - 1) << lsb
    free = ~(mask | imask) & 0xFFFFFFFF
    return word | (template & free)


def class_of(word):
    for i, (_, mask, value, _) in enumerate(CLASSES):
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


def classify():
    """{(class index, op index): feature mask, 0 = unallocated}"""
    samples = []
    for ci, cls in enumerate(CLASSES):
        for idx in range(1 << index_bits(cls[3])):
            samples.append((ci, idx, [encode(cls, idx, t) for t in TEMPLATES]))
    words = sorted({w for _, _, ws in samples for w in ws})
    base = llvm_valid(words, BASE)
    single = [llvm_valid(words, f"{BASE},+{attr}") for _, attr in FEATURES]
    pairs = {}
    every = llvm_valid(words, "+all")

    def features_of(w):
        if w in base:
            return BASE_ONLY
        for i, ok in enumerate(single):
            if w in ok:
                return 1 << i
        for i in range(len(FEATURES)):
            for j in range(i + 1, len(FEATURES)):
                key = (i, j)
                if key not in pairs:
                    pairs[key] = llvm_valid(words, f"{BASE},+{FEATURES[i][1]},+{FEATURES[j][1]}")
                if w in pairs[key]:
                    return (1 << i) | (1 << j)
        return UNSUPPORTED if w in every else 0

    global DISASM
    DISASM = every
    table = {}
    for ci, idx, ws in samples:
        kinds = {features_of(w) for w in ws}
        if len(kinds) != 1:
            raise SystemExit(f"{CLASSES[ci][0]} index {idx:#x}: templates disagree {sorted(kinds)}")
        table[(ci, idx)] = kinds.pop()
    return table


def host_executes(native_path):
    """{word: True if the host CPU ran it} from difffuzz output for emit_words()."""
    ran = {}
    for line in open(native_path):
        w, _, h = line.split()
        ran.setdefault(int(w, 16), h != "ILL")
    return ran


def manual_features(ci, idx):
    """Features for encodings the host runs but LLVM can't attribute to one or two
    of FEATURES; None if there is no rule (the generator then stops)."""
    return None


M_REGISTER = 0x4000  # elem classes: the M bit is the top bit of Rm, not an index bit


def m_is_register(ci, idx):
    """For the by-element classes: does M (bit 20) select a register (v16-v31)?"""
    name, _, _, fields = CLASSES[ci]
    if name not in ("elem", "s_elem"):
        return False
    shift = index_bits(fields)
    for lsb, width in fields:
        shift -= width
        if lsb == 20:
            mbit = 1 << shift
    w = encode(CLASSES[ci], idx | mbit, TEMPLATES[0])  # Rm field = 3
    return "v19" in DISASM.get(w, "")


def c_fields(fields):
    return ", ".join(f"{{{lsb}, {w}}}" for lsb, w in fields) or "{0, 0}"


def emit_table(native_path):
    table = classify()
    ran = host_executes(native_path)
    out = [
        "// Generated by gen_simd_alloc.py; do not edit. Included by gen.c.",
        "// An encoding is allocated if the reference host (Apple M4) executes it; the",
        "// features it needs come from LLVM's AArch64 disassembler. One uint16_t per",
        "// operation index: 0xffff = unallocated, else the SIMD_FEAT_* bits it needs",
        "// (0 = ARMv8.0), plus SIMD_M_REGISTER for by-element forms whose M bit is Rm<4>.",
        "",
    ]
    problems = []
    for ci, (name, mask, value, fields) in enumerate(CLASSES):
        n = 1 << index_bits(fields)
        vals = []
        for idx in range(n):
            ws = [encode(CLASSES[ci], idx, t) for t in TEMPLATES]
            ws = [w for w in ws if class_of(w) == ci]
            runs = {ran[w] for w in ws}
            f = table[(ci, idx)]
            if not ws or runs == {False}:
                vals.append(0xFFFF)
                if ws and f not in (0, UNSUPPORTED):
                    print(f"note: {name} {ws[0]:08x}: LLVM decodes it (features {f:#x}), the host does not",
                          file=sys.stderr)
                continue
            if len(runs) != 1:
                problems.append(f"{name} index {idx:#x}: host result depends on registers")
                continue
            if f == BASE_ONLY:
                v = 0
            elif f in (0, UNSUPPORTED):
                v = manual_features(ci, idx)
                if v is None:
                    problems.append(f"{name} {ws[0]:08x}: host runs it, LLVM can't attribute it")
                    continue
            else:
                v = f
            if m_is_register(ci, idx):
                v |= M_REGISTER
            vals.append(v)
        # the M=0 and M=1 halves of a pair must agree on whether M is a register bit
        out.append(f"static const uint16_t alloc_{name}[{n}] = {{")
        for i in range(0, n, 16):
            out.append("    " + ", ".join(f"0x{v:04x}" for v in vals[i:i + 16]) + ",")
        out.append("};")
    if problems:
        raise SystemExit("\n".join(problems))
    out.append("")
    out.append("static const struct simd_alloc_class simd_alloc_classes[] = {")
    for name, mask, value, fields in CLASSES:
        out.append(f"    {{0x{mask:08x}, 0x{value:08x}, {len(fields)}, {{{c_fields(fields)}}}, alloc_{name}}},  // {name}")
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
    with open(os.path.join(here, "simd_alloc.inc"), "w") as f:
        f.write("\n".join(out) + "\n")

    asm = [
        "// Generated by gen_simd_alloc.py; do not edit. Included at the end of math.S:",
        "// generic hostop tables, one entry (instruction + branch back) per index.",
    ]
    for name, mask, value, fields, gadget in HOSTOPS:
        asm += ["", "    .p2align 3", f"    .global NAME(hostop_g_{name})", f"NAME(hostop_g_{name}):"]
        free = ~(mask) & 0xFFFFFFFF
        for idx in range(1 << index_bits(fields)):
            w, shift, imask = value, index_bits(fields), 0
            for lsb, width in fields:
                shift -= width
                w |= ((idx >> shift) & ((1 << width) - 1)) << lsb
                imask |= ((1 << width) - 1) << lsb
            w |= HOSTOP_TEMPLATE & free & ~imask
            asm += [f"    .inst 0x{w:08x}", f"    b {GADGETS[gadget][1]}"]
    with open(os.path.join(here, "gadgets-aarch64", "hostop_tables.inc"), "w") as f:
        f.write("\n".join(asm) + "\n")


def emit_words(ntemplates):
    for cls in CLASSES:
        for idx in range(1 << index_bits(cls[3])):
            for t in TEMPLATES[:ntemplates]:
                print(f"{encode(cls, idx, t):08x}")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "table":
        emit_table(sys.argv[2])
    elif len(sys.argv) > 1 and sys.argv[1] == "words":
        emit_words(int(sys.argv[2]) if len(sys.argv) > 2 else len(TEMPLATES))
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
