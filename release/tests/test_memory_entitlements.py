"""Check entitlement packaging without building, signing or publishing a release."""
import json
import os
from pathlib import Path
import plistlib
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
        start = publish.index('python3 - "$HERE/source.json" "$SOURCE_OUT" "$INFO_PLIST" "$NOTES" <<PY\n')
        end = publish.index("\nPY\n", start) + len("\nPY\n")
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            (fixture / "docs/screenshots").mkdir(parents=True)
            (fixture / "source.json").write_text("{}")
            (fixture / "notes.md").write_text("### Changes\n- Fixture release\n")
            with (fixture / "Info.plist").open("wb") as source:
                plistlib.dump({}, source)
            # Isolate the commit-count input; execute the metadata writer unchanged.
            subprocess.run(
                ["bash", "-euc", "git() { printf '1\\n'; }\n" + publish[start:end]],
                check=True, cwd=fixture,
                env={**os.environ,
                     "HERE": directory, "SOURCE_OUT": str(fixture / "generated.json"),
                     "INFO_PLIST": str(fixture / "Info.plist"), "NOTES": str(fixture / "notes.md"),
                     "RAW": "https://example.invalid/main", "VERSION": "9.9.9",
                     "REPO": "example/linpad", "TAG": "v9.9.9", "IPA_NAME": "fixture.ipa",
                     "IPA_SIZE": "1", "IPA_SHA": "a" * 64, "MIN_OS": "16.0",
                     "BUNDLE_ID": "com.example.linpad"},
            )
            generated = json.loads((fixture / "generated.json").read_text())
        self.assertIn(KEY, generated["apps"][0]["appPermissions"]["entitlements"])
