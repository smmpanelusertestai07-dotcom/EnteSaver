#!/usr/bin/env python3
"""The manifest keeps the owner's data where the plan says it lives (plan §6, §12).

  - Android's own backup and device transfer take nothing: allowBackup is false, and both
    dataExtractionRules (Android 12+) and fullBackupContent (Android 10 and 11) exist and
    exclude every domain. The phone keeps only the settings; code and chats live in the owner's
    own Google Cloud Shell.
  - No storage or media permission (the photo picker needs none), and none of the "never"
    permissions: camera, microphone, location, contacts, SMS, calls, the app list, a battery
    exemption, drawing over other apps.

Usage: manifest.py [--built]   (--built also checks the merged release manifest)
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import common
import manifests

DOMAINS = {"root", "file", "database", "sharedpref", "external"}
NEVER = [
    (r"(READ|WRITE|MANAGE)_EXTERNAL_STORAGE|READ_MEDIA_\w+|ACCESS_MEDIA_LOCATION", "storage or media"),
    (r"CAMERA", "the camera"),
    (r"RECORD_AUDIO", "the microphone"),
    (r"ACCESS_(FINE|COARSE|BACKGROUND)_LOCATION", "location"),
    (r"(READ|WRITE)_CONTACTS|GET_ACCOUNTS", "contacts or accounts"),
    (r"(SEND|READ|RECEIVE)_(SMS|MMS|WAP_PUSH)", "SMS"),
    (r"READ_PHONE_STATE|READ_PHONE_NUMBERS|CALL_PHONE|READ_CALL_LOG|WRITE_CALL_LOG|ANSWER_PHONE_CALLS", "calls"),
    (r"(READ|WRITE)_CALENDAR", "the calendar"),
    (r"QUERY_ALL_PACKAGES", "the list of apps"),
    (r"REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", "a battery exemption"),
    (r"SYSTEM_ALERT_WINDOW", "drawing over other apps"),
]


def never_problems(manifest: manifests.Manifest, label: str) -> list[str]:
    problems = []
    for name in manifest.uses_permissions:
        short = name.removeprefix("android.permission.")
        for pattern, what in NEVER:
            if name.startswith("android.permission.") and re.fullmatch(pattern, short):
                problems.append(f"{label} requests {name} ({what}); PocketIDE never asks for {what}")
    return problems


def excluded_domains(section) -> set[str]:
    return {e.get("domain", "") for e in section.findall("exclude") if e.get("path") == "."}


def rules_problems(root: Path, manifest: manifests.Manifest) -> list[str]:
    problems = []
    app = manifest.application
    if app.get("allowBackup") != "false":
        problems.append('<application> must set android:allowBackup="false"')
    xml_dir = common.main_src(root) / "res" / "xml"
    for attribute, sections in (("dataExtractionRules", ("cloud-backup", "device-transfer")),
                                ("fullBackupContent", (None,))):
        reference = app.get(attribute, "")
        if not reference.startswith("@xml/"):
            problems.append(f"<application> has no android:{attribute}=\"@xml/…\"")
            continue
        path = xml_dir / (reference.removeprefix("@xml/") + ".xml")
        if not path.is_file():
            problems.append(f"android:{attribute} points to {reference}, which does not exist")
            continue
        rules = ET.parse(path).getroot()
        for name in sections:
            section = rules if name is None else rules.find(name)
            if section is None:
                problems.append(f"{path.name} has no <{name}> section, so Android's default applies to it")
                continue
            if section.findall("include"):
                problems.append(f"{path.name} <{name or rules.tag}> includes something; it must only exclude")
            missing = DOMAINS - excluded_domains(section)
            if missing:
                problems.append(f"{path.name} <{name or rules.tag}> does not exclude {', '.join(sorted(missing))}")
    return problems


def check(root: Path = common.POCKET, built: bool = False) -> common.Report:
    report = common.Report()
    source = manifests.parse(manifests.source(root))
    for problem in rules_problems(root, source) + never_problems(source, "AndroidManifest.xml"):
        report.fail(problem)
    if built:
        merged_path = manifests.merged_release(root)
        if merged_path is None:
            report.fail(f"no merged release manifest under {manifests.MERGED_RELEASE}; run assembleRelease first")
        else:
            merged = manifests.parse(merged_path)
            for problem in never_problems(merged, "the merged release manifest"):
                report.fail(problem)
            if merged.application.get("allowBackup") != "false":
                report.fail("the merged release manifest turns allowBackup back on")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--built", action="store_true", help="also check the merged release manifest")
    args = parser.parse_args()
    sys.exit(common.run_standalone("manifest", lambda: check(built=args.built)))
