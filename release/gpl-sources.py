#!/usr/bin/env python3
"""Corresponding-source manifest for a public LinPad rootfs (GPL/LGPL compliance).

Lists every component the image redistributes and where its exact source lives:
  - Alpine packages (from the image's apk database): the aports commit that built each
    package, with permalinks to its APKBUILD directory and a source archive of it;
  - Debian/Ubuntu theme packages unpacked by themes/guest/install.sh: their source
    package on snapshot.debian.org / Launchpad;
  - GitHub themes and icon packs at their pinned refs (themes/guest/versions.sh,
    themes/guest/ish-icon-packs);
  - VLC, whose Wayland plugin LinPad compiles from VLC's sources;
  - LinPad itself (ishwl, the audio and VLC shims, the theme and release scripts) at the
    release tag, also attached to the release as a tarball.

  release/gpl-sources.py --rootfs ROOTFS.tar.gz --release 1.4.0 --out DIR \
      [--apkindex DIR] [--repo fspecii/LinPad] [--source-tarball NAME]

--apkindex points at a directory of APKINDEX.tar.gz files named <branch>-<repo>.tar.gz
(e.g. v3.21-main.tar.gz, edge-community.tar.gz); without it the main/community repository
of each package is unknown and the links point at the aports commit instead.
Writes DIR/sources-manifest.json and DIR/SOURCES.md.
"""
import argparse
import json
import os
import re
import sys
import tarfile

APORTS = "https://gitlab.alpinelinux.org/alpine/aports"

# themes/guest/install.sh: versions.sh variable -> (GitHub repo, install stamp(s)).
GITHUB_THEMES = [
    ("WHITESUR_GTK_REF", "vinceliuice/WhiteSur-gtk-theme", ["whitesur-gtk"]),
    ("WHITESUR_ICONS_REF", "vinceliuice/WhiteSur-icon-theme", ["whitesur-icons"]),
    ("WHITESUR_CURSORS_REF", "vinceliuice/WhiteSur-cursors", ["whitesur-cursors"]),
    ("WHITESUR_KDE_REF", "vinceliuice/WhiteSur-kde", ["whitesur-kvantum"]),
    ("FLUENT_GTK_REF", "vinceliuice/Fluent-gtk-theme", ["fluent-gtk"]),
    ("FLUENT_ICONS_REF", "vinceliuice/Fluent-icon-theme", ["fluent-icons", "fluent-cursors"]),
    ("FLUENT_KDE_REF", "vinceliuice/Fluent-kde", ["fluent-kvantum"]),
    ("KVANTUM_REF", "tsujan/Kvantum", ["kvantum-ukui", "kvantum-themes"]),
]


def parse_apk_db(text):
    """Blocks of `K:value` lines separated by blank lines (lib/apk/db/installed, APKINDEX)."""
    packages, block = [], {}
    for line in text.splitlines() + [""]:
        if not line.strip():
            if block.get("P"):
                packages.append(block)
            block = {}
        elif len(line) > 2 and line[1] == ":":
            block.setdefault(line[0], line[2:])
    return packages


