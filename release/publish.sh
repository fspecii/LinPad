#!/bin/bash
# Cuts a LinPad release: the public rootfs, an IPA that SideStore, AltStore and iloader can
# re-sign, checksums, release notes, the GitHub release and the SideStore/AltStore source.
#
#   release/publish.sh VERSION [--dry-run | --publish] [options]
#
#   --dry-run          (default) build nothing, publish nothing: print every step, and
#                      write the release notes, rootfs-manifest.json and source.json that a
#                      publish would produce into the output directory
#   --publish          build what is missing, create the GitHub release v<VERSION> with
#                      `gh release create`, and update release/source.json (commit and push
#                      it afterwards: the source URL serves it from main)
#   --prerelease       mark the GitHub release as a pre-release; source.json is left alone
#                      (SideStore/AltStore sources have no channels)
#   --rootfs FILE      use this rootfs instead of building one (must pass the public check;
#                      FILE.version, from build-rootfs.sh, holds its version stamp)
#   --ipa FILE         use this IPA instead of building one
#   --min-app VERSION  oldest app that may install this Linux system from Settings › Updates
#                      (default: the oldest version listed in release/source.json, so any
#                      LinPad release can; raise it when the rootfs needs new app features)
#   --from REF         release notes from REF (default: the previous v* tag)
#
# Output: release/out/VERSION/ (git-ignored): LinPad-VERSION.ipa,
# linpad-rootfs-VERSION.tar.gz(.sha256), rootfs-manifest.json, RELEASE-NOTES.md, source.json.
# Env: OUT_DIR, BUILD_DIR (default build-ios-publish), REMOTE (git remote of the public repo,
# default linpad). The steps are in release/RELEASING.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
REPO=fspecii/LinPad
RAW=https://raw.githubusercontent.com/$REPO/main
BUNDLE_ID=com.valentinneagu.ish.arm64
APP_GROUP=group.$BUNDLE_ID
MIN_OS=17.0
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
VERSION=
MODE=dry-run
PRERELEASE=
ROOTFS=
IPA=
MIN_APP=
FROM=
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) MODE=dry-run ;;
        --publish) MODE=publish ;;
        --prerelease) PRERELEASE=1 ;;
        --rootfs) ROOTFS=${2:?}; shift ;;
        --ipa) IPA=${2:?}; shift ;;
        --min-app) MIN_APP=${2:?}; shift ;;
        --from) FROM=${2:?}; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option $1" >&2; usage ;;
        *) [ -z "$VERSION" ] || usage; VERSION=$1 ;;
    esac
    shift
