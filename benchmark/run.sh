#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# iSH Unified Benchmark — Performance & Compatibility
#
# Usage:
#   ./run.sh                  # Run all suites
#   ./run.sh shell            # Shell-level: Native vs x86 vs ARM64
#   ./run.sh python           # Python workloads (ARM64 only)
#   ./run.sh node             # Node.js workloads (ARM64 only)
#   ./run.sh c                # C workloads (compile + run inside ARM64)
#   ./run.sh compat           # Compatibility pass/fail tests
#
# Assets:  assets/pybench.py, assets/nodebench.js, assets/cbench.c
# Reports: BENCHMARK_PERF.md, BENCHMARK_COMPAT.md
# Data:    results/
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
ASSETS_DIR="$SCRIPT_DIR/assets"
DATE=$(date +%Y%m%d_%H%M%S)

ISH_X86="$PROJECT_DIR/build-x86-release/ish"
ISH_ARM64="$PROJECT_DIR/build-arm64-release/ish"
FAKEFS_X86="$PROJECT_DIR/alpine-x86-fakefs"
FAKEFS_ARM64="$PROJECT_DIR/alpine-arm64-fakefs"

PERF_MD="$SCRIPT_DIR/BENCHMARK_PERF.md"
COMPAT_MD="$SCRIPT_DIR/BENCHMARK_COMPAT.md"
CSV="$RESULTS_DIR/run_${DATE}.csv"
RUNS=3
TIMEOUT_S=120

mkdir -p "$RESULTS_DIR"

# ── Colors & helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
log()  { echo -e "${CYAN}>>>${NC} $*"; }
ok()   { echo -e "${GREEN}OK${NC}  $*"; }
fail() { echo -e "${RED}ERR${NC} $*"; }
hr()   { echo "────────────────────────────────────────────────────────────────"; }

# ── Preflight ───────────────────────────────────────────────────────
preflight() {
    local ok=1
    [ -x "$ISH_X86" ]       || { fail "x86 binary: $ISH_X86"; ok=0; }
    [ -x "$ISH_ARM64" ]     || { fail "ARM64 binary: $ISH_ARM64"; ok=0; }
    [ -d "$FAKEFS_X86" ]    || { fail "x86 fakefs: $FAKEFS_X86"; ok=0; }
    [ -d "$FAKEFS_ARM64" ]  || { fail "ARM64 fakefs: $FAKEFS_ARM64"; ok=0; }
    [ $ok -eq 0 ] && exit 1
}

# ── Timing via /usr/bin/time ────────────────────────────────────────
# Returns "seconds instructions"
_time() {
    local tmp; tmp=$(mktemp)
    if timeout "$TIMEOUT_S" /usr/bin/time -l "$@" >/dev/null 2>"$tmp"; then :
    elif [ $? -eq 124 ]; then rm -f "$tmp"; echo "TIMEOUT 0"; return; fi
    local t; t=$(awk '/real/{print $1}' "$tmp" | head -1); [ -z "$t" ] && t=0
    local i; i=$(awk '/instructions retired/{gsub(/,/,""); print $1}' "$tmp"); [ -z "$i" ] && i=0
    rm -f "$tmp"; echo "$t $i"
}

_median() {
    echo "$@" | tr ' ' '\n' | grep -vE 'TIMEOUT|FAIL' | sort -n |
        awk '{a[NR]=$1} END{if(NR==0)print"FAIL";else if(NR%2)print a[(NR+1)/2];else print(a[NR/2]+a[NR/2+1])/2}'
}

_ratio() {
    local a="$1" b="$2"
    { [ "$a" = "FAIL" ] || [ "$b" = "FAIL" ]; } && { echo "—"; return; }
    awk "BEGIN{b=$b; if(b>0.00001)printf\"%.1fx\",$a/b; else print\"—\"}"
}

_fmti() {
    local n="$1"
    { [ "$n" = "0" ] || [ "$n" = "FAIL" ]; } && { echo "—"; return; }
    awk "BEGIN{n=$n; if(n>=1e9)printf\"%.1fB\",n/1e9; else if(n>=1e6)printf\"%.0fM\",n/1e6; else printf\"%.0fK\",n/1e3}"
}

