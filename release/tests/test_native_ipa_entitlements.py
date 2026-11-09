"""Exercise the real macOS signing reader with temporary ad-hoc signed binaries."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_ipa_entitlements import write_ipa


ROOT = Path(__file__).resolve().parents[2]
KEY = "com.apple.developer.kernel.increased-memory-limit"


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS signing tools")
class NativeIpaEntitlementsTests(unittest.TestCase):
    def test_signed_main_executable_requires_true_memory_entitlement(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for label, entitlements, valid in (
                ("true", {KEY: True}, True),
                ("missing", {}, False),
                ("false", {KEY: False}, False),
            ):
                with self.subTest(label=label):
                    binary = fixture / label
                    shutil.copyfile("/usr/bin/true", binary)
                    binary.chmod(0o755)
                    plist = fixture / (label + ".plist")
                    with plist.open("wb") as output:
                        plistlib.dump(entitlements, output)
                    signed = subprocess.run(
                        ["codesign", "--force", "--sign", "-", "--entitlements", str(plist),
                         "--generate-entitlement-der", str(binary)], capture_output=True, text=True,
                    )
                    self.assertEqual(signed.returncode, 0, signed.stderr)
                    ipa = fixture / (label + ".ipa")
                    write_ipa(ipa, main=binary.read_bytes())
                    result = subprocess.run(
                        [sys.executable, str(ROOT / "release/check-ipa-entitlements.py"), str(ipa)],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode == 0, valid, result.stderr)
                    if not valid:
                        self.assertIn("rebuild the IPA", result.stderr)
