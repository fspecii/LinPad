#!/usr/bin/env python3
"""Builds LinPad's internet-radio playlist for VLC from the community Radio Browser
directory (https://www.radio-browser.info, https://api.radio-browser.info):

    release/build-radio-playlist.py [--no-probe]

Writes release/guest/linpad/packs/radio/linpad-radio.xspf. The stations are curated below
by Radio Browser station UUID, grouped as VLC playlist folders. For each one the script
reads the directory's current record (stream URL, homepage, codec, bitrate, votes), keeps
only stations the directory has checked as working (lastcheckok=1), takes their HTTPS
stream (upgrading an http:// one when the same stream is served over TLS) and, unless
--no-probe, fetches the first bytes of every stream to be sure it answers with audio.
A station that fails is reported and left out; run it again before a release.
"""
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape

API = "https://de1.api.radio-browser.info/json/stations/byuuid/"
USER_AGENT = "LinPad/1.0 (radio playlist build)"
# Several Icecast servers (SomaFM, WALM) refuse curl's default user agent.
PROBE_AGENT = "VLC/3.0.21 LibVLC/3.0.21"
OUT = Path(__file__).resolve().parent / "guest/linpad/packs/radio/linpad-radio.xspf"

# (folder, Radio Browser station UUID, display name or None, stream URL override or None)
# Left out after testing in VLC 3.0.21 under LinPad: Nightwave Plaza and Radio Swiss
# Classic, whose streams stop after the first second or two in VLC.
STATIONS = [
    ("News", "598c4d0e-6b06-43fb-bff4-717c591213a9", "BBC World Service", None),
    ("News", "1c3e8be2-5b14-4933-bad3-87cbc227cba4", "Deutschlandfunk", None),
    ("News", "dfcef843-6bf9-40f6-b3fe-2b224df86e48", "Europe 1", None),
    ("News", "33178054-56cd-449c-8cf7-412cc7be936a", "CNN (audio)", None),
    ("Chill / Lo-fi", "960cf833-0601-11e8-ae97-52543be04c81", "SomaFM Groove Salad", None),
    ("Chill / Lo-fi", "478fd7f4-dc36-11e9-a8ba-52543be04c81", "Smooth Chill", None),
    ("Chill / Lo-fi", "02338a64-da59-4db6-a1c1-639fdc74d65b", "REYFM #lofi", None),
    ("Chill / Lo-fi", "9467b580-dd8b-44d6-b99a-6ac688a50786", "ISEKOI Radio Chill Zone", None),
    ("Chill / Lo-fi", "960eb2e9-0601-11e8-ae97-52543be04c81", "SomaFM Drone Zone", None),
    ("Chill / Lo-fi", "3fd18c3f-8157-11e9-aa30-52543be04c81", "Café del Mar", None),
    ("Jazz", "ea8059be-d119-4de3-b27b-0d9bd6aedb17", "Adroit Jazz Underground", None),
    ("Jazz", "960c7c81-0601-11e8-ae97-52543be04c81", "SomaFM Secret Agent", None),
    ("Jazz", "0eb3dbcf-05f7-480e-83f4-7718102a4820", "SmoothJazz.com", None),
    ("Jazz", "7ada8a81-5ae1-418c-8f18-51d2f38d86a4", "Bossa Jazz Brasil", None),
    ("Classical", "96063f25-0601-11e8-ae97-52543be04c81", "Classic FM", None),
    ("Classical", "6b4d2d9d-1435-44aa-b5ee-1db50f833ddc", "Venice Classic Radio", None),
    ("Classical", "64bb1467-2585-4454-a96f-34cfbc864d41", "WALM 2", None),
    ("Classical", "03e68f6d-1ca3-459f-891a-c55d84711646", "BBC Radio 3", None),
    ("Rock", "961e37ee-0601-11e8-ae97-52543be04c81", "SomaFM Left Coast 70s", None),
    ("Rock", "d7f5a497-40ec-11e9-aa55-52543be04c81", "0N Classic Rock", None),
    ("Rock", "96394224-0601-11e8-ae97-52543be04c81", "SomaFM Indie Pop Rocks!", None),
    ("Rock", "501e4f18-fd92-441e-b4c6-4bd4a8435672", "Exclusively Pink Floyd", None),
    ("Rock", "605b2521-e764-42ba-8be0-473fc096a3b3", "ERT Zeppelin 106.7", None),
    ("Electronic", "962cc6df-0601-11e8-ae97-52543be04c81", "Dance Wave!", None),
    ("Electronic", "af6f51b1-0ca9-11ea-a87e-52543be04c81", "Intense Radio", None),
    ("Electronic", "960d3f6f-0601-11e8-ae97-52543be04c81", "SomaFM Space Station Soma", None),
    ("Electronic", "961173b5-0601-11e8-ae97-52543be04c81", "SomaFM Lush", None),
    ("Electronic", "cc0fdbe3-a2fb-4f0a-b67d-b47acd6354c7", "Technolovers Deep House", None),
    ("Talk", "98137c2d-ce68-4e33-8cb7-ddf3692ecc9d", "BBC Radio 4", None),
    ("Talk", "9614bbb6-0601-11e8-ae97-52543be04c81", "LBC", None),
    ("Talk", "7a3a3989-8f26-44f7-9ae5-fa91e5cf4f9d", "RMC", None),
    ("Talk", "177dda8f-ce5f-4f18-a19e-c6c8b6f5319a", "talkSPORT", None),
    ("Romania", "8158142a-c13e-4073-ace3-ab574f0285bb", "Radio România Actualități", None),
    ("Romania", "73ee836b-e9f2-4758-9cd6-2886da6db476", "Digi24 FM", None),
    ("Romania", "99ac4423-0307-11ea-bbf2-52543be04c81", "Kiss FM România", None),
    ("Romania", "c63f7402-f143-4f92-9cc9-e2d49f2a0bc5", "Europa FM", None),
    ("Romania", "1d6d9870-b554-4919-a0a9-93457d3de6da", "Virgin Radio România", None),
    ("Romania", "331f8e7c-a7ca-4c19-b1f2-1998cca09d4c", "Radio Guerrilla", None),
    ("Romania", "5e7667bc-98db-4772-be99-cf6e2e10d73f", "Magic FM România", None),
    ("Romania", "2eb897a7-b86b-4bb2-b245-94a43829b7e5", "Rock FM Hard Rock", None),
    ("UK", "3606ef8c-cd58-4440-8c47-dbf1e0cacdac", "BBC Radio 2", None),
    ("UK", "c4077677-dc2f-11e9-a8ba-52543be04c81", "Heart 80s", None),
    ("UK", "0a1e0bb0-dc37-11e9-a8ba-52543be04c81", "Gold", None),
    ("UK", "52bb00fe-dc31-11e9-a8ba-52543be04c81", "Heart 90s", None),
    ("UK", "9617bbd8-0601-11e8-ae97-52543be04c81", "Radio X", None),
    ("UK", "c6c204d3-3ffd-4e85-b0f9-29bf6de7ddf4", "Absolute Radio 80s", None),
]


