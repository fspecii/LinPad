"""Require the increased-memory request in the selected IPA's main executable."""
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


def check_ipa(path):
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory() as directory:
        apps = [name for name in archive.namelist()
                if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(apps) != 1:
            raise ValueError("expected one main app")
        info = plistlib.loads(archive.read(apps[0]))
        executable = info.get("CFBundleExecutable") if isinstance(info, dict) else None
        if not isinstance(executable, str) or executable in ("", ".", "..") or "/" in executable or "\\" in executable:
            raise ValueError("invalid main-app executable name")
        target = Path(directory) / "executable"
        with archive.open(apps[0].rsplit("/", 1)[0] + "/" + executable) as source, target.open("wb") as output:
            shutil.copyfileobj(source, output)
        result = subprocess.run(["xcrun", "swift", str(Path(__file__).with_suffix(".swift")), str(target)],
                                capture_output=True)
        if result.returncode:
            raise ValueError("could not verify the main app's increased-memory entitlement is true")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-ipa-entitlements.py APP.ipa")
    try:
        check_ipa(sys.argv[1])
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(f"{error}; rebuild the IPA with Increased Memory Limit before publishing")
