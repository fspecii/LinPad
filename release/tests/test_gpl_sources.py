"""Tests for release/gpl-sources.py:  python3 -m unittest discover -s release/tests"""
import importlib.util
import io
import json
import os
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gpl_sources", os.path.join(HERE, "..", "gpl-sources.py"))
gpl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpl)

INSTALLED = """C:Q1abc=
P:musl
V:1.2.5-r9
A:aarch64
L:MIT
o:musl
c:3e6a5bd5aa0b1d7d1d9f7c4c1e0a3f8b2c6d7e8f

P:busybox
V:1.37.0-r12
L:GPL-2.0-only
o:busybox
c:0123456789abcdef0123456789abcdef01234567

P:busybox-binsh
V:1.37.0-r12
L:GPL-2.0-only
o:busybox
c:0123456789abcdef0123456789abcdef01234567

P:mesa-vulkan-virtio
V:26.2.3-r0
L:MIT AND SGI-B-2.0 AND BSL-1.0
o:mesa
c:fedcba9876543210fedcba9876543210fedcba98

P:.ishwl-build
V:20261002.120000
"""

VERSIONS = """# pins
WHITESUR_GTK_REF=2026-09-10
KVANTUM_REF=V1.1.3
VLC_REF=3.0.21
UKUI_THEMES_VERSION=4.0.0.1-1
YARU_VERSION=24.04.2-0ubuntu1
BASE_ICON_PACKS="adwaita papirus kora"
"""

ICON_PACKS = """# id|display name|source|ref|sha256|theme dirs|approx. MB|licence
kora|Kora|github:bikass/kora|v2.0.6|159bdb7a09409a12e54a71136ec8889c51b0bf7c145c8b20e3509dc1e90089bd|kora kora-pgrey|27|GPL-3.0
candy|Candy|github:EliverLara/candy-icons|83512fbcadcb7e1015ebbe1729a1894946b021be|1de25126c50da4edf4b49623993c1ca5f626d5be1020e5bd1b1c683cd724721b|candy-icons|7|GPL-3.0
papirus|Papirus|apk:papirus-icon-theme||||40|GPL-3.0
"""


def write_apkindex(directory, name, text):
    data = text.encode()
    with tarfile.open(os.path.join(directory, name), "w:gz") as tar:
        info = tarfile.TarInfo("APKINDEX")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))


