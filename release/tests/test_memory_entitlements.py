"""Check entitlement packaging without building, signing or publishing a release."""
import ast
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
KEY = "com.apple.developer.kernel.increased-memory-limit"


class MemoryEntitlementsTests(unittest.TestCase):
    def test_source_app_requests_increased_memory(self):
        with (ROOT / "app/iSH.entitlements").open("rb") as source:
            self.assertIs(plistlib.load(source)[KEY], True)

    def test_release_app_keeps_request_and_extension_only_keeps_app_group(self):
        publish = (ROOT / "release/publish.sh").read_text()
        start = publish.index('    cat > "$ENT/app.plist" <<PLIST\n')
        end = publish.index('    if [ -z "$DRY" ]; then', start)
        # Execute only the existing plist-generation block, never the publisher.
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(
                ["bash", "-euc", publish[start:end]], check=True,
                env={**os.environ, "ENT": directory, "APP_GROUP": "group.example.linpad"},
            )
            with (Path(directory) / "app.plist").open("rb") as source:
                app = plistlib.load(source)
            with (Path(directory) / "extension.plist").open("rb") as source:
                extension = plistlib.load(source)
        self.assertIs(app[KEY], True)
        self.assertIs(app["get-task-allow"], True)
        self.assertEqual(app["com.apple.developer.user-fonts"], ["app-usage"])
        self.assertEqual(extension, {
            "com.apple.security.application-groups": ["group.example.linpad"],
        })

    def test_sideload_source_declares_requested_permission(self):
        publish = (ROOT / "release/publish.sh").read_text()
        permissions = re.findall(r'"entitlements": (\[[^\n]+\])', publish)
        self.assertEqual(len(permissions), 1)
        self.assertIn(KEY, ast.literal_eval(permissions[0]))
