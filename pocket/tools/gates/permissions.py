#!/usr/bin/env python3
"""Permissions, checked where they are decided: the merged release manifest.

Libraries add permissions of their own when manifests merge, so the source manifest alone
proves little. The allow-list is permissions.txt beside this file. Three things must agree:
  - the merged release manifest requests exactly the allow-list (with --built);
  - the source manifest requests nothing outside it;
  - every android.permission on it is explained in Help > Permissions (docs/Guide.kt),
    and Help explains nothing that is not requested.
Any permission the app declares itself must be signature-level, so no other app can hold it.

Usage: permissions.py [--built]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import common
import manifests

ALLOW_LIST = Path(__file__).with_name("permissions.txt")
DOCS = "docs/Guide.kt"
ANDROID_PREFIX = "android.permission."


def allow_list(path: Path = ALLOW_LIST) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return [line.strip() for line in lines if line.strip() and not line.lstrip().startswith("#")]


def expand(entries: list[str], package: str | None) -> set[str]:
    return {e.replace("${applicationId}", package or "${applicationId}") for e in entries}


def documented(root: Path) -> set[str] | None:
    """Short names in Help > Permissions (row("INTERNET", …)), or None when the section is gone."""
    path = common.kotlin_sources(root) / DOCS
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    match = re.search(r'section\(\s*"permissions"(.*?)(?:\n    val |\Z)', text, re.S)
    if not match:
        return None
    return set(re.findall(r'row\(\s*"([A-Z][A-Z0-9_]+)"', match.group(1)))


def check_docs(root: Path, allowed: set[str], report: common.Report) -> None:
    rows = documented(root)
    if rows is None:
        report.fail(f"{DOCS} has no 'permissions' section; Help must explain every permission")
        return
    wanted = {p.removeprefix(ANDROID_PREFIX) for p in allowed if p.startswith(ANDROID_PREFIX)}
    for name in sorted(wanted - rows):
        report.fail(f"{name} may be requested but Help > Permissions does not explain it ({DOCS})")
    for name in sorted(rows - wanted):
        report.fail(f"Help > Permissions explains {name}, which is not on the allow-list")


def check_declared(manifest: manifests.Manifest, report: common.Report) -> None:
    for name, level in manifest.declared_permissions.items():
        if "signature" not in level:
            report.fail(f"{manifest.path.name} declares {name} with protectionLevel '{level}'; "
                        "only signature-level permissions may be declared")


def check_merged(root: Path, entries: list[str], report: common.Report) -> None:
    path = manifests.merged_release(root)
    if path is None:
        report.fail(f"no merged release manifest under {manifests.MERGED_RELEASE}; run assembleRelease first")
        return
    merged = manifests.parse(path)
    allowed = expand(entries, merged.package)
    requested = set(merged.uses_permissions)
    for name in sorted(requested - allowed):
        report.fail(f"the merged release manifest requests {name}, which is not on the allow-list "
                    f"(a library may have added it; remove it with tools:node=\"remove\" or justify it "
                    f"in tools/gates/permissions.txt)")
    for name in sorted(allowed - requested):
        report.fail(f"{name} is on the allow-list but no longer requested; remove it from permissions.txt")
    check_declared(merged, report)
    report.note(f"merged release manifest: {len(requested)} permissions ({path.relative_to(root)})")


def check(root: Path = common.POCKET, built: bool = False, allow: Path = ALLOW_LIST) -> common.Report:
    report = common.Report()
    entries = allow_list(allow)
    source = manifests.parse(manifests.source(root))
    allowed_source = expand(entries, "${applicationId}") | expand(entries, source.package)
    for name in source.uses_permissions:
        if name not in allowed_source:
            report.fail(f"AndroidManifest.xml requests {name}, which is not on the allow-list")
    check_declared(source, report)
    check_docs(root, set(entries), report)
    if built:
        check_merged(root, entries, report)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--built", action="store_true", help="also check the merged release manifest")
    args = parser.parse_args()
    sys.exit(common.run_standalone("permissions", lambda: check(built=args.built)))
