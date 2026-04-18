#!/usr/bin/env python3
"""Create a fakefs meta.db from an existing rootfs directory.

Usage:
    python3 create_fakefs.py <rootfs_dir> <output_dir>

Example:
    # Download Alpine x86 minirootfs
    mkdir -p alpine-x86-fakefs/data
    tar xzf alpine-minirootfs-3.21.0-x86.tar.gz -C alpine-x86-fakefs/data

    # Create meta.db
    python3 benchmark/create_fakefs.py alpine-x86-fakefs/data alpine-x86-fakefs

The meta.db stores path→inode mappings and inode→stat blobs for fakefs.

IMPORTANT: fakefs stores root "/" as empty blob b"", not b"/".
All other paths keep the leading slash: "/bin", "/etc/os-release", etc.
This matches fix_path() in fs/fix_path.h which strips leading "/" for
host filesystem access.
"""

import sqlite3
import struct
import os
import sys


def create_fakefs(data_dir: str, output_dir: str) -> None:
    db_path = os.path.join(output_dir, "meta.db")

    # Remove stale WAL files
    for suffix in ("", "-shm", "-wal"):
        path = db_path + suffix
        if os.path.exists(path):
            os.remove(path)

    db = sqlite3.connect(db_path)
    db.execute("CREATE TABLE meta (id integer unique default 0, db_inode integer)")
    db.execute("CREATE TABLE stats (inode integer primary key, stat blob)")
    db.execute("CREATE TABLE paths (path blob primary key, inode integer references stats(inode))")
    db.execute("CREATE INDEX inode_to_path on paths (inode, path)")
    db.execute("PRAGMA user_version = 3")

    # Store db_inode for fakefs rebuild detection
    db_inode = os.stat(db_path).st_ino
    db.execute("INSERT INTO meta (id, db_inode) VALUES (0, ?)", (db_inode,))

    count = 0
    for dirpath, dirnames, filenames in os.walk(data_dir):
        entries = [""] + dirnames + filenames
        for name in entries:
            fullpath = os.path.join(dirpath, name) if name else dirpath
            relpath = os.path.relpath(fullpath, data_dir)

            # fakefs path encoding: "/" → "" (empty blob), "/bin" → "/bin"
            if relpath == ".":
                guest_path = ""
            else:
                guest_path = "/" + relpath

            try:
                st = os.lstat(fullpath)
            except OSError:
                continue

            # struct ish_stat: mode(u32) uid(u32) gid(u32) rdev(u32) = 16 bytes
            stat_blob = struct.pack("<IIII", st.st_mode, 0, 0, 0)

            db.execute(
                "INSERT OR IGNORE INTO stats (inode, stat) VALUES (?, ?)",
                (st.st_ino, stat_blob),
            )
            db.execute(
                "INSERT OR REPLACE INTO paths (path, inode) VALUES (?, ?)",
                (guest_path.encode("utf-8"), st.st_ino),
            )
            count += 1

    db.commit()

    # Verify root entry exists
    root = db.execute("SELECT inode FROM paths WHERE path = X''").fetchone()
    if not root:
        print("ERROR: root entry missing in meta.db", file=sys.stderr)
        sys.exit(1)

    print(f"Created {db_path}: {count} entries, root inode={root[0]}")
    db.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <rootfs_data_dir> <fakefs_output_dir>")
        sys.exit(1)

    data_dir = sys.argv[1]
    output_dir = sys.argv[2]

    if not os.path.isdir(data_dir):
        print(f"ERROR: {data_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)
    create_fakefs(data_dir, output_dir)
