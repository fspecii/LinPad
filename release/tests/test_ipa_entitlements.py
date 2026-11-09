"""Exercise archive selection and the release guard without invoking a release."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]


def write_ipa(path, executable="LinPad", main=b"allow", extension=False):
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/LinPad.app/Info.plist", plistlib.dumps({
            "CFBundleExecutable": executable, "CFBundleShortVersionString": "9.9.9",
        }))
        archive.writestr("Payload/LinPad.app/LinPad", main)
        if extension:
            archive.writestr("Payload/LinPad.app/PlugIns/Files.appex/Files", b"allow")


class IpaEntitlementsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.fixture = Path(self.directory.name)
        tools = self.fixture / "bin"
        tools.mkdir()
        # Only the platform signing reader is a double; archive/guard code is real.
        reader = tools / "xcrun"
        reader.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nimport sys\n"
                          "sys.exit(0 if Path(sys.argv[-1]).read_bytes() == b'allow' else 1)\n")
        reader.chmod(0o755)
        self.env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"]}

    def test_only_the_main_app_can_satisfy_the_request(self):
        for label, main, extension, valid in (
            ("compliant", b"allow", False, True),
            ("legacy", b"reject", False, False),
            ("extension-only", b"reject", True, False),
        ):
            with self.subTest(label=label):
                ipa = self.fixture / (label + ".ipa")
                write_ipa(ipa, main=main, extension=extension)
                result = subprocess.run(["python3", str(ROOT / "release/check-ipa-entitlements.py"), str(ipa)],
                                        env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, valid, result.stderr)
                if not valid:
                    self.assertIn("rebuild the IPA", result.stderr)

    def test_unsafe_executable_and_unreadable_archives_are_rejected(self):
        ipa = self.fixture / "invalid.ipa"
        write_ipa(ipa, executable="../outside")
        for label in ("unsafe-name", "unreadable-archive"):
            with self.subTest(label=label):
                if label == "unreadable-archive":
                    ipa.write_bytes(b"not a zip archive")
                result = subprocess.run(["python3", str(ROOT / "release/check-ipa-entitlements.py"), str(ipa)],
                                        env=self.env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("rebuild the IPA", result.stderr)

    def test_explicit_cached_and_missing_ipa_paths_use_the_final_guard(self):
        publish = (ROOT / "release/publish.sh").read_text()
        start = publish.index("SRC_IPA=$IPA;")
        end = publish.index('    IPA_SIZE=$(bytes "$SRC_IPA")', start)
        guard = publish[start:end] + 'fi\nprintf "AFTER_GUARD\\n"\n'
        for cached in (False, True):
            for valid in (False, True):
                with self.subTest(cached=cached, valid=valid):
                    ipa = self.fixture / "selected.ipa"
                    write_ipa(ipa, main=b"allow" if valid else b"reject")
                    env = {**self.env, "HERE": str(ROOT / "release"),
                           "IPA": "" if cached else str(ipa),
                           "DEST_IPA": str(ipa) if cached else str(self.fixture / "absent.ipa")}
                    result = subprocess.run(["bash", "-euc", guard], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)
                    self.assertEqual("AFTER_GUARD" in result.stdout, valid)
        result = subprocess.run(["bash", "-euc", guard], capture_output=True, text=True,
                                env={**self.env, "HERE": str(ROOT / "release"), "IPA": "",
                                     "DEST_IPA": str(self.fixture / "absent.ipa")})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("AFTER_GUARD", result.stdout)
