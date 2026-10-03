"""Printable ASCII typed into VS Code's integrated terminal through ishwl's `text` path
(the on-screen keyboard's), on several keyboard layouts: a Chromium/Electron consumer
for wl-bridge/tools/keymap-test.sh, which uses a plain xkbcommon client.

    python3 vscode-keymap.py OUT.json [--layouts "us:-:- de:mac:- ..."]

Uses vscodebench's launch step (headless ishwl, ISHWL selects the binary). For each layout
it types `printf '%s\n' '` on US, sends `keymap`, then types the ASCII line (quotes
escaped) and `' > FILE` and Return on that layout, and compares FILE with the ASCII line.
Everything is typed at the shell prompt: a foreground `cat` or `read` (canonical tty
mode, kernel echo) stalls VS Code's pty host under the emulator after a character or two.
"""
import argparse, json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vscodebench import VSBench, read  # noqa: E402

CTRL, GRAVE, KEY_S = 29, 41, 31
EDITOR_SETTINGS = {
    "editor.autoClosingBrackets": "never", "editor.autoClosingQuotes": "never",
    "editor.autoSurround": "never", "editor.autoClosingOvertype": "never",
    "editor.quickSuggestions": {"other": False, "comments": False, "strings": False},
    "editor.suggestOnTriggerCharacters": False, "editor.acceptSuggestionOnEnter": "off",
    "editor.autoIndent": "none", "editor.formatOnType": False, "files.insertFinalNewline": False,
}


def editor_settings():
    """The editor must keep typed text as is: no auto-closing pairs or suggestions."""
    path = "/root/.config/Code/User/settings.json"
    try:
        text = re.sub(r"^\s*//.*$", "", open(path).read(), flags=re.M)
        settings = json.loads(re.sub(r",(\s*[}\]])", r"\1", text)) if text.strip() else {}
    except (OSError, ValueError):
        settings = {}
    settings.update(EDITOR_SETTINGS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(settings, open(path, "w"), indent=1)
ASCII = "".join(chr(c) for c in range(0x20, 0x7F))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--layouts", default="us:-:- us:mac:- de:mac:- gb:mac:- ro:std:- fr:mac:-")
    ap.add_argument("--project", default="/root/projects/vscb")
    ap.add_argument("--scale", default="1")
    ap.add_argument("--png", action="store_true")
    ap.add_argument("--code-args", default="")
    ap.add_argument("--extension", default="")
    ap.add_argument("--steps", default="launch")
    ap.add_argument("--editor-layouts", default="us:-:- de:mac:- fr:mac:-")
    args = ap.parse_args()
    editor_settings()
    b = VSBench(args)
    res = {"layouts": {}}
    b.t0 = time.time()
    try:
        if not b.step("launch", b.launch):
            raise RuntimeError("VS Code did not start")
        # VS Code shows its "running as root" notification a little after the workbench;
        # typing before things settle lost keys in testing.
        time.sleep(20)
        b.wait_quiet(3000, 60)
        b.key(CTRL, GRAVE)
        if not b.wait(lambda: any(p for p in os.listdir("/proc") if p.isdigit()
                                  and read(f"/proc/{p}/cmdline").startswith("/bin/sh\0-l")), 180, "terminal shell"):
            raise RuntimeError("no terminal")
        time.sleep(3)
        b.text("echo A1 > /tmp/kbd-probe.txt\n")
        res["probe"] = b.wait(lambda: "A1" in read("/tmp/kbd-probe.txt"), 120, "probe command")
        b.shot("kbd-probe")
        print("probe", res["probe"], flush=True)
        for spec in args.layouts.split():
            layout, variant, options = spec.split(":")
            name = spec.replace(":", "_").replace(",", "+")
            path = f"/tmp/kbd-{name}.txt"
            b.send("keymap us - -")
            time.sleep(0.5)
            b.text("printf '%s\\n' '")
            time.sleep(1)
            b.send(f"keymap {layout} {variant} {options}")
            time.sleep(1)
            line = ASCII.replace("'", "'\\''") + f"' > {path}\n"
            for i in range(0, len(line), 16):
                b.text(line[i:i + 16])
                time.sleep(1.5)
            time.sleep(2)
            b.shot("kbd-" + name)
            b.wait(lambda: os.path.exists(path) and read(path).endswith("\n"), 60, "file " + name)
            time.sleep(1)
            got = read(path).rstrip("\n")
            missing = sorted(set(ASCII) - set(got))
            res["layouts"][spec] = {"ok": got == ASCII, "got": got, "missing": "".join(missing)}
            print(spec, "ok" if got == ASCII else f"MISMATCH missing={''.join(missing)!r} got={got!r}", flush=True)
        # The editor: one line per layout in a file opened with `code -r`, saved with Ctrl-S.
        specs = args.editor_layouts.split()
        if specs:
            path = "/tmp/kbd-editor.txt"
            open(path, "w").close()
            b.send("keymap us - -")
            b.text(f"code -r {path}\n")
            time.sleep(15)
            b.wait_quiet(2000, 60)
            for n, spec in enumerate(specs):
                layout, variant, options = spec.split(":")
                b.send(f"keymap {layout} {variant} {options}")
                time.sleep(1)
                line = ASCII + ("\n" if n < len(specs) - 1 else "")
                for i in range(0, len(line), 16):
                    b.text(line[i:i + 16])
                    time.sleep(1.5)
                time.sleep(2)
            b.send("keymap us - -")
            b.key(CTRL, KEY_S)
            want = "\n".join([ASCII] * len(specs))
            b.wait(lambda: read(path) == want, 60, "editor save")
            b.shot("kbd-editor")
            got = read(path)
            res["editor"] = {"layouts": specs, "ok": got == want, "got": got}
            print("editor", " ".join(specs), "ok" if got == want else f"MISMATCH got={got!r}", flush=True)
    except Exception as e:
        res["fatal"] = repr(e)[:300]
        print("fatal", res["fatal"], flush=True)
    finally:
        b.close()
    res["ishwl_log_tail"] = read("/tmp/vscb-ishwl.log")[-1500:]
    json.dump(res, open(args.out, "w"), indent=1)
    ok = res["layouts"] and all(v["ok"] for v in res["layouts"].values()) and res.get("editor", {"ok": True})["ok"]
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
