#!/usr/bin/env python3
"""Python 性能基准: 文本处理 / 数学运算 / 图片处理 / JSON / 正则 / 加密"""
import time, sys, json, re, hashlib, base64, math, os

results = []

def bench(name, func, *args):
    t0 = time.monotonic()
    ret = func(*args)
    t1 = time.monotonic()
    ms = round((t1 - t0) * 1000)
    results.append((name, ms))
    print(f"{name:<40s} {ms:>6d} ms")
    return ret

# ━━━ 文本处理 ━━━
def text_concat():
    s = ""
    for i in range(50000):
        s += str(i)
    return len(s)

def text_split_join():
    s = " ".join(str(i) for i in range(50000))
    parts = s.split(" ")
    return len(parts)

def text_replace():
    s = "hello world " * 10000
    for _ in range(100):
        s = s.replace("hello", "HELLO").replace("HELLO", "hello")
    return len(s)

def text_format():
    results_list = []
    for i in range(50000):
        results_list.append(f"item_{i}: value={i*3.14:.4f}, hex=0x{i:08x}")
    return len(results_list)

def regex_search():
    text = "The quick brown fox 123 jumps over 456 lazy dogs 789\n" * 1000
    pat = re.compile(r'\b\d{3}\b')
    matches = pat.findall(text)
    return len(matches)

def regex_replace():
    text = "foo123bar456baz789qux012\n" * 5000
    pat = re.compile(r'(\d+)')
    result = pat.sub(lambda m: str(int(m.group()) * 2), text)
    return len(result)

# ━━━ 数学运算 ━━━
def math_int_arith():
    a, b, c = 123456789, 987654321, 0
    for i in range(2000000):
        c = a * b + c
        a = c % 1000000007
        b = (a ^ b) + i
        c = a + b
    return c

def math_float():
    x, y = 1.0, 0.0
    for i in range(1000000):
        x = math.sin(x) + math.cos(y)
        y = math.sqrt(abs(x)) + math.log(abs(y) + 1)
    return x + y

def math_fibonacci():
    def fib(n):
        if n < 2: return n
        return fib(n-1) + fib(n-2)
    return fib(32)

def math_prime_sieve():
    """Sieve of Eratosthenes up to 500000"""
    n = 500000
    sieve = [True] * (n + 1)
    sieve[0] = sieve[1] = False
    for i in range(2, int(n**0.5) + 1):
        if sieve[i]:
            for j in range(i*i, n + 1, i):
                sieve[j] = False
    return sum(sieve)

def math_matrix():
    """Matrix multiply 64x64"""
    N = 64
    A = [[float(i * N + j) for j in range(N)] for i in range(N)]
    B = [[float(i * N + j) for j in range(N)] for i in range(N)]
    C = [[0.0] * N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            s = 0.0
            for k in range(N):
                s += A[i][k] * B[k][j]
            C[i][j] = s
    return C[0][0]

# ━━━ JSON 处理 ━━━
def json_serialize():
    data = [{"id": i, "name": f"user_{i}", "email": f"user{i}@example.com",
             "scores": [i * 0.1, i * 0.2, i * 0.3]} for i in range(10000)]
    s = json.dumps(data)
    return len(s)

def json_parse():
    data = [{"id": i, "name": f"user_{i}", "scores": [i, i*2, i*3]} for i in range(10000)]
    s = json.dumps(data)
    parsed = json.loads(s)
    return len(parsed)

def json_roundtrip():
    data = {"users": [{"id": i, "tags": [f"t{j}" for j in range(5)]} for i in range(5000)]}
    for _ in range(10):
        data = json.loads(json.dumps(data))
    return len(data["users"])

# ━━━ 加密 & 哈希 ━━━
def hash_md5():
    data = b"benchmark data for hashing performance test " * 100
    for _ in range(10000):
        hashlib.md5(data).hexdigest()

def hash_sha256():
    data = b"benchmark data for hashing performance test " * 100
    for _ in range(10000):
        hashlib.sha256(data).hexdigest()

def base64_encode_decode():
    data = b"A" * 10000
    for _ in range(10000):
        enc = base64.b64encode(data)
        base64.b64decode(enc)

# ━━━ 列表/字典操作 ━━━
def list_sort():
    import random
    random.seed(42)
    data = [random.randint(0, 1000000) for _ in range(200000)]
    data.sort()
    return data[0]

def dict_operations():
    d = {}
    for i in range(200000):
        d[f"key_{i}"] = i
    total = 0
    for i in range(200000):
        total += d.get(f"key_{i}", 0)
    return total

# ━━━ 图片处理 (Pillow) ━━━
def image_create_fill():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (800, 600), "white")
    draw = ImageDraw.Draw(img)
    for i in range(100):
        x, y = (i * 7) % 700, (i * 11) % 500
        draw.rectangle([x, y, x + 80, y + 60], fill=(i % 256, (i*3) % 256, (i*7) % 256))
    return img.size

