#!/usr/bin/env python3
"""Backup and restore round trip on a fakefs with the Mac CLI emulator.

Runs the guest script exactly as the app sends it (extracted from BackupGuestScript.swift)
and does the host's part the way BackupService does: the manifest member and a reserved
header before the guest appends the payload, the payload header afterwards, and a copy of
the finished file into the guest for the restore.

    backup-roundtrip.py --ish build-backup/ish --fakefs /path/to/a/clone/of/a/fakefs

The fakefs is modified (test files, a wipe of /root and /home, restores): use a clone
(`cp -cR fakefs fakefs-clone` on APFS).
"""
import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(HERE, "../Sources/DesktopKit/Core/System/Maintenance/Backup/BackupGuestScript.swift")
WORK_ROOT = "/var/tmp/linpad-backup"


def guest_script():
    lines = open(SWIFT).read().split("\n")
    start = lines.index('    static let source = #"""') + 1
    end = lines.index('"""#', start)
    return "\n".join(lines[start:end]) + "\n"


class Guest:
    def __init__(self, ish, fakefs):
        self.ish = ish
        self.fakefs = fakefs
        self.script = guest_script()

    def sh(self, command, check=True, timeout=1800):
        result = subprocess.run([self.ish, "-f", self.fakefs, "/bin/sh", "-c", command],
                                capture_output=True, text=True, timeout=timeout)
        if check and result.returncode != 0:
            raise RuntimeError(f"guest command failed ({result.returncode}): {command[:200]}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def backup_script(self, *args, check=True):
        return self.sh("set -- " + " ".join(shlex.quote(a) for a in args) + "\n" + self.script, check=check)

    def host_path(self, guest_path):
        return os.path.join(self.fakefs, "data", guest_path.lstrip("/"))


# The rules of BackupExclusionCategory.category(of:), for the candidates `scan` prints.
EDITOR_DIRS = {"Code", "Code - OSS", "VSCodium", "code-oss"}
EDITOR_CACHES = {"Cache", "CachedData", "Code Cache", "GPUCache", "CachedExtensionVSIXs", "CachedProfilesData",
                 "logs", "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad"}


def category(path):
    parts = [p for p in path.split("/") if p]
    depth = {"root": 1, "home": 2}.get(parts[0] if parts else "")
    if depth is None or len(parts) <= depth:
        return None
    rest = parts[depth:]
    if rest[-1] == "node_modules":
        return "node-modules"
    if rest == [".cache"] or rest == [".npm", "_cacache"]:
        return "caches"
    if len(rest) == 3 and rest[0] == ".config" and rest[1] in EDITOR_DIRS and rest[2] in EDITOR_CACHES:
        return "editor-caches"
    if len(rest) == 4 and rest[:2] == [".mozilla", "firefox"] and rest[3] in ("cache2", "startupCache"):
        return "caches"
    return None


SCAN_PRIMARIES = ["name:.cache", "name:node_modules", "path:*/.npm/_cacache",
                  "path:*/.mozilla/firefox/*/cache2", "path:*/.mozilla/firefox/*/startupCache"] + [
    f"path:*/.config/{d}/{c}" for d in sorted(EDITOR_DIRS) for c in sorted(EDITOR_CACHES)]

MAKE_TEST_FILES = r"""
set -e
mkdir -p /root/rt/sub "/root/rt/with space" /root/rt/empty /home/alice/docs
echo hello > /root/rt/a.txt && chmod 600 /root/rt/a.txt
printf '#!/bin/sh\necho hi\n' > /root/rt/run.sh && chmod 755 /root/rt/run.sh
ln -sf a.txt /root/rt/link && ln -sf /etc/hostname /root/rt/abs-link
dd if=/dev/urandom of=/root/rt/random.bin bs=1024 count=20480 2>/dev/null
printf 'caf\303\251\n' > "/root/rt/with space/\303\274n\303\257code [1].txt"
echo nested > /root/rt/sub/deep.txt && touch -d '2020-01-02 03:04:05' /root/rt/sub/deep.txt
chmod 4755 /root/rt/run.sh
echo alice > /home/alice/docs/n.txt && chown -R 1000:1000 /home/alice && chmod 700 /home/alice
mkfifo /root/rt/fifo
mkdir -p "/root/rt/br [x]*/node_modules/m" && echo dep > "/root/rt/br [x]*/node_modules/m/index.js"
mkdir -p /root/.cache/thumbs /root/.config/Code/CachedData /root/.mozilla/firefox/p.default/cache2/entries /home/alice/.cache
dd if=/dev/urandom of=/root/.cache/thumbs/big.bin bs=1024 count=4096 2>/dev/null
echo x > /root/.config/Code/CachedData/c && echo y > /root/.mozilla/firefox/p.default/cache2/entries/e
echo prefs > /root/.mozilla/firefox/p.default/prefs.js && echo z > /home/alice/.cache/z
"""

CHECKSUMS = r"""
cd /
find root home -xdev | sort | while IFS= read -r p; do
    t=$(stat -c '%F|%a|%u|%g' "$p")
    case "$t" in
        regular*) s="$(sha256sum < "$p" | cut -c1-64)|$(stat -c %Y "$p")" ;;
        symbolic*) s="$(readlink "$p")" ;;
        *) s=- ;;
    esac
    printf '%s|%s|%s\n' "$p" "$t" "$s"
done
"""


def checksums(guest, excluded):
    rows = {}
    for line in guest.sh(CHECKSUMS).splitlines():
        path = line.split("|", 1)[0]
        if any(path == e or path.startswith(e + "/") for e in excluded):
            continue
        rows[path] = line
    return rows


def ustar_header(name, size):
    info = tarfile.TarInfo(name)
    info.size = size
    info.mtime = int(time.time())
    info.mode = 0o644
    return info.tobuf(format=tarfile.USTAR_FORMAT)


def report_lines(output):
    return [l for l in output.splitlines() if l.startswith("@@")]


def make_backup(guest, excludes, compressor, out_path, results, label):
    work = f"{WORK_ROOT}/{uuid.uuid4()}"
    guest.sh(f"rm -rf {work} && mkdir -p {work} && : > {work}/backup.tar && : > {work}/excludes")
    with open(guest.host_path(f"{work}/excludes"), "w") as f:
        f.write("\n".join(excludes) + "\n")
    files = int([l for l in report_lines(guest.backup_script("list", work)) if l.startswith("@@files ")][0].split()[1])
    manifest = json.dumps({"format": 1, "fileCount": files, "compression": compressor}).encode()
    archive = guest.host_path(f"{work}/backup.tar")
    with open(archive, "wb") as f:
        f.write(ustar_header("manifest.json", len(manifest)))
        f.write(manifest + b"\0" * ((512 - len(manifest) % 512) % 512))
        header_offset = f.tell()
        f.write(b"\0" * 512)
    started = time.time()
    output = guest.backup_script("archive", work, compressor)
    elapsed = time.time() - started
    assert "@@done" in report_lines(output), output
    with open(archive, "r+b") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell() - header_offset - 512
        f.write(b"\0" * ((512 - size % 512) % 512) + b"\0" * 1024)
        f.seek(header_offset)
        f.write(ustar_header("linux.tar.zst" if compressor == "zstd" else "linux.tar.gz", size))
    shutil.copyfile(archive, out_path)
    guest.sh(f"rm -rf {work}")
    results[label] = {"files": files, "seconds": round(elapsed, 2), "payload_bytes": size,
                      "warnings": [l for l in report_lines(output) if l.startswith("@@warn")]}
    return out_path


def restore(guest, backup, mode, results, label):
    with tarfile.open(backup) as archive:
        members = archive.getmembers()
        assert members[0].name == "manifest.json", [m.name for m in members]
        payload = members[-1]
        compressor = "zstd" if payload.name.endswith(".zst") else "gzip"
    work = f"{WORK_ROOT}/{uuid.uuid4()}"
    guest.sh(f"rm -rf {work} && mkdir -p {work} && : > {work}/backup.tar")
    staged = guest.host_path(f"{work}/backup.tar")
    os.remove(staged)
    shutil.copyfile(backup, staged)
    started = time.time()
    output = guest.backup_script("restore", f"{work}/backup.tar", str(payload.offset_data), str(payload.size),
                                 compressor, mode, work)
    elapsed = time.time() - started
    lines = report_lines(output)
    assert "@@done" in lines, output
    restored = int(guest.sh(f"wc -l < {work}/names").strip())
    guest.sh(f"rm -rf {work}")
    results[label] = {"seconds": round(elapsed, 2), "restored_entries": restored, "report": lines}
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ish", required=True)
    parser.add_argument("--fakefs", required=True)
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "backup-roundtrip"))
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    guest = Guest(args.ish, args.fakefs)
    results = {}

    guest.sh(MAKE_TEST_FILES)
    scan = report_lines(guest.backup_script("scan", *SCAN_PRIMARIES))
    total_kb = int(scan[0].split()[1])
    candidates = []
    for line in scan[1:]:
        size, path = line[len("@@candidate "):].split("\t", 1)
        candidates.append((path, int(size), category(path)))
    excluded = sorted(p for p, _, c in candidates if c)
    results["scan"] = {"total_kb": total_kb, "candidates": candidates, "excluded": excluded}
    assert "root/.cache" in excluded and "root/.config/Code/CachedData" in excluded
    assert "root/.mozilla/firefox/p.default/cache2" in excluded and "home/alice/.cache" in excluded
    escaped = [p.replace("\\", "\\\\").replace("*", "\\*").replace("?", "\\?").replace("[", "\\[").replace("]", "\\]")
               for p in excluded]

    assert "root/rt/br [x]*/node_modules" in excluded

    # Speed with nothing left out (node_modules and caches included).
    make_backup(guest, [], "zstd", os.path.join(args.out, "linpad-backup-everything.tar"), results, "backup_everything_zstd")
    make_backup(guest, [], "gzip", os.path.join(args.out, "linpad-backup-everything-gzip.tar"), results, "backup_everything_gzip")
    for name in ("linpad-backup-everything.tar", "linpad-backup-everything-gzip.tar"):
        os.remove(os.path.join(args.out, name))

    before = checksums(guest, excluded)
    backup = make_backup(guest, escaped, "zstd", os.path.join(args.out, "linpad-backup-roundtrip.tar"), results, "backup_zstd")
    listing = subprocess.run(["tar", "-tvf", backup], capture_output=True, text=True, check=True).stdout
    results["mac_tar_listing"] = listing.strip().splitlines()
    inner = subprocess.run(f"tar -xOf {shlex.quote(backup)} linux.tar.zst | tar -tf - | wc -l", shell=True,
                           capture_output=True, text=True)
    results["mac_inner_entries"] = inner.stdout.strip() or inner.stderr.strip()

    # Wipe /root and /home, restore (merge), compare.
    guest.sh("rm -rf /root /home && mkdir -m 700 /root && mkdir /home")
    restore(guest, backup, "merge", results, "restore_merge")
    after = checksums(guest, excluded)
    missing = sorted(set(before) - set(after))
    extra = sorted(set(after) - set(before))
    changed = sorted(p for p in before if p in after and before[p] != after[p])
    results["merge_compare"] = {"entries": len(before), "missing": missing, "extra": extra,
                                "changed": [(before[p], after[p]) for p in changed]}
    leaked = [p for p in after if any(p == e or p.startswith(e + "/") for e in excluded)]
    assert not leaked, leaked

    # Replace mode with a gzip backup: local edits are undone, the old tree is moved aside.
    gz = make_backup(guest, escaped, "gzip", os.path.join(args.out, "linpad-backup-roundtrip-gzip.tar"), results, "backup_gzip")
    guest.sh("echo changed > /root/rt/a.txt && echo extra > /root/rt/extra.txt")
    lines = restore(guest, gz, "replace", results, "restore_replace")
    aside = [l.split(" ", 1)[1] for l in lines if l.startswith("@@aside ")][0]
    replaced = checksums(guest, excluded)
    results["replace_compare"] = {
        "a.txt_restored": guest.sh("cat /root/rt/a.txt").strip() == "hello",
        "extra_gone": guest.sh("[ -e /root/rt/extra.txt ] && echo yes || echo no").strip() == "no",
        "extra_kept_aside": guest.sh(f"cat {aside}/root/rt/extra.txt").strip() == "extra",
        "identical_to_backup": sorted(replaced) == sorted(after)
        and all(replaced[p] == after[p] for p in after if not p.startswith("root/rt/a.txt")),
    }

    # Cancel: start an archive, cancel it a moment later, in one guest session.
    work = f"{WORK_ROOT}/{uuid.uuid4()}"
    guest.sh(f"mkdir -p {work} && : > {work}/backup.tar && : > {work}/excludes")
    guest.backup_script("list", work)
    script = guest.script
    cancel_out = guest.sh(f"( set -- archive {work} gzip\n{script} ) > {work}/out & sleep 2; "
                          f"( set -- cancel {work}\n{script} ); wait; cat {work}/out", check=False)
    results["cancel"] = report_lines(cancel_out)
    guest.sh(f"rm -rf {work}")

    with open(os.path.join(args.out, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    ok = (not missing and not extra and not changed and all(results["replace_compare"].values())
          and "@@cancelled" in results["cancel"])
    print(json.dumps({k: v for k, v in results.items() if k not in ("mac_tar_listing", "scan")}, indent=2))
    print("ROUND TRIP", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
