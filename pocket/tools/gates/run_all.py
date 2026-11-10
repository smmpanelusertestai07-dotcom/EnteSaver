#!/usr/bin/env python3
"""Runs every PocketIDE gate and exits non-zero if any fails.

Source gates need only the checkout. With --built they also check what Gradle produced: the
merged release manifest, and (with --apk) the native libraries inside the signed APK.

Usage: run_all.py [--built] [--apk PATH]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import brand_tokens
import common
import least_privilege
import manifest
import native_alignment
import no_secrets
import permissions
import repository
import script_safety
import version
import workflow


def gates(built: bool, apk: Path | None):
    yield "repository", repository.check
    yield "no secrets", no_secrets.check
    yield "workflow", workflow.check
    yield "version", version.check
    yield "brand tokens", brand_tokens.check
    yield "manifest", lambda: manifest.check(built=built)
    yield "permissions", lambda: permissions.check(built=built)
    yield "least privilege (GitHub Administration)", least_privilege.check
    yield "script safety", script_safety.check
    yield "16 KB native alignment (jniLibs)", native_alignment.check
    if apk is not None:
        yield f"16 KB native alignment ({apk.name})", lambda: native_alignment.check(apk=apk)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--built", action="store_true", help="also check Gradle's release output")
    parser.add_argument("--apk", type=Path, help="the signed APK whose native libraries to check")
    args = parser.parse_args()

    failed = []
    for name, check in gates(args.built, args.apk):
        try:
            report = check()
        except Exception as error:  # a gate that cannot run has failed, and says why
            report = common.Report()
            report.fail(f"the gate itself could not run: {type(error).__name__}: {error}")
        common.print_report(name, report)
        if not report.ok:
            failed.append(name)
    print()
    if failed:
        print(f"{len(failed)} gate(s) failed: {', '.join(failed)}")
        return 1
    print("All gates passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