def image_resize():
    from PIL import Image
    img = Image.new("RGB", (1920, 1080), "blue")
    for _ in range(10):
        small = img.resize((480, 270), Image.LANCZOS)
        big = small.resize((1920, 1080), Image.LANCZOS)
    return big.size

def image_filter():
    from PIL import Image, ImageFilter
    img = Image.new("RGB", (800, 600))
    pixels = img.load()
    for y in range(600):
        for x in range(800):
            pixels[x, y] = ((x * 7) % 256, (y * 11) % 256, ((x + y) * 3) % 256)
    img = img.filter(ImageFilter.GaussianBlur(radius=5))
    img = img.filter(ImageFilter.SHARPEN)
    return img.size

def image_convert_save():
    from PIL import Image
    import io
    img = Image.new("RGB", (640, 480), "red")
    for fmt in ["PNG", "BMP"]:
        for _ in range(5):
            buf = io.BytesIO()
            img.save(buf, format=fmt)
    return "done"

# ━━━ 运行所有测试 ━━━
if __name__ == "__main__":
    print("=" * 52)
    print("Python Performance Benchmark")
    print("=" * 52)

    print("\n--- 文本处理 ---")
    bench("string concat 50K", text_concat)
    bench("string split+join 50K", text_split_join)
    bench("string replace 100x", text_replace)
    bench("string format 50K", text_format)
    bench("regex search", regex_search)
    bench("regex replace", regex_replace)

    print("\n--- 数学运算 ---")
    bench("int arithmetic 2M", math_int_arith)
    bench("float sin/cos/sqrt/log 1M", math_float)
    bench("fibonacci(32) recursive", math_fibonacci)
    bench("prime sieve 500K", math_prime_sieve)
    bench("matrix multiply 64x64", math_matrix)

    print("\n--- JSON ---")
    bench("json serialize 10K objects", json_serialize)
    bench("json parse 10K objects", json_parse)
    bench("json roundtrip 5K x10", json_roundtrip)

    print("\n--- 加密 & 哈希 ---")
    bench("md5 x10K (4.5KB each)", hash_md5)
    bench("sha256 x10K (4.5KB each)", hash_sha256)
    bench("base64 encode+decode x10K", base64_encode_decode)

    print("\n--- 列表/字典 ---")
    bench("list sort 200K ints", list_sort)
    bench("dict ops 200K entries", dict_operations)

    # Pillow 测试
    print("\n--- 图片处理 (Pillow) ---")
    try:
        bench("image create + draw 800x600", image_create_fill)
        bench("image resize 1920x1080 x10", image_resize)
        bench("image filter (blur+sharpen)", image_filter)
        bench("image convert+save (PNG/BMP)", image_convert_save)
    except ImportError:
        print("  [SKIP] Pillow not installed")

    print("\n" + "=" * 52)
    total = sum(ms for _, ms in results)
    print(f"Total: {total} ms ({total/1000:.1f}s)")
