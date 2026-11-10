#!/usr/bin/env python3
"""The app's version, read from app/build.gradle.kts without running Gradle.

The release tag is pocketide-v<appVersion>, the updater offers a release by that tag, and a
published tag is never replaced, so appVersion is the one number to raise for a new release.
Android, however, installs an update only when its versionCode is higher, so versionCode must
follow appVersion (major * 10000 + minor * 100 + patch) rather than be a number of its own: a
release that raised only the version would be offered to every phone and refused by all of them.
Any 9.x (90000 and up) installs over every 8.x (80000 and up), and so on down to 2.6.0 (260).
No release goes back below 8.0.0, the first of this app's line.

Usage: version.py            check the version
       version.py --print    print versionName (for the workflow)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import common

VERSION_SHAPE = re.compile(r"([89]|[1-9]\d)\.(\d{1,2})\.(\d{1,2})")
VERSION = re.compile(r'^\s*val appVersion = "([^"]*)"\s*$', re.M)
VERSION_CODE = re.compile(r"^\s*versionCode\s*=\s*(.+?)\s*$", re.M)
VERSION_NAME = re.compile(r"^\s*versionName\s*=\s*(.+?)\s*$", re.M)
DERIVED_CODE = "versionCodeOf(appVersion)"
FORMULA = "major * 10000 + minor * 100 + patch"
FORMULA_LINE = re.compile(r"^\s*return " + re.escape(FORMULA) + r"\s*$", re.M)


def version_code(version: str) -> int:
    major, minor, patch = (int(part) for part in version.split("."))
    return major * 10000 + minor * 100 + patch


def check(root: Path = common.POCKET) -> common.Report:
    report = common.Report()
    text = (common.app(root) / "build.gradle.kts").read_text(encoding="utf-8")
    versions = VERSION.findall(text)
    codes = VERSION_CODE.findall(text)
    names = VERSION_NAME.findall(text)
    if len(versions) != 1:
        report.fail(f'app/build.gradle.kts must set val appVersion = "<major>.<minor>.<patch>" exactly once (found {len(versions)})')
    elif not VERSION_SHAPE.fullmatch(versions[0]):
        report.fail(f"appVersion '{versions[0]}' is not <major>.<minor>.<patch> with major 8 to 99, minor and patch below 100")
    if codes != [DERIVED_CODE] or len(FORMULA_LINE.findall(text)) != 1:
        report.fail(f"versionCode must be set once as {DERIVED_CODE} ({FORMULA}), found {codes or 'none'}: "
                    "a versionCode of its own is not raised with the version, and every phone would refuse the update")
    if names != ["appVersion"]:
        report.fail(f"versionName must be set once as appVersion, found {names or 'none'}")
    if report.ok:
        report.note(f"versionName {versions[0]}, versionCode {version_code(versions[0])}")
    return report


def version_name(root: Path = common.POCKET) -> str:
    report = check(root)
    if not report.ok:
        raise SystemExit("\n".join(report.problems))
    text = (common.app(root) / "build.gradle.kts").read_text(encoding="utf-8")
    return VERSION.findall(text)[0]


if __name__ == "__main__":
    if sys.argv[1:] == ["--print"]:
        print(version_name())
        sys.exit(0)
    sys.exit(common.run_standalone("version", check))
