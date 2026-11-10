#!/usr/bin/env python3
"""What may be tracked under pocket/, in a repository the whole world can read.

No Markdown (the docs live inside the app), no key stores or private keys of any format, no
local.properties (it can carry the owner's configuration), no built APKs, and no Python caches. And pocket/ stays
a standalone Gradle build: the root settings never include it, so CloudSaver's build cannot
break PocketIDE's, or the other way round.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import common

FORBIDDEN_SUFFIXES = {
    ".md": "Markdown (the docs are in the app, versioned with it)",
    ".jks": "a Java key store",
    ".keystore": "a key store",
    ".p12": "a PKCS#12 key store",
    ".pfx": "a PKCS#12 key store",
    ".pem": "a PEM key or certificate",
    ".apk": "a built APK",
    ".aab": "a built app bundle",
    ".pyc": "compiled Python (a cache Python leaves when a test imports a script)",
}
FORBIDDEN_NAMES = {"local.properties": "local build configuration"}


def forbidden(path: Path) -> str | None:
    name = path.name.lower()
    if name in FORBIDDEN_NAMES:
        return FORBIDDEN_NAMES[name]
    for suffix, what in FORBIDDEN_SUFFIXES.items():
        if name.endswith(suffix):
            return what
    return None


def root_settings_include_pocket(repo_root: Path) -> list[str]:
    found = []
    for name in ("settings.gradle.kts", "settings.gradle"):
        settings = repo_root / name
        if settings.is_file():
            text = settings.read_text(encoding="utf-8")
            if re.search(r"""(include|includeBuild)\s*\(?[^\n]*["':]pocket\b""", text):
                found.append(name)
    return found


def check(root: Path = common.POCKET, tracked: list[Path] | None = None) -> common.Report:
    """tracked: the files to judge, relative to root (default: what git tracks)."""
    report = common.Report()
    for path in common.tracked_files(root) if tracked is None else tracked:
        what = forbidden(path)
        if what:
            report.fail(f"pocket/{path.as_posix()} is tracked: {what} must not be in this repository")
    for name in root_settings_include_pocket(root.parent):
        report.fail(f"{name} at the repository root includes pocket/; it must stay a standalone build")
    return report


if __name__ == "__main__":
    sys.exit(common.run_standalone("repository", check))