def parse_shell_vars(text):
    values = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
        if m:
            values[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return values


def parse_icon_packs(text, wanted):
    """`id|name|source|ref|sha256|dirs|MB|licence` rows of ish-icon-packs for the ids in `wanted`."""
    packs = []
    for line in text.splitlines():
        m = re.match(r"^#?\s*([a-z0-9-]+)\|([^|]+)\|github:([^|]+)\|([^|]+)\|([0-9a-f]{64})\|[^|]*\|[^|]*\|([^|]+)$", line.strip())
        if m and m.group(1) in wanted:
            packs.append({"id": m.group(1), "name": m.group(2), "repo": m.group(3), "ref": m.group(4),
                          "sha256": m.group(5), "license": m.group(6)})
    return packs


def load_apkindexes(directory):
    """origin -> "main" | "community" (first index wins), from <branch>-<repo>.tar.gz files."""
    repos = {}
    if not directory or not os.path.isdir(directory):
        return repos
    # Release branches first: a package that moved repository in edge keeps its branch's.
    for name in sorted(os.listdir(directory), key=lambda n: (n.startswith("edge-"), n)):
        m = re.match(r"^(.+)-(main|community|testing)\.tar\.gz$", name)
        if not m:
            continue
        with tarfile.open(os.path.join(directory, name)) as tar:
            member = tar.extractfile("APKINDEX")
            if member is None:
                continue
            for pkg in parse_apk_db(member.read().decode("utf-8", "replace")):
                origin = pkg.get("o") or pkg["P"]
                repos.setdefault(origin, m.group(2))
    return repos


def alpine_sources(installed, repos):
    """One entry per origin (source package), with the binary packages built from it."""
    origins = {}
    for pkg in installed:
        name = pkg["P"]
        if name.startswith("."):  # virtual packages (apk add --virtual) have no source
            continue
        origin = pkg.get("o") or name
        commit = pkg.get("c", "")
        entry = origins.setdefault((origin, pkg.get("V", ""), commit), {
            "kind": "alpine",
            "origin": origin,
            "version": pkg.get("V", ""),
            "license": pkg.get("L", ""),
            "commit": commit,
            "packages": [],
        })
        entry["packages"].append(name)
    result = []
    for entry in sorted(origins.values(), key=lambda e: (e["origin"], e["version"])):
        repo = repos.get(entry["origin"])
        commit = entry["commit"]
        entry["repository"] = repo
        if commit and repo:
            entry["aports"] = f"{APORTS}/-/tree/{commit}/{repo}/{entry['origin']}"
            entry["archive"] = f"{APORTS}/-/archive/{commit}/aports-{commit}.tar.gz?path={repo}/{entry['origin']}"
        elif commit:
            entry["aports"] = f"{APORTS}/-/commit/{commit}"
            entry["archive"] = f"{APORTS}/-/archive/{commit}/aports-{commit}.tar.gz"
        else:
            entry["aports"] = None
            entry["archive"] = None
        entry["packages"].sort()
        result.append(entry)
    return result


def theme_sources(versions, stamps):
    def present(names):
        return stamps is None or any(n in stamps for n in names)

    result = []
    if versions.get("UKUI_THEMES_VERSION") and present(["ukui"]):
        v = versions["UKUI_THEMES_VERSION"]
        result.append({"kind": "debian", "name": "ukui-themes", "version": v, "license": "GPL-2.0-or-later and others",
                       "source": f"https://snapshot.debian.org/package/ukui-themes/{v}/",
                       "packages": ["ukui-gtk-theme", "ukui-icons-theme"]})
    if versions.get("YARU_VERSION") and present(["yaru"]):
        v = versions["YARU_VERSION"]
        result.append({"kind": "ubuntu", "name": "yaru-theme", "version": v, "license": "GPL-3.0, CC-BY-SA-4.0",
                       "source": f"https://launchpad.net/ubuntu/+source/yaru-theme/{v}",
                       "packages": ["yaru-theme-gtk", "yaru-theme-icon"]})
    for var, repo, names in GITHUB_THEMES:
        ref = versions.get(var)
        if ref and present(names):
            result.append({"kind": "github", "name": repo.split("/")[1], "version": ref,
                           "source": f"https://github.com/{repo}/tree/{ref}",
                           "archive": f"https://codeload.github.com/{repo}/tar.gz/{ref}", "packages": names})
    if versions.get("VLC_REF"):
        ref = versions["VLC_REF"]
        result.append({"kind": "github", "name": "vlc", "version": ref, "license": "GPL-2.0-or-later / LGPL-2.1-or-later",
                       "source": f"https://code.videolan.org/videolan/vlc/-/tree/{ref}",
                       "archive": f"https://download.videolan.org/pub/videolan/vlc/{ref}/vlc-{ref}.tar.xz",
                       "packages": ["VLC Wayland output plugins (modules/video_output/wayland), built by themes/guest/vlc/build-vlc-wayland.sh"]})
    return result


def icon_pack_sources(packs):
    return [{"kind": "github", "name": p["name"], "version": p["ref"], "license": p["license"],
             "source": f"https://github.com/{p['repo']}/tree/{p['ref']}",
             "archive": f"https://codeload.github.com/{p['repo']}/tar.gz/{p['ref']}",
             "sha256": p["sha256"], "packages": [p["id"]]} for p in packs]


def linpad_source(project, release, tarball):
    tag = f"v{release}"
    entry = {"kind": "linpad", "name": "LinPad", "version": release, "license": "GPL-3.0",
             "source": f"https://github.com/{project}/tree/{tag}",
             "archive": f"https://github.com/{project}/archive/refs/tags/{tag}.tar.gz",
             "packages": ["ishwl (wl-bridge/)", "ishaudio (themes/guest/audio/)",
                          "VLC compat shims and the vlc-qt patch (themes/guest/vlc/)",
                          "theme, icon pack and release scripts (themes/, release/)", "the app and emulator"]}
    if tarball:
        entry["attached"] = f"https://github.com/{project}/releases/download/{tag}/{tarball}"
    return entry


def build_manifest(installed_text, versions_text, icon_packs_text, stamps, repos, release, project, tarball):
    versions = parse_shell_vars(versions_text or "")
    base = set((versions.get("BASE_ICON_PACKS") or "").split())
    return {
        "release": release,
        "linpad": linpad_source(project, release, tarball),
        "alpine": alpine_sources(parse_apk_db(installed_text), repos),
        "themes": theme_sources(versions, stamps),
        "iconPacks": icon_pack_sources(parse_icon_packs(icon_packs_text or "", base)),
    }


def render_markdown(manifest, project):
    release = manifest["release"]
    lines = [
        f"# Corresponding source for LinPad {release}",
        "",
        "LinPad is GPLv3, and its Linux system redistributes free software under the GPL, LGPL and",
        "other licences. This file lists where the exact source of every component of the release's",
        "rootfs lives. `sources-manifest.json` has the same data for tools.",
        "",
        "**Written offer.** For at least three years after this release, the LinPad maintainers will",
        "provide the complete corresponding source of any GPL- or LGPL-licensed component listed here,",
        "for no more than the cost of distribution, to anyone who asks. Ask by opening an issue at",
        f"https://github.com/{project}/issues with the title \"Source request {release}\".",
        "",
        "## LinPad",
        "",
    ]
    lp = manifest["linpad"]
    lines.append(f"- Tag `v{release}`: {lp['source']} ({lp['archive']})")
    if lp.get("attached"):
        lines.append(f"- Attached to the release: {lp['attached']}")
    lines.append("- Contains: " + "; ".join(lp["packages"]))
    lines += ["", "## Themes, icon packs and VLC", "", "| Component | Version | Source |", "|---|---|---|"]
    for e in manifest["themes"] + manifest["iconPacks"]:
        lines.append(f"| {e['name']} | `{e['version']}` | {e['source']} |")
    alpine = manifest["alpine"]
    lines += ["", f"## Alpine Linux packages ({sum(len(e['packages']) for e in alpine)} packages from {len(alpine)} source packages)", "",
              "Each package was built by Alpine from the APKBUILD at the aports commit shown. The APKBUILD lists",
              "the upstream source URLs and checksums, and Alpine's patches sit next to it.", "",
              "| Source package | Version | Licence | Binary packages | aports |", "|---|---|---|---|---|"]
    for e in alpine:
        link = f"[{e['commit'][:10]}]({e['aports']})" if e.get("aports") else "—"
        lines.append(f"| {e['origin']} | `{e['version']}` | {e['license'] or '—'} | {', '.join(e['packages'])} | {link} |")
    lines.append("")
    return "\n".join(lines)


def read_from_rootfs(path):
    installed, stamps = "", set()
    with tarfile.open(path) as tar:
        for member in tar:
            name = member.name[2:] if member.name.startswith("./") else member.name
            if name == "lib/apk/db/installed":
                installed = tar.extractfile(member).read().decode("utf-8", "replace")
            elif name.startswith("usr/share/ish/themes/.installed/") and member.isfile():
                stamps.add(os.path.basename(name))
    return installed, stamps


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--rootfs")
    source.add_argument("--installed", help="an apk installed database instead of a rootfs")
    p.add_argument("--release", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--apkindex")
    p.add_argument("--repo", default="fspecii/LinPad")
    p.add_argument("--source-tarball")
    p.add_argument("--versions", default=os.path.join(root, "themes/guest/versions.sh"))
    p.add_argument("--icon-packs", default=os.path.join(root, "themes/guest/ish-icon-packs"))
    args = p.parse_args(argv)

    if args.rootfs:
        installed, stamps = read_from_rootfs(args.rootfs)
    else:
        installed, stamps = open(args.installed, encoding="utf-8").read(), None
    if not installed:
        sys.exit("gpl-sources: no apk database (lib/apk/db/installed) in the input")
    read = lambda path: open(path, encoding="utf-8").read() if path and os.path.exists(path) else ""
    manifest = build_manifest(installed, read(args.versions), read(args.icon_packs), stamps,
                              load_apkindexes(args.apkindex), args.release, args.repo, args.source_tarball)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "sources-manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    with open(os.path.join(args.out, "SOURCES.md"), "w") as f:
        f.write(render_markdown(manifest, args.repo))
    unresolved = sum(1 for e in manifest["alpine"] if not e.get("repository"))
    print(f"gpl-sources: {len(manifest['alpine'])} Alpine source packages "
          f"({unresolved} without a known repository), {len(manifest['themes']) + len(manifest['iconPacks'])} others")


if __name__ == "__main__":
    main()