def station(uuid):
    request = urllib.request.Request(API + uuid, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        rows = json.load(response)
    return rows[0] if rows else None


def answers_with_audio(url):
    result = subprocess.run(
        ["curl", "-sS", "-L", "-A", PROBE_AGENT, "--max-time", "8", "-r", "0-32767", "-o", "/dev/null",
         "-w", "%{http_code} %{content_type}", url], capture_output=True, text=True)
    code, _, kind = result.stdout.strip().partition(" ")
    return code in ("200", "206") and ("audio" in kind or "ogg" in kind or "mpegurl" in kind or "octet" in kind)


def https_candidates(url):
    """The stream itself when it is HTTPS, else the same stream on HTTPS (Global's
    musicradio.com serves every stream on media-ssl too)."""
    if url.startswith("https://"):
        return [url]
    if not url.startswith("http://"):
        return []
    secure = "https://" + url[len("http://"):]
    host = urllib.parse.urlsplit(url).hostname or ""
    if host.endswith(".musicradio.com"):
        return [secure.replace(host, "media-ssl.musicradio.com", 1), secure]
    return [secure]


def main():
    probe = "--no-probe" not in sys.argv
    tracks, folders, failures = [], {}, []
    for folder, uuid, name, override in STATIONS:
        record = station(uuid)
        if not record or record.get("lastcheckok") != 1:
            failures.append(f"{folder}: {name} ({uuid}) not checked OK by the directory")
            continue
        candidates = [override] if override else https_candidates(record.get("url_resolved", ""))
        url = next((c for c in candidates if not probe or answers_with_audio(c)), None) if candidates else None
        if not url:
            failures.append(f"{folder}: {name} ({uuid}) has no HTTPS stream that answers with audio")
            continue
        details = [record.get("countrycode") or "", record.get("codec") or ""]
        if record.get("bitrate"):
            details.append(f"{record['bitrate']} kbps")
        tracks.append({
            "url": url, "name": name or record["name"].strip(), "homepage": record.get("homepage", "").strip(),
            "annotation": " · ".join(part for part in details if part), "uuid": uuid,
        })
        folders.setdefault(folder, []).append(len(tracks) - 1)

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<playlist xmlns="http://xspf.org/ns/0/" xmlns:vlc="http://www.videolan.org/vlc/playlist/ns/0/" version="1">',
        "  <title>LinPad Radio</title>",
        "  <creator>LinPad</creator>",
        f"  <annotation>Internet radio stations from the community Radio Browser directory "
        f"(https://www.radio-browser.info), checked {date.today().isoformat()}. Each track's info link is the "
        f"station's own website; more stations: VLC › View › Playlist › Internet › Icecast Radio Directory."
        f"</annotation>",
        "  <info>https://www.radio-browser.info</info>",
        "  <trackList>",
    ]
    for index, track in enumerate(tracks):
        lines += [
            "    <track>",
            f"      <location>{escape(track['url'])}</location>",
            f"      <title>{escape(track['name'])}</title>",
            f"      <annotation>{escape(track['annotation'])}</annotation>",
        ]
        if track["homepage"]:
            lines.append(f"      <info>{escape(track['homepage'])}</info>")
        lines += [
            f'      <meta rel="https://api.radio-browser.info/#stationuuid">{track["uuid"]}</meta>',
            '      <extension application="http://www.videolan.org/vlc/playlist/0">',
            f"        <vlc:id>{index}</vlc:id>",
            "      </extension>",
            "    </track>",
        ]
    lines += ["  </trackList>", '  <extension application="http://www.videolan.org/vlc/playlist/0">']
    for folder, indices in folders.items():
        lines.append(f'    <vlc:node title="{escape(folder)}">')
        lines += [f'      <vlc:item tid="{index}"/>' for index in indices]
        lines.append("    </vlc:node>")
    lines += ["  </extension>", "</playlist>", ""]
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"{OUT}: {len(tracks)} stations in {len(folders)} folders")
    for failure in failures:
        print("left out:", failure, file=sys.stderr)


if __name__ == "__main__":
    main()