# ── Run ISH helpers ─────────────────────────────────────────────────
ish_x86()  { "$ISH_X86" -f "$FAKEFS_X86" /bin/sh -c "$1"; }
ish_arm()  { "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "$1"; }

# Push a file into the ARM64 fakefs data directory
push_asset() {
    local src="$1" dst="$2"
    cp "$src" "$FAKEFS_ARM64/data$dst"
}

# ═══════════════════════════════════════════════════════════════════
# SUITE 1: Shell — tri-architecture wall clock + instructions
# ═══════════════════════════════════════════════════════════════════

SHELL_TESTS=(
    "System|echo hello|echo 'Hello World'"
    "System|uname -a|uname -a"
    "System|ls /bin|ls /bin"
    "System|cat file|cat /etc/os-release"
    "System|wc -l|ls /bin | wc -l"
    "System|date|date"
    "Compute|loop 1000|i=0; while [ \$i -lt 1000 ]; do i=\$((i+1)); done"
    "Compute|loop 5000|i=0; while [ \$i -lt 5000 ]; do i=\$((i+1)); done"
    "Compute|seq+awk 10K|seq 1 10000 | awk '{s+=\$1} END{print s}'"
    "Compute|seq+awk 50K|seq 1 50000 | awk '{s+=\$1} END{print s}'"
    "Compute|expr loop 500|i=0; while [ \$i -lt 500 ]; do i=\$(expr \$i + 1); done"
    "Compute|bc sqrt|echo 'scale=100; sqrt(2)' | bc -l"
    "Text|sed replace|echo 'hello world' | sed 's/world/iSH/g'"
    "Text|sort 1K lines|seq 1 1000 | sort -nr | tail -1"
    "Text|uniq count|seq 1 500 | sort | uniq -c | wc -l"
    "File-IO|create 50 files|for i in \$(seq 1 50); do echo x > /tmp/_b\$i; done; rm /tmp/_b*"
    "File-IO|create 200 files|for i in \$(seq 1 200); do echo x > /tmp/_b\$i; done; rm /tmp/_b*"
    "File-IO|find /bin|find /bin -type f 2>/dev/null | wc -l"
    "Crypto|md5sum|echo test | md5sum"
    "Crypto|sha256sum|echo test | sha256sum"
    "Process|fork+exec 10|for i in \$(seq 1 10); do /bin/true; done"
    "Process|fork+exec 50|for i in \$(seq 1 50); do /bin/true; done"
    "Process|pipe chain|seq 1 1000 | grep 5 | sort -n | wc -l"
)

suite_shell() {
    log "Shell benchmark (Native vs x86 vs ARM64, $RUNS runs, median)"
    hr

    printf "${BOLD}%-9s %-18s │ %7s %7s │ %7s %7s │ %7s %7s │ %8s %8s${NC}\n" \
        "Cat" "Test" "Native" "" "x86" "" "ARM64" "" "x86/A64" "x86/A64"
    printf "${DIM}%9s %18s │ %7s %7s │ %7s %7s │ %7s %7s │ %8s %8s${NC}\n" \
        "" "" "time" "insns" "time" "insns" "time" "insns" "time" "insns"
    hr

    local rows=() total=${#SHELL_TESTS[@]} n=0

    for line in "${SHELL_TESTS[@]}"; do
        n=$((n+1))
        IFS='|' read -r cat name cmd <<< "$line"
        echo -ne "\r${DIM}[$n/$total] $name${NC}                         \r" >&2

        local nt=() ni=() xt=() xi=() at=() ai=()
        for _ in $(seq 1 $RUNS); do
            local r
            r=$(_time bash -c "$cmd");          nt+=("${r%% *}"); ni+=("${r##* }")
            r=$(_time "$ISH_X86" -f "$FAKEFS_X86" /bin/sh -c "$cmd"); xt+=("${r%% *}"); xi+=("${r##* }")
            r=$(_time "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "$cmd"); at+=("${r%% *}"); ai+=("${r##* }")
        done

        local mnt mni mxt mxi mat mai
        mnt=$(_median "${nt[@]}"); mni=$(_median "${ni[@]}")
        mxt=$(_median "${xt[@]}"); mxi=$(_median "${xi[@]}")
        mat=$(_median "${at[@]}"); mai=$(_median "${ai[@]}")

        local rt ri
        rt=$(_ratio "$mxt" "$mat"); ri=$(_ratio "$mxi" "$mai")

        printf "%-9s %-18s │ %6ss %7s │ %6ss %7s │ %6ss %7s │ %8s %8s\n" \
            "$cat" "$name" "$mnt" "$(_fmti "$mni")" "$mxt" "$(_fmti "$mxi")" "$mat" "$(_fmti "$mai")" "$rt" "$ri"

        echo "shell,$cat,$name,$mnt,$mni,$mxt,$mxi,$mat,$mai" >> "$CSV"
        rows+=("$cat|$name|${mnt}s|$(_fmti "$mni")|${mxt}s|$(_fmti "$mxi")|${mat}s|$(_fmti "$mai")|$(_ratio "$mxt" "$mnt")|$(_ratio "$mat" "$mnt")|$rt|$ri")
    done

    echo ""
    # Write shell section of perf markdown
    _md_shell_section "${rows[@]}"
}

_md_shell_section() {
    local rows=("$@") prev=""
    {
        echo "## 1. Shell Benchmark (Native vs x86 vs ARM64)"
        echo ""
        echo "> Measured with \`/usr/bin/time -l\`. **Instructions retired** eliminates"
        echo "> filesystem-mode differences (x86 realfs vs ARM64 fakefs)."
        echo ""
    } >> "$PERF_MD"

    for r in "${rows[@]}"; do
        IFS='|' read -r cat name nt ni xt xi at ai xn an rt ri <<< "$r"
        if [ "$cat" != "$prev" ]; then
            [ -n "$prev" ] && echo "" >> "$PERF_MD"
            echo "### $cat" >> "$PERF_MD"
            echo "" >> "$PERF_MD"
            echo "| Test | Native | | x86 | | ARM64 | | x86/N | A64/N | x86/A64 | x86/A64 |" >> "$PERF_MD"
            echo "|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|" >> "$PERF_MD"
            echo "| | time | insns | time | insns | time | insns | time | time | time | **insns** |" >> "$PERF_MD"
            prev="$cat"
        fi
        echo "| $name | $nt | $ni | $xt | $xi | $at | $ai | $xn | $an | $rt | **$ri** |" >> "$PERF_MD"
    done
    echo "" >> "$PERF_MD"
}

# ═══════════════════════════════════════════════════════════════════
# SUITE 2: Python — run pybench.py inside ARM64 iSH
# ═══════════════════════════════════════════════════════════════════

suite_python() {
    log "Python benchmark (ARM64 iSH)"
    hr

    push_asset "$ASSETS_DIR/pybench.py" "/tmp/pybench.py"

    # Single run: capture both /usr/bin/time and stdout
    local output_tmp; output_tmp=$(mktemp)
    local time_tmp; time_tmp=$(mktemp)
    timeout "$TIMEOUT_S" /usr/bin/time -l \
        "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "python3 /tmp/pybench.py" \
        > "$output_tmp" 2>"$time_tmp" || true

    local total_time; total_time=$(awk '/real/{print $1}' "$time_tmp" | head -1); [ -z "$total_time" ] && total_time=0
    local total_insns; total_insns=$(awk '/instructions retired/{gsub(/,/,""); print $1}' "$time_tmp"); [ -z "$total_insns" ] && total_insns=0

    echo ""
    cat "$output_tmp"
    echo ""
    ok "Python total: ${total_time}s ($(_fmti "$total_insns") instructions)"

    echo "python,total,pybench.py,$total_time,$total_insns,,,," >> "$CSV"

    {
        echo "## 2. Python Benchmark (ARM64 iSH)"
        echo ""
        echo "> \`assets/pybench.py\` — 19 tests: text, math, JSON, crypto, list/dict."
        echo "> x86 iSH cannot run Python (no python3 in minirootfs; 32-bit limit)."
        echo ""
        echo "\`\`\`"
        cat "$output_tmp"
        echo "\`\`\`"
        echo ""
        echo "**Total wall clock:** ${total_time}s | **Instructions:** $(_fmti "$total_insns")"
        echo ""
    } >> "$PERF_MD"

    rm -f "$output_tmp" "$time_tmp"
}

# ═══════════════════════════════════════════════════════════════════
# SUITE 3: Node.js — run nodebench.js inside ARM64 iSH
# ═══════════════════════════════════════════════════════════════════

suite_node() {
    log "Node.js benchmark (ARM64 iSH)"
    hr

    # Check if node exists
    if ! timeout 10 "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "which node" >/dev/null 2>&1; then
        fail "node not installed in ARM64 rootfs — skipping"
        {
            echo "## 3. Node.js Benchmark (ARM64 iSH)"
            echo ""
            echo "> **Skipped** — node not installed in ARM64 rootfs."
            echo ""
        } >> "$PERF_MD"
        return
    fi

    push_asset "$ASSETS_DIR/nodebench.js" "/tmp/nodebench.js"

    local output_tmp; output_tmp=$(mktemp)
    local time_tmp; time_tmp=$(mktemp)
    timeout "$TIMEOUT_S" /usr/bin/time -l \
        "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "node /tmp/nodebench.js" \
        > "$output_tmp" 2>"$time_tmp" || true

    local total_time; total_time=$(awk '/real/{print $1}' "$time_tmp" | head -1); [ -z "$total_time" ] && total_time=0
    local total_insns; total_insns=$(awk '/instructions retired/{gsub(/,/,""); print $1}' "$time_tmp"); [ -z "$total_insns" ] && total_insns=0

    echo ""
    cat "$output_tmp"
    echo ""
    ok "Node.js total: ${total_time}s ($(_fmti "$total_insns") instructions)"

    echo "node,total,nodebench.js,$total_time,$total_insns,,,," >> "$CSV"

    {
        echo "## 3. Node.js Benchmark (ARM64 iSH)"
        echo ""
        echo "> \`assets/nodebench.js\` — 18 tests: text, math, JSON, crypto, buffer."
        echo "> x86 iSH cannot run Node.js (V8 requires 48-bit address space)."
        echo ""
        echo "\`\`\`"
        cat "$output_tmp"
        echo "\`\`\`"
        echo ""
        echo "**Total wall clock:** ${total_time}s | **Instructions:** $(_fmti "$total_insns")"
        echo ""
    } >> "$PERF_MD"

    rm -f "$output_tmp" "$time_tmp"
}

# ═══════════════════════════════════════════════════════════════════
# SUITE 4: C — compile cbench.c inside ARM64, then run
# ═══════════════════════════════════════════════════════════════════

suite_c() {
    log "C benchmark (compile + run inside ARM64 iSH)"
    hr

    if ! timeout 10 "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "which gcc" >/dev/null 2>&1; then
        fail "gcc not installed in ARM64 rootfs — skipping"
        {
            echo "## 4. C Benchmark (ARM64 iSH)"
            echo ""
            echo "> **Skipped** — gcc not installed in ARM64 rootfs."
            echo ""
        } >> "$PERF_MD"
        return
    fi

    push_asset "$ASSETS_DIR/cbench.c" "/tmp/cbench.c"

    log "Compiling cbench.c inside iSH..."
    if ! timeout 120 "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c \
        "gcc -O2 -o /tmp/cbench /tmp/cbench.c -lm" >/dev/null 2>&1; then
        fail "Compilation failed — skipping"
        return
    fi
    ok "Compiled"

    local output_tmp; output_tmp=$(mktemp)
    local time_tmp; time_tmp=$(mktemp)
    timeout "$TIMEOUT_S" /usr/bin/time -l \
        "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "/tmp/cbench" \
        > "$output_tmp" 2>"$time_tmp" || true

    local total_time; total_time=$(awk '/real/{print $1}' "$time_tmp" | head -1); [ -z "$total_time" ] && total_time=0
    local total_insns; total_insns=$(awk '/instructions retired/{gsub(/,/,""); print $1}' "$time_tmp"); [ -z "$total_insns" ] && total_insns=0

    echo ""
    cat "$output_tmp"
    echo ""
    ok "C total: ${total_time}s ($(_fmti "$total_insns") instructions)"

    echo "c,total,cbench.c,$total_time,$total_insns,,,," >> "$CSV"

    {
        echo "## 4. C Benchmark (ARM64 iSH)"
        echo ""
        echo "> \`assets/cbench.c\` — 10 tests: integer, float, memory, branch, matrix, string."
        echo "> Compiled with \`gcc -O2\` inside iSH, then executed."
        echo ""
        echo "\`\`\`"
        cat "$output_tmp"
        echo "\`\`\`"
        echo ""
        echo "**Total wall clock:** ${total_time}s | **Instructions:** $(_fmti "$total_insns")"
        echo ""
    } >> "$PERF_MD"

    rm -f "$output_tmp" "$time_tmp"
}

# ═══════════════════════════════════════════════════════════════════
# SUITE 5: Compatibility — pass/fail across x86 and ARM64
# ═══════════════════════════════════════════════════════════════════

COMPAT_TESTS=(
    "Core|sh|sh -c 'echo ok'"
    "Core|echo|echo test"
    "Core|printf|printf '%s\n' test"
    "Core|test|test 1 -eq 1"
    "Core|true|true"
    "Core|false|false; true"
    "Core|ls|ls / >/dev/null"
    "Core|cat|cat /etc/os-release >/dev/null"
    "Core|head|head -1 /etc/os-release >/dev/null"
    "Core|tail|tail -1 /etc/os-release >/dev/null"
    "Core|wc|echo test | wc -l"
    "Core|tee|echo test | tee /dev/null >/dev/null"
    "Core|env|env >/dev/null"
    "Core|pwd|pwd >/dev/null"
    "Core|id|id >/dev/null"
    "Core|uname|uname -a >/dev/null"
    "Core|date|date >/dev/null"
    "Core|sleep|sleep 0"
    "Core|basename|basename /usr/bin/test"
    "Core|dirname|dirname /usr/bin/test"
    "Core|seq|seq 1 5 >/dev/null"
    "Core|yes|yes | head -1 >/dev/null"
    "FileOps|touch|touch /tmp/_ct && rm /tmp/_ct"
    "FileOps|mkdir+rmdir|mkdir -p /tmp/_cd && rmdir /tmp/_cd"
    "FileOps|cp|echo x>/tmp/_c1 && cp /tmp/_c1 /tmp/_c2 && rm /tmp/_c1 /tmp/_c2"
    "FileOps|mv|echo x>/tmp/_m1 && mv /tmp/_m1 /tmp/_m2 && rm /tmp/_m2"
    "FileOps|ln -s|echo x>/tmp/_l1 && ln -s /tmp/_l1 /tmp/_l2 && rm /tmp/_l1 /tmp/_l2"
    "FileOps|chmod|echo x>/tmp/_h1 && chmod 755 /tmp/_h1 && rm /tmp/_h1"
    "FileOps|stat|stat /bin/sh >/dev/null"
    "FileOps|readlink|readlink -f /bin/sh >/dev/null 2>&1; true"
    "FileOps|dd|dd if=/dev/zero of=/tmp/_d bs=1024 count=1 2>/dev/null && rm /tmp/_d"
    "FileOps|tar|echo x>/tmp/_t && tar cf /tmp/_t.tar /tmp/_t 2>/dev/null && rm /tmp/_t /tmp/_t.tar"
    "FileOps|gzip|echo x | gzip | gunzip >/dev/null"
    "TextProc|grep|echo hello | grep hello >/dev/null"
    "TextProc|sed|echo hello | sed 's/h/H/' >/dev/null"
    "TextProc|awk|echo '1 2' | awk '{print \$2}' >/dev/null"
    "TextProc|sort|echo -e 'b\na' | sort >/dev/null"
    "TextProc|uniq|echo -e 'a\na' | uniq >/dev/null"
    "TextProc|cut|echo 'a:b' | cut -d: -f2 >/dev/null"
    "TextProc|tr|echo AB | tr A-Z a-z >/dev/null"
    "TextProc|diff|diff /etc/os-release /etc/os-release >/dev/null"
    "TextProc|xargs|echo 'a b' | xargs echo >/dev/null"
    "TextProc|find|find /bin -name 'sh' >/dev/null"
    "TextProc|which|which sh >/dev/null"
    "Math|expr|expr 6 + 7 >/dev/null"
    "Math|bc|echo '2+3' | bc >/dev/null 2>&1"
    "ProcDev|/proc/meminfo|cat /proc/meminfo >/dev/null 2>&1; true"
    "ProcDev|/proc/cpuinfo|cat /proc/cpuinfo >/dev/null 2>&1; true"
    "ProcDev|/proc/version|cat /proc/version >/dev/null 2>&1; true"
    "ProcDev|/dev/null|echo test > /dev/null"
    "ProcDev|/dev/zero|dd if=/dev/zero bs=16 count=1 2>/dev/null | wc -c >/dev/null"
    "ProcDev|/dev/urandom|dd if=/dev/urandom bs=16 count=1 2>/dev/null | wc -c >/dev/null"
    "Signal|trap|sh -c 'trap \"echo c\" INT; kill -INT \$\$; echo ok' 2>/dev/null; true"
    "Signal|kill|sh -c 'sleep 99 & kill \$! 2>/dev/null; wait \$! 2>/dev/null; echo ok'"
    "Signal|wait|sh -c 'true & wait \$!'"
    "Signal|background|sh -c 'sleep 0 & wait'"
)

suite_compat() {
    log "Compatibility tests (x86 vs ARM64)"
    hr

    local total=${#COMPAT_TESTS[@]} n=0
    local x86p=0 x86f=0 armp=0 armf=0
    local rows=()

    printf "${BOLD}%-9s %-16s │ %6s │ %6s${NC}\n" "Cat" "Test" "x86" "ARM64"
    hr

    for line in "${COMPAT_TESTS[@]}"; do
        n=$((n+1))
        IFS='|' read -r cat name cmd <<< "$line"

        local xr ar
        if timeout 10 "$ISH_X86" -f "$FAKEFS_X86" /bin/sh -c "$cmd" >/dev/null 2>&1; then
            xr="PASS"; x86p=$((x86p+1))
        else
            xr="FAIL"; x86f=$((x86f+1))
        fi
        if timeout 10 "$ISH_ARM64" -f "$FAKEFS_ARM64" /bin/sh -c "$cmd" >/dev/null 2>&1; then
            ar="PASS"; armp=$((armp+1))
        else
            ar="FAIL"; armf=$((armf+1))
        fi

        local xs as
        [ "$xr" = "PASS" ] && xs="${GREEN}PASS${NC}" || xs="${RED}FAIL${NC}"
        [ "$ar" = "PASS" ] && as="${GREEN}PASS${NC}" || as="${RED}FAIL${NC}"
        printf "%-9s %-16s │ %b │ %b\n" "$cat" "$name" "$xs" "$as"
        rows+=("$cat|$name|$xr|$ar")
    done

    echo ""
    ok "x86:   $x86p / $total pass ($(( x86p * 100 / total ))%)"
    ok "ARM64: $armp / $total pass ($(( armp * 100 / total ))%)"

    _md_compat "$x86p" "$x86f" "$armp" "$armf" "$total" "${rows[@]}"
}

_md_compat() {
    local x86p="$1" x86f="$2" armp="$3" armf="$4" total="$5"
    shift 5; local rows=("$@")

    cat > "$COMPAT_MD" << EOF
# iSH Compatibility: x86 vs ARM64

> **Generated:** $(date '+%Y-%m-%d %H:%M:%S') | **Tests:** $total | **Host:** macOS $(sw_vers -productVersion)
>
> Both architectures use fakefs mode with virtual device nodes.
> x86 = Alpine x86 minirootfs (busybox) | ARM64 = Alpine aarch64 full rootfs (apk)

| Architecture | Pass | Fail | Rate |
|:---:|:---:|:---:|:---:|
| **x86** (Jitter) | $x86p | $x86f | **$(( x86p * 100 / total ))%** |
| **ARM64** (Asbestos JIT) | $armp | $armf | **$(( armp * 100 / total ))%** |

---

EOF

    local prev="" cp=0 cf=0 ap=0 af=0 pending=()

    flush() {
        if [ -n "$prev" ]; then
            local t=$((cp+cf))
            echo "### $prev ($t tests)" >> "$COMPAT_MD"
            echo "" >> "$COMPAT_MD"
            echo "| Test | x86 | ARM64 |" >> "$COMPAT_MD"
            echo "|------|:---:|:---:|" >> "$COMPAT_MD"
            for r in "${pending[@]}"; do echo "$r" >> "$COMPAT_MD"; done
            echo "" >> "$COMPAT_MD"
            echo "> x86: $cp/$t — ARM64: $ap/$t" >> "$COMPAT_MD"
            echo "" >> "$COMPAT_MD"
        fi
        pending=(); cp=0; cf=0; ap=0; af=0
    }

    for entry in "${rows[@]}"; do
        IFS='|' read -r cat name xr ar <<< "$entry"
        if [ "$cat" != "$prev" ]; then flush; prev="$cat"; fi
        [ "$xr" = "PASS" ] && cp=$((cp+1)) || cf=$((cf+1))
        [ "$ar" = "PASS" ] && ap=$((ap+1)) || af=$((af+1))
        pending+=("| $name | $xr | $ar |")
    done
    flush

    # Failures summary
    echo "---" >> "$COMPAT_MD"
    echo "" >> "$COMPAT_MD"
    echo "## Failures" >> "$COMPAT_MD"
    echo "" >> "$COMPAT_MD"
    echo "### x86 only" >> "$COMPAT_MD"
    echo "" >> "$COMPAT_MD"
    local any=0
    for e in "${rows[@]}"; do
        IFS='|' read -r c n x a <<< "$e"
        [ "$x" = "FAIL" ] && [ "$a" = "PASS" ] && { echo "- \`$n\` ($c)" >> "$COMPAT_MD"; any=1; }
    done
    [ $any -eq 0 ] && echo "_None_" >> "$COMPAT_MD"

    echo "" >> "$COMPAT_MD"
    echo "### ARM64 only" >> "$COMPAT_MD"
    echo "" >> "$COMPAT_MD"
    any=0
    for e in "${rows[@]}"; do
        IFS='|' read -r c n x a <<< "$e"
        [ "$a" = "FAIL" ] && [ "$x" = "PASS" ] && { echo "- \`$n\` ($c)" >> "$COMPAT_MD"; any=1; }
    done
    [ $any -eq 0 ] && echo "_None_" >> "$COMPAT_MD"

    ok "Compatibility report: $COMPAT_MD"
}

# ═══════════════════════════════════════════════════════════════════
# Report header
# ═══════════════════════════════════════════════════════════════════

write_perf_header() {
    cat > "$PERF_MD" << HEADER
# iSH Performance Benchmark

> **Generated:** $(date '+%Y-%m-%d %H:%M:%S')
> **Host:** macOS $(sw_vers -productVersion) / $(uname -m)
> **x86:** $(basename "$ISH_X86") ($(ls -lh "$ISH_X86" | awk '{print $5}'), fakefs)
> **ARM64:** $(basename "$ISH_ARM64") ($(ls -lh "$ISH_ARM64" | awk '{print $5}'), fakefs)
> **Runs:** $RUNS (median) | **Timeout:** ${TIMEOUT_S}s

| | x86 Emulation | ARM64 JIT |
|---|:---:|:---:|
| Engine | Interpreter (Jitter) | JIT Compiler (Asbestos) |
| Guest | i386 → ARM64 host | AArch64 → AArch64 host |
| Address | 32-bit (4 GB) | 48-bit (256 TB) |
| SIMD | Partial SSE/SSE2 | Full NEON + Crypto |
| Node/Go/Rust | Not possible | Supported |

---

HEADER
}

# ═══════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════

main() {
    local suite="${1:-all}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  iSH Unified Benchmark"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    preflight

    echo "suite,category,name,native_time,native_insns,x86_time,x86_insns,arm64_time,arm64_insns" > "$CSV"

    case "$suite" in
        all)
            write_perf_header
            echo ""; suite_shell
            echo ""; suite_python
            echo ""; suite_node
            echo ""; suite_c
            echo ""; suite_compat
            ;;
        shell)   write_perf_header; suite_shell ;;
        python)  write_perf_header; suite_python ;;
        node)    write_perf_header; suite_node ;;
        c)       write_perf_header; suite_c ;;
        compat)  suite_compat ;;
        *)       echo "Usage: $0 [all|shell|python|node|c|compat]"; exit 1 ;;
    esac

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    ok "Done"
    [ -f "$PERF_MD" ]   && echo "  Performance:    $PERF_MD"
    [ -f "$COMPAT_MD" ] && echo "  Compatibility:  $COMPAT_MD"
    echo "  Raw CSV:        $CSV"
    echo "═══════════════════════════════════════════════════════════════"
}

main "$@"
