#!/usr/bin/env python3
"""The GPL notice published beside each release, for the PRoot actually inside the APK.

It reads the version string inside the APK's lib/arm64-v8a/libproot.so, finds that release in
sources.json, and writes where its exact source is: PRoot (GPL-2.0), talloc (LGPL-3.0-or-later)
and libandroid-shmem (BSD-3-Clause). Publishing a GPL binary without its exact source is not an
option, so it fails when the APK's PRoot is not in sources.json, when the APK's native libraries
differ from the binaries that release records, or when a GPL or LGPL part lacks a pinned archive
(url and sha256). With --sources DIR it downloads every pinned archive and build recipe into DIR,
verified, to attach to the release.

Usage: gpl_notice.py APK --app-version X.Y.Z [--out FILE] [--sources DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

SOURCES_JSON = Path(__file__).with_name("sources.json")
LIB_DIR = "lib/arm64-v8a/"
PARTS = ("proot", "talloc", "libandroid_shmem")
VERSION = re.compile(rb"(?<![\d.])(\d+\.\d+\.\d+\.\d+)(?![\d.])")
SHA256 = re.compile(r"[0-9a-f]{64}")


class NoticeError(Exception):
    pass


def releases(path: Path = SOURCES_JSON) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))["releases"]


def shipped_release(libproot: bytes, known: list[dict]) -> dict:
    versions = {v.decode() for v in VERSION.findall(libproot)}
    matches = [r for r in known if r["version"] in versions]
    if len(matches) != 1:
        found = ", ".join(sorted(versions)) or "none"
        raise NoticeError(f"libproot.so carries version strings [{found}], which name "
                          f"{len(matches)} releases in sources.json; add its source there before releasing")
    return matches[0]


def _pinned(entry: dict | None) -> bool:
    return bool(entry and entry.get("url") and SHA256.fullmatch(entry.get("sha256") or ""))


def check_pinned(release: dict) -> None:
    """Every GPL or LGPL part, and every build recipe listed, has a url and a SHA-256 to fetch it by."""
    missing = []
    for key in PARTS:
        part = release[key]
        if "GPL" in part["license"] and not _pinned(part):
            missing.append(f"{key} ({part['license']}) has no pinned source archive")
        if "recipe" in part and not _pinned(part["recipe"]):
            missing.append(f"{key}'s build recipe has no pinned url and sha256")
    if missing:
        raise NoticeError(f"PRoot {release['version']}: {'; '.join(missing)}. Pin them in sources.json before releasing")


def check_binaries(libraries: dict[str, bytes], release: dict) -> None:
    """The APK carries exactly the native libraries the release records, when it records them."""
    expected = release.get("binaries")
    if not expected:
        return
    problems = []
    for name, sha256 in sorted(expected.items()):
        data = libraries.get(name)
        if data is None:
            problems.append(f"{name} is missing")
        elif hashlib.sha256(data).hexdigest() != sha256:
            problems.append(f"{name} is not the recorded build")
    problems += [f"{name} is not recorded" for name in sorted(set(libraries) - set(expected))]
    if problems:
        raise NoticeError(f"the APK's native libraries are not PRoot {release['version']} as sources.json "
                          f"records it: {'; '.join(problems)}")


def notice(release: dict, app_version: str) -> str:
    proot, talloc, shmem = release["proot"], release["talloc"], release["libandroid_shmem"]
    lines = [
        f"PocketIDE {app_version}: source for the GPL and LGPL parts inside the APK",
        "",
        "PocketIDE's own code is under the Apache License 2.0. The APK also carries PRoot, which",
        "runs the Ubuntu computer, and the libraries PRoot uses. Their licences and exact source:",
        "",
        f"PRoot {release['version']} (libproot.so, libproot-loader.so), {proot['license']}",
        f"  Termux's PRoot, tag {proot['tag']}, commit {proot['commit']}",
        "  https://github.com/termux/proot",
        f"  {proot['url']}",
    ]
    lines += _archive_lines(proot)
    for title, part in (("talloc", talloc), ("libandroid-shmem", shmem)):
        lines += ["", f"{title}, {part['license']}", f"  Version: {part['version']}", f"  {part['url']}"]
        lines += _archive_lines(part)
    lines += [
        "",
        f"How this PRoot was made: {release['origin']}",
    ]
    if release.get("build"):
        lines += [
            "The build script is pocket/tools/proot/build-proot.sh in this repository, at the commit",
            "this release was built from.",
        ]
    if release.get("patches"):
        lines += ["Patches applied to PRoot's source first (in pocket/tools/proot/, each saying what it fixes):"]
        lines += [f"  {patch}" for patch in release["patches"]]
    if release.get("binaries"):
        lines += ["", "SHA-256 of the files inside the APK (lib/arm64-v8a/):"]
        lines += [f"  {sha256}  {name}" for name, sha256 in sorted(release["binaries"].items())]
    lines += [
        "",
        "Every archive and build recipe above is attached to this release, checked against its SHA-256.",
        "",
        "The GNU General Public License, version 2: https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt",
        "The GNU Lesser General Public License, version 3: https://www.gnu.org/licenses/lgpl-3.0.txt",
        "",
    ]
    return "\n".join(lines)


def _archive_lines(part: dict) -> list[str]:
    lines = []
    if part.get("sha256"):
        lines.append(f"  SHA-256 of that archive: {part['sha256']}")
    if part.get("recipe"):
        lines += [f"  Build recipe: {part['recipe']['url']}", f"  SHA-256 of that recipe: {part['recipe']['sha256']}"]
    return lines


def download_verified(url: str, sha256: str, destination: Path, mirrors: tuple[str, ...] = (), tries: int = 3) -> None:
    """Saves the first of url and its mirrors whose bytes match the pinned SHA-256.

    A host that cannot be reached or answers 5xx is tried again, so one dropped connection does
    not fail a release; a wrong checksum or a 4xx moves on to the next mirror at once.
    """
    problems = []
    for candidate in (url, *mirrors):
        for attempt in range(tries):
            try:
                request = urllib.request.Request(candidate, headers={"User-Agent": "pocketide-ci"})
                with urllib.request.urlopen(request, timeout=120) as response:
                    data = response.read()
            except urllib.error.HTTPError as error:
                problems.append(f"{candidate}: HTTP {error.code}")
                if error.code < 500 and error.code not in (408, 429):
                    break
            except OSError as error:
                problems.append(f"{candidate}: {error}")
            else:
                actual = hashlib.sha256(data).hexdigest()
                if actual == sha256:
                    destination.write_bytes(data)
                    return
                problems.append(f"{candidate} now hashes to {actual}, not the pinned {sha256}")
                break
            if attempt + 1 < tries:
                time.sleep(5 * (attempt + 1))
    raise NoticeError("; ".join(problems))


def fetch_sources(release: dict, directory: Path) -> list[Path]:
    directory.mkdir(parents=True, exist_ok=True)
    saved = []
    for key in PARTS:
        part = release[key]
        stem = f"{key.replace('_', '-')}-{part.get('version') or release['version']}"
        if part.get("sha256"):
            saved.append(directory / f"{stem}-source{_suffix(part['url'])}")
            download_verified(part["url"], part["sha256"], saved[-1], mirrors=tuple(part.get("mirrors", ())))
        if part.get("recipe"):
            saved.append(directory / f"{stem}-termux-build.sh")
            download_verified(part["recipe"]["url"], part["recipe"]["sha256"], saved[-1])
    return saved


def proot_family(name: str) -> bool:
    """PRoot's own files and the libraries it links: the rest of lib/ is AndroidX's, under Apache 2.0."""
    return name.startswith("libproot") or "talloc" in name or "shmem" in name


def native_libraries(apk: Path) -> dict[str, bytes]:
    """The APK's arm64 PRoot libraries by file name."""
    with zipfile.ZipFile(apk) as archive:
        names = [n for n in archive.namelist() if n.startswith(LIB_DIR) and n.endswith(".so")]
        return {name[len(LIB_DIR):]: archive.read(name) for name in names
                if "/" not in name[len(LIB_DIR):] and proot_family(name[len(LIB_DIR):])}


def _suffix(url: str) -> str:
    for suffix in (".tar.gz", ".tar.xz", ".zip"):
        if url.endswith(suffix):
            return suffix
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("apk", type=Path)
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--out", type=Path, help="write the notice here instead of printing it")
    parser.add_argument("--sources", type=Path, help="download the pinned source archives into this folder")
    args = parser.parse_args()
    try:
        libraries = native_libraries(args.apk)
        if "libproot.so" not in libraries:
            raise NoticeError(f"{args.apk} has no {LIB_DIR}libproot.so")
        release = shipped_release(libraries["libproot.so"], releases())
        check_binaries(libraries, release)
        check_pinned(release)
        text = notice(release, args.app_version)
        if args.out:
            args.out.write_text(text, encoding="utf-8")
        else:
            print(text)
        if args.sources:
            for path in fetch_sources(release, args.sources):
                print(f"source attached: {path.name}", file=sys.stderr)
    except (NoticeError, KeyError, OSError, zipfile.BadZipFile) as error:
        print(f"gpl_notice: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