done
[ -n "$VERSION" ] || usage
VERSION=${VERSION#v}
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'
[[ $VERSION =~ $SEMVER ]] || { echo "version must look like 1.4.0 or 1.5.0-beta.1, not $VERSION" >&2; exit 2; }
[[ $VERSION != *-* ]] || [ -n "$PRERELEASE" ] || { echo "$VERSION is a pre-release version: add --prerelease" >&2; exit 2; }
TAG=v$VERSION
OUT_DIR=${OUT_DIR:-$HERE/out/$VERSION}
BUILD_DIR=${BUILD_DIR:-$ROOT/build-ios-publish}
REMOTE=${REMOTE:-linpad}
IPA_NAME=LinPad-$VERSION.ipa
ROOTFS_NAME=linpad-rootfs-$VERSION.tar.gz
DRY=; [ "$MODE" = dry-run ] && DRY=1
mkdir -p "$OUT_DIR"
cd "$ROOT"

say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
# Runs a command, or in a dry run shows it.
run() {
    if [ -n "$DRY" ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}
bytes() { stat -f %z "$1"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

say "LinPad $TAG ($MODE) -> $OUT_DIR"

# 1. Preflight --------------------------------------------------------------------------
say "1/7 preflight"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    [ -n "$DRY" ] || { echo "the working tree has uncommitted changes; commit them first" >&2; exit 1; }
    note "warning: uncommitted changes (a publish refuses this)"
fi
HEAD_SHA=$(git rev-parse HEAD)
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [ -n "$DRY" ] || { echo "tag $TAG already exists locally" >&2; exit 1; }
    note "warning: tag $TAG already exists locally"
fi
if command -v gh >/dev/null && gh api "repos/$REPO/releases/tags/$TAG" >/dev/null 2>&1; then
    [ -n "$DRY" ] || { echo "release $TAG already exists on $REPO" >&2; exit 1; }
    note "warning: release $TAG already exists on $REPO"
fi
if [ -z "$DRY" ]; then
    git fetch -q "$REMOTE" main
    git merge-base --is-ancestor "$HEAD_SHA" "$REMOTE/main" ||
        { echo "HEAD ($HEAD_SHA) is not on $REMOTE/main yet; push it first" >&2; exit 1; }
fi
note "commit $HEAD_SHA"

# 2. Rootfs -----------------------------------------------------------------------------
say "2/7 public rootfs"
DEST_ROOTFS=$OUT_DIR/$ROOTFS_NAME
if [ -z "$ROOTFS" ] && [ -f "$DEST_ROOTFS" ]; then ROOTFS=$DEST_ROOTFS; fi
if [ -z "$ROOTFS" ]; then
    note "building it (about an hour; needs network)"
    run env PUBLIC=1 VSCODE=0 OUT="$DEST_ROOTFS" "$HERE/build-rootfs.sh"
    ROOTFS=$DEST_ROOTFS
elif [ "$ROOTFS" != "$DEST_ROOTFS" ]; then
    [ -f "$ROOTFS" ] || { echo "no such rootfs: $ROOTFS" >&2; exit 1; }
    note "reusing $ROOTFS"
    run cp "$ROOTFS" "$DEST_ROOTFS"
    [ ! -f "${ROOTFS%.tar.gz}.version" ] || run cp "${ROOTFS%.tar.gz}.version" "${DEST_ROOTFS%.tar.gz}.version"
fi
SRC_ROOTFS=$ROOTFS; [ -f "$DEST_ROOTFS" ] && SRC_ROOTFS=$DEST_ROOTFS
if [ -f "$SRC_ROOTFS" ]; then
    "$HERE/check-public-rootfs.sh" "$SRC_ROOTFS"
    ROOTFS_VERSION=$(cat "${SRC_ROOTFS%.tar.gz}.version" 2>/dev/null || true)
    [ -n "$ROOTFS_VERSION" ] || ROOTFS_VERSION=$(tar -xzOf "$SRC_ROOTFS" ./usr/share/ish/rootfs-version 2>/dev/null | tr -d '[:space:]')
    [ -n "$ROOTFS_VERSION" ] || { echo "cannot tell the version stamp of $SRC_ROOTFS" >&2; exit 1; }
    ROOTFS_SIZE=$(bytes "$SRC_ROOTFS")
    ROOTFS_SHA=$(sha "$SRC_ROOTFS")
else
    note "(dry run: no rootfs yet, using placeholders)"
    ROOTFS_VERSION=$(date -u +%Y%m%d%H%M)
    ROOTFS_SIZE=0
    ROOTFS_SHA=0000000000000000000000000000000000000000000000000000000000000000
fi
note "version $ROOTFS_VERSION, $((ROOTFS_SIZE / 1048576)) MB, sha256 $ROOTFS_SHA"

# 3. IPA --------------------------------------------------------------------------------
say "3/7 IPA (unsigned build, ad-hoc signature with the app's entitlements)"
DEST_IPA=$OUT_DIR/$IPA_NAME
[ -n "$IPA" ] || { [ ! -f "$DEST_IPA" ] || IPA=$DEST_IPA; }
APP="$BUILD_DIR/Release-iphoneos/iSH ARM64.app"
ENT=$OUT_DIR/entitlements
if [ -z "$IPA" ]; then
    BUILD_NUMBER=$(git rev-list --count HEAD)
    note "building $VERSION ($BUILD_NUMBER): Release, native JIT, virtgpu"
    run xcodebuild -project iSH.xcodeproj -target iSH-ARM64 -configuration Release -sdk iphoneos \
        SYMROOT="$BUILD_DIR" IPHONEOS_DEPLOYMENT_TARGET=$MIN_OS ISH_JIT_BUILD=enabled ISH_VIRTGPU=enabled \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build
    # SideStore and AltStore re-sign with the user's Apple ID and keep these entitlements:
    # the app group, user fonts, and get-task-allow, which StikDebug needs for the JIT.
    mkdir -p "$ENT"
    cat > "$ENT/app.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.user-fonts</key>
	<array><string>app-usage</string></array>
	<key>com.apple.security.application-groups</key>
	<array><string>$APP_GROUP</string></array>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
PLIST
    sed -e '/user-fonts/,/<\/array>/d' -e '/get-task-allow/,/<true\/>/d' "$ENT/app.plist" > "$ENT/extension.plist"
    if [ -z "$DRY" ]; then
        [ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
        find "$APP/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -exec codesign --force --sign - {} \; 2>/dev/null || true
        for ext in "$APP"/PlugIns/*.appex; do
            [ -d "$ext" ] && codesign --force --sign - --entitlements "$ENT/extension.plist" --generate-entitlement-der "$ext"
        done
    fi
    run "$HERE/embed-rootfs.sh" "$APP" "$DEST_ROOTFS"
    run codesign --force --sign - --entitlements "$ENT/app.plist" --generate-entitlement-der "$APP"
    run codesign -v --strict --deep "$APP"
    STAGE=$OUT_DIR/ipa-stage
    run rm -rf "$STAGE"
    run mkdir -p "$STAGE/Payload"
    run ditto "$APP" "$STAGE/Payload/iSH ARM64.app"
    if [ -n "$DRY" ]; then
        printf '    [dry-run] (cd %s && zip -qry -X %s Payload)\n' "$STAGE" "$DEST_IPA"
    else
        rm -f "$DEST_IPA"
        (cd "$STAGE" && zip -qry -X "$DEST_IPA" Payload)
        rm -rf "$STAGE"
    fi
    IPA=$DEST_IPA
elif [ "$IPA" != "$DEST_IPA" ]; then
    [ -f "$IPA" ] || { echo "no such IPA: $IPA" >&2; exit 1; }
    note "reusing $IPA"
    run cp "$IPA" "$DEST_IPA"
fi
SRC_IPA=$IPA; [ -f "$DEST_IPA" ] && SRC_IPA=$DEST_IPA
if [ -f "$SRC_IPA" ]; then
    IPA_SIZE=$(bytes "$SRC_IPA")
    IPA_SHA=$(sha "$SRC_IPA")
    IPA_VERSION=$(unzip -p "$SRC_IPA" 'Payload/*.app/Info.plist' | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null || true)
    [ "$IPA_VERSION" = "$VERSION" ] || {
        [ -n "$DRY" ] || { echo "the IPA says version '$IPA_VERSION', not $VERSION (SideStore rejects that)" >&2; exit 1; }
        note "warning: the IPA says version '$IPA_VERSION', not $VERSION"
    }
else
    note "(dry run: no IPA yet, using placeholders)"
    IPA_SIZE=0
    IPA_SHA=0000000000000000000000000000000000000000000000000000000000000000
fi
note "$IPA_NAME: $((IPA_SIZE / 1048576)) MB, sha256 $IPA_SHA"

# 4. Checksums and manifest -------------------------------------------------------------
say "4/7 checksums and rootfs-manifest.json"
if [ -z "$MIN_APP" ]; then
    MIN_APP=$(python3 - "$HERE/source.json" "$VERSION" <<'PY'
import json, re, sys
path, current = sys.argv[1], sys.argv[2]
def key(v):
    m = re.match(r'(\d+)\.(\d+)\.(\d+)', v)
    return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)
try:
    versions = [v['version'] for v in json.load(open(path))['apps'][0]['versions']]
except (OSError, ValueError, KeyError, IndexError):
    versions = []
print(min(versions + [current], key=key))
PY
)
fi
printf '%s  %s\n' "$ROOTFS_SHA" "$ROOTFS_NAME" > "$OUT_DIR/$ROOTFS_NAME.sha256"
printf '%s  %s\n' "$IPA_SHA" "$IPA_NAME" > "$OUT_DIR/$IPA_NAME.sha256"
python3 - "$OUT_DIR/rootfs-manifest.json" <<PY
import json, sys
json.dump({
    "version": "$ROOTFS_VERSION",
    "release": "$VERSION",
    "file": "$ROOTFS_NAME",
    "size": $ROOTFS_SIZE,
    "sha256": "$ROOTFS_SHA",
    "minAppVersion": "$MIN_APP",
}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
PY
note "minAppVersion $MIN_APP"

# 5. Release notes ----------------------------------------------------------------------
say "5/7 release notes"
if [ -z "$FROM" ]; then
    FROM=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)
    [ "$FROM" != "$TAG" ] || FROM=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2>/dev/null || true)
fi
if [ -n "$FROM" ]; then
    RANGE="$FROM..HEAD"; LIMIT=()
else
    RANGE=HEAD; LIMIT=(-n 30)  # the first release: the latest work, not iSH's whole history
fi
NOTES=$OUT_DIR/RELEASE-NOTES.md
{
    echo "## LinPad $VERSION"
    echo
    echo "### Install or update"
    echo
    echo "- **SideStore / AltStore**: add the source \`$RAW/release/source.json\`; LinPad then updates from there."
    echo "- **iloader, Sideloadly or Xcode**: download \`$IPA_NAME\` below and install it with the same Apple ID as before, which keeps your Linux system and files."
    echo "- **Linux system only**: Settings › Updates downloads \`$ROOTFS_NAME\` ($((ROOTFS_SIZE / 1048576)) MB) and installs it at the next launch; /root, /home and your packages are kept. Needs LinPad $MIN_APP or later."
    echo
    echo "Optional apps such as Visual Studio Code and Claude Code are installed on the iPad from Settings › Apps; they are not part of this release."
    echo
    echo "### Changes${FROM:+ since $FROM}"
    echo
    git log ${LIMIT[@]+"${LIMIT[@]}"} --no-merges --format='- %s (%h)' "$RANGE"
    echo
    echo "### Checksums (SHA-256)"
    echo
    echo '```'
    cat "$OUT_DIR/$IPA_NAME.sha256" "$OUT_DIR/$ROOTFS_NAME.sha256"
    echo '```'
    echo
    echo "Linux system version: \`$ROOTFS_VERSION\`"
} > "$NOTES"
note "$(grep -c '^- .*([0-9a-f]\{7,\})$' "$NOTES" || true) changes${FROM:+ since $FROM}"

# 6. SideStore / AltStore source --------------------------------------------------------
say "6/7 source.json"
SOURCE_OUT=$OUT_DIR/source.json
INFO_PLIST=app/Info.plist
[ -f "$APP/Info.plist" ] && INFO_PLIST="$APP/Info.plist"
python3 - "$HERE/source.json" "$SOURCE_OUT" "$INFO_PLIST" "$NOTES" <<PY
import datetime, json, os, plistlib, re, sys
source_in, source_out, info_path, notes_path = sys.argv[1:5]
raw = "$RAW"
version = "$VERSION"
try:
    source = json.load(open(source_in))
except (OSError, ValueError):
    source = {}
info = plistlib.load(open(info_path, "rb"))
privacy = {k: v for k, v in sorted(info.items()) if k.startswith("NS") and k.endswith("UsageDescription")}
shots = sorted(f for f in os.listdir("docs/screenshots") if f.endswith((".jpg", ".png")))
screenshots = [f"{raw}/docs/screenshots/{f}" for f in shots]
notes = open(notes_path).read()
changes = notes.split("### Changes", 1)[-1].split("### Checksums", 1)[0]
changes = "\n".join(line for line in changes.splitlines()[1:] if line.startswith("- "))[:3500]
date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
entry = {
    "version": version,
    "buildVersion": "$(git rev-list --count HEAD)",
    "date": date,
    "localizedDescription": f"LinPad {version}\n\n{changes}".strip(),
    "downloadURL": f"https://github.com/$REPO/releases/download/$TAG/$IPA_NAME",
    "size": $IPA_SIZE,
    "sha256": "$IPA_SHA",
    "minOSVersion": "$MIN_OS",
}
app = (source.get("apps") or [{}])[0]
versions = [v for v in app.get("versions", []) if v.get("version") != version]
versions.insert(0, entry)
app.update({
    "name": "LinPad",
    "bundleIdentifier": "$BUNDLE_ID",
    "developerName": "LinPad Project",
    "subtitle": "A real Linux desktop on your iPad.",
    "localizedDescription": (
        "LinPad turns an Apple Silicon iPad into a Linux computer: a windowed desktop with tiling and "
        "workspaces, and real Alpine Linux apps (Firefox, Thunar, foot, Node, git) as native windows. "
        "No VM, no jailbreak. Optional apps such as VS Code and Claude Code install from Settings › Apps.\n\n"
        "Fast mode (native JIT) needs StikDebug; the Linux system updates itself from Settings › Updates."),
    "iconURL": f"{raw}/app/Assets.xcassets/AppIcon.appiconset/App%20Store.png",
    "tintColor": "#0A84FF",
    "category": "developer",
    "screenshotURLs": screenshots,
    "screenshots": {"ipad": screenshots},
    "versions": versions,
    "appPermissions": {
        "entitlements": ["com.apple.developer.user-fonts", "com.apple.security.application-groups", "get-task-allow"],
        "privacy": privacy,
    },
})
# Pre-2.0 clients (older SideStore) read the newest version from the app itself.
app.update({k: v for k, v in {
    "version": versions[0]["version"], "versionDate": versions[0]["date"],
    "versionDescription": versions[0]["localizedDescription"], "downloadURL": versions[0]["downloadURL"],
    "size": versions[0]["size"]}.items()})
source.update({
    "name": "LinPad",
    "identifier": "io.github.fspecii.linpad",
    "subtitle": "Linux for iPad",
    "description": "Official source for LinPad releases from github.com/$REPO.",
    "iconURL": app["iconURL"],
    "website": "https://github.com/$REPO",
    "tintColor": "#0A84FF",
    "featuredApps": ["$BUNDLE_ID"],
    "apps": [app],
    "news": source.get("news", []),
})
with open(source_out, "w") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
note "$SOURCE_OUT ($(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['apps'][0]['versions']))" "$SOURCE_OUT") versions)"

# 7. Publish ----------------------------------------------------------------------------
say "7/7 GitHub release"
ASSETS=("$DEST_IPA" "$OUT_DIR/$IPA_NAME.sha256" "$DEST_ROOTFS" "$OUT_DIR/$ROOTFS_NAME.sha256" "$OUT_DIR/rootfs-manifest.json")
run gh release create "$TAG" --repo "$REPO" --target "$HEAD_SHA" --title "LinPad $VERSION" \
    --notes-file "$NOTES" ${PRERELEASE:+--prerelease} ${PRERELEASE:+--latest=false} "${ASSETS[@]}"
if [ -n "$PRERELEASE" ]; then
    note "pre-release: release/source.json unchanged"
elif [ -n "$DRY" ]; then
    note "[dry-run] would copy $SOURCE_OUT to release/source.json"
else
    cp "$SOURCE_OUT" "$HERE/source.json"
    note "release/source.json updated: commit and push it to $REMOTE main, e.g."
    note "  git add release/source.json && git commit -m 'Release $VERSION: source.json' && git push $REMOTE HEAD:main"
fi

say "done"
note "notes:    $NOTES"
note "manifest: $OUT_DIR/rootfs-manifest.json"
note "source:   $SOURCE_OUT"
[ -z "$DRY" ] || note "dry run: nothing was built, uploaded or committed. Publish with: release/publish.sh $VERSION --publish"