class GplSourcesTests(unittest.TestCase):
    def test_parses_the_apk_database(self):
        packages = gpl.parse_apk_db(INSTALLED)
        self.assertEqual([p["P"] for p in packages], ["musl", "busybox", "busybox-binsh", "mesa-vulkan-virtio", ".ishwl-build"])
        self.assertEqual(packages[0]["c"], "3e6a5bd5aa0b1d7d1d9f7c4c1e0a3f8b2c6d7e8f")

    def test_groups_by_origin_and_links_the_aports_commit(self):
        repos = {"busybox": "main", "musl": "main", "mesa": "main"}
        sources = gpl.alpine_sources(gpl.parse_apk_db(INSTALLED), repos)
        self.assertEqual([s["origin"] for s in sources], ["busybox", "mesa", "musl"], "virtual packages are skipped")
        busybox = sources[0]
        self.assertEqual(busybox["packages"], ["busybox", "busybox-binsh"])
        self.assertEqual(busybox["license"], "GPL-2.0-only")
        self.assertEqual(busybox["aports"],
                         "https://gitlab.alpinelinux.org/alpine/aports/-/tree/0123456789abcdef0123456789abcdef01234567/main/busybox")
        self.assertTrue(busybox["archive"].endswith("aports-0123456789abcdef0123456789abcdef01234567.tar.gz?path=main/busybox"))

    def test_unknown_repository_falls_back_to_the_commit(self):
        sources = gpl.alpine_sources(gpl.parse_apk_db(INSTALLED), {})
        self.assertIsNone(sources[0]["repository"])
        self.assertEqual(sources[0]["aports"],
                         "https://gitlab.alpinelinux.org/alpine/aports/-/commit/0123456789abcdef0123456789abcdef01234567")

    def test_apkindex_resolves_repositories(self):
        with tempfile.TemporaryDirectory() as d:
            write_apkindex(d, "v3.21-main.tar.gz", "P:busybox\nV:1.37.0-r12\no:busybox\n\nP:musl\nV:1.2.5-r9\n")
            write_apkindex(d, "edge-main.tar.gz", "P:mesa-vulkan-virtio\nV:26.2.3-r0\no:mesa\n")
            write_apkindex(d, "v3.21-community.tar.gz", "P:firefox-esr\nV:128\no:firefox-esr\n")
            repos = gpl.load_apkindexes(d)
        self.assertEqual(repos, {"busybox": "main", "musl": "main", "mesa": "main", "firefox-esr": "community"})

    def test_themes_icon_packs_and_linpad(self):
        manifest = gpl.build_manifest(INSTALLED, VERSIONS, ICON_PACKS, {"whitesur-gtk", "ukui"}, {}, "1.4.0",
                                      "fspecii/LinPad", "linpad-source-1.4.0.tar.gz")
        names = [t["name"] for t in manifest["themes"]]
        self.assertIn("ukui-themes", names)
        self.assertIn("WhiteSur-gtk-theme", names)
        self.assertIn("vlc", names, "the VLC Wayland plugin is compiled from VLC's sources")
        self.assertNotIn("yaru-theme", names, "not installed in this image")
        self.assertNotIn("Kvantum", names)
        ukui = next(t for t in manifest["themes"] if t["name"] == "ukui-themes")
        self.assertEqual(ukui["source"], "https://snapshot.debian.org/package/ukui-themes/4.0.0.1-1/")
        self.assertEqual([p["name"] for p in manifest["iconPacks"]], ["Kora"], "GitHub packs in BASE_ICON_PACKS only")
        self.assertEqual(manifest["iconPacks"][0]["archive"], "https://codeload.github.com/bikass/kora/tar.gz/v2.0.6")
        self.assertEqual(manifest["linpad"]["source"], "https://github.com/fspecii/LinPad/tree/v1.4.0")
        self.assertEqual(manifest["linpad"]["attached"],
                         "https://github.com/fspecii/LinPad/releases/download/v1.4.0/linpad-source-1.4.0.tar.gz")
        json.dumps(manifest)

    def test_markdown_has_the_offer_and_every_package(self):
        manifest = gpl.build_manifest(INSTALLED, VERSIONS, ICON_PACKS, None, {"busybox": "main"}, "1.4.0", "fspecii/LinPad", None)
        text = gpl.render_markdown(manifest, "fspecii/LinPad")
        self.assertIn("Written offer", text)
        self.assertIn("Source request 1.4.0", text)
        for name in ["busybox, busybox-binsh", "mesa-vulkan-virtio", "musl", "yaru-theme", "Kora"]:
            self.assertIn(name, text)
        self.assertIn("4 packages from 3 source packages", text)

    def test_command_line_with_a_rootfs(self):
        with tempfile.TemporaryDirectory() as d:
            rootfs = os.path.join(d, "rootfs.tar.gz")
            with tarfile.open(rootfs, "w:gz") as tar:
                for name, text in [("./lib/apk/db/installed", INSTALLED), ("./usr/share/ish/themes/.installed/yaru", "x\n")]:
                    data = text.encode()
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
            versions = os.path.join(d, "versions.sh")
            with open(versions, "w") as f:
                f.write(VERSIONS)
            out = os.path.join(d, "out")
            gpl.main(["--rootfs", rootfs, "--release", "1.4.0", "--out", out, "--versions", versions,
                      "--icon-packs", os.path.join(d, "missing")])
            with open(os.path.join(out, "sources-manifest.json")) as f:
                manifest = json.load(f)
            self.assertEqual(len(manifest["alpine"]), 3)
            self.assertEqual([t["name"] for t in manifest["themes"]], ["yaru-theme", "vlc"])
            self.assertTrue(os.path.exists(os.path.join(out, "SOURCES.md")))


if __name__ == "__main__":
    unittest.main()
