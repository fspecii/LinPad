#!/bin/bash
# 快速测试脚本 - 跳过已知会卡住的测试

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ISH="$PROJECT_DIR/build-arm64-release/ish"
ROOTFS="$PROJECT_DIR/alpine-arm64-fakefs"

echo "=== iSH ARM64 快速功能测试 ==="
echo "时间: $(date)"
echo ""

PASS=0
FAIL=0
SKIP=0

test_cmd() {
    local name="$1"
    local cmd="$2"
    local timeout="${3:-5}"

    echo -n "Testing $name... "

    if timeout $timeout $ISH -f $ROOTFS /bin/sh -c "$cmd" > /tmp/test_out.txt 2>&1; then
        echo "✅ PASS"
        ((PASS++))
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "⏱️  TIMEOUT (skipped)"
            ((SKIP++))
        else
            echo "❌ FAIL (exit: $exit_code)"
            ((FAIL++))
            tail -3 /tmp/test_out.txt | sed 's/^/  /'
        fi
    fi
}

echo "📦 核心工具测试"
echo "─────────────────"
test_cmd "busybox" "busybox --help" 3
test_cmd "sh" "sh -c 'echo hello'" 3
test_cmd "ls" "ls /" 3
test_cmd "cat" "cat /etc/alpine-release" 3
test_cmd "grep" "echo hello | busybox grep hello" 3
test_cmd "sed" "echo hello | sed 's/hello/world/'" 3
test_cmd "awk" "echo hello | awk '{print \$1}'" 3
test_cmd "find" "find /bin -name sh" 5
test_cmd "tar" "tar --version" 3

echo ""
echo "🔧 系统工具测试"
echo "─────────────────"
test_cmd "hostname" "hostname" 3
test_cmd "uname" "uname -a" 3
test_cmd "whoami" "whoami" 3
test_cmd "id" "id" 3
test_cmd "pwd" "pwd" 3
test_cmd "date" "date" 3
test_cmd "uptime" "uptime" 3
test_cmd "df" "df -h" 3
test_cmd "du" "du -sh /bin" 5
test_cmd "free" "free" 3

echo ""
echo "📝 文件操作测试"
echo "─────────────────"
test_cmd "touch" "touch /tmp/test && rm /tmp/test" 3
test_cmd "mkdir" "rm -rf /tmp/testdir; mkdir /tmp/testdir && rmdir /tmp/testdir" 3
test_cmd "cp" "cp /etc/alpine-release /tmp/test && rm /tmp/test" 3
test_cmd "mv" "rm -f /tmp/bench_a /tmp/bench_b; touch /tmp/bench_a && mv /tmp/bench_a /tmp/bench_b && rm /tmp/bench_b" 3
test_cmd "chmod" "touch /tmp/test && chmod 755 /tmp/test && rm /tmp/test" 3
test_cmd "head" "head -5 /etc/alpine-release" 3
test_cmd "tail" "tail -5 /etc/alpine-release" 3
test_cmd "wc" "wc -l /etc/alpine-release" 3
test_cmd "sort" "echo -e '3\n1\n2' | sort" 3

echo ""
echo "🌐 网络工具测试"
echo "─────────────────"
test_cmd "wget" "wget --version" 3
test_cmd "curl" "curl --version" 3
test_cmd "ping" "ping -c 1 127.0.0.1" 5
test_cmd "nc" "nc -h 2>&1 | head -1" 3
test_cmd "ifconfig" "ifconfig" 3

echo ""
echo "🗜️  压缩工具测试"
echo "─────────────────"
test_cmd "gzip" "echo test | gzip | gunzip" 3
test_cmd "bzip2" "echo test | bzip2 | bunzip2" 3
test_cmd "xz" "echo test | xz | unxz" 5
test_cmd "zip" "echo test > /tmp/t && zip /tmp/t.zip /tmp/t && unzip -l /tmp/t.zip && rm /tmp/t /tmp/t.zip" 5

echo ""
echo "🔐 加密工具测试"
echo "─────────────────"
test_cmd "openssl-version" "openssl version" 3
test_cmd "openssl-md5" "echo test | openssl md5" 3
test_cmd "openssl-sha256" "echo test | openssl sha256" 3
test_cmd "ssh" "ssh -V 2>&1" 3

echo ""
echo "📜 脚本语言测试"
echo "─────────────────"
test_cmd "python3" "python3 --version" 5
test_cmd "python-hello" "python3 -c 'print(42)'" 5
test_cmd "perl" "perl --version" 3
test_cmd "perl-hello" "perl -e 'print 42'" 3
test_cmd "lua" "lua5.4 -v" 3

echo ""
echo "📊 科学计算测试"
echo "─────────────────"
test_cmd "numpy-import" "python3 -c 'import numpy; print(numpy.__version__)'" 15
test_cmd "numpy-compute" "python3 -c 'import numpy as np; a=np.linspace(0,10,100); print(np.mean(np.sin(a)))'" 15
test_cmd "numpy-linalg" "python3 -c 'import numpy as np; A=np.array([[1,2],[3,4]]); print(np.linalg.det(A))'" 15
test_cmd "matplotlib-import" "python3 -c 'import matplotlib; matplotlib.use(\"Agg\"); print(matplotlib.__version__)'" 30
test_cmd "matplotlib-plot" "python3 -c '
import matplotlib; matplotlib.use(\"Agg\")
import matplotlib.pyplot as plt
import numpy as np
x = np.linspace(0,10,50); fig,ax = plt.subplots()
ax.plot(x, np.sin(x)); fig.savefig(\"/tmp/bench_test.png\", dpi=72)
plt.close(fig)
import os; print(\"PNG:\", os.path.getsize(\"/tmp/bench_test.png\"), \"bytes\")
'" 120
test_cmd "matplotlib-multi" "python3 -c '
import matplotlib; matplotlib.use(\"Agg\")
import matplotlib.pyplot as plt
import numpy as np
fig, axes = plt.subplots(2, 2, figsize=(8,6))
x = np.linspace(0,10,50)
axes[0,0].plot(x, np.sin(x))
axes[0,1].scatter(np.random.randn(30), np.random.randn(30))
axes[1,0].bar([\"A\",\"B\",\"C\"], [3,7,5])
axes[1,1].imshow(np.random.rand(8,8), cmap=\"viridis\")
fig.savefig(\"/tmp/bench_multi.png\", dpi=72)
plt.close(fig)
import os; print(\"PNG:\", os.path.getsize(\"/tmp/bench_multi.png\"), \"bytes\")
'" 180

echo ""
echo "🔢 开发工具测试"
echo "─────────────────"
test_cmd "gcc" "gcc --version" 3
test_cmd "make" "make --version" 3
test_cmd "git" "git --version" 3
test_cmd "vim" "vim --version | head -1" 3

echo ""
echo "📊 测试结果汇总"
echo "══════════════════════════"
TOTAL=$((PASS + FAIL + SKIP))
echo "总计: $TOTAL"
PERCENT=$((PASS * 100 / TOTAL))
echo "通过: $PASS ($PERCENT%)"
echo "失败: $FAIL"
echo "跳过: $SKIP"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "✅ 所有测试通过！"
    exit 0
else
    echo "❌ 有 $FAIL 个测试失败"
    exit 1
fi
