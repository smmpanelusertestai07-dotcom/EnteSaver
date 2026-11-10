"""Reading Android manifests: the source one, and the merged one Gradle writes for release."""
from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import common

ANDROID = "{http://schemas.android.com/apk/res/android}"
TOOLS = "{http://schemas.android.com/tools}"
MERGED_RELEASE = "app/build/intermediates/merged_manifests/release"


@dataclass
class Manifest:
    path: Path
    package: str | None
    uses_permissions: list[str]
    declared_permissions: dict[str, str]  # name -> protectionLevel
    application: dict[str, str]  # android:* attributes of <application>, without the namespace


def parse(path: Path) -> Manifest:
    root = ET.parse(path).getroot()
    # tools:node="remove" strikes a library's permission out of the merge; it is not a request.
    uses = [e.get(ANDROID + "name", "") for e in root.iter()
            if e.tag in ("uses-permission", "uses-permission-sdk-23") and e.get(TOOLS + "node") != "remove"]
    declared = {e.get(ANDROID + "name", ""): e.get(ANDROID + "protectionLevel", "normal")
                for e in root.findall("permission")}
    application = root.find("application")
    attributes = {}
    if application is not None:
        attributes = {k.removeprefix(ANDROID): v for k, v in application.attrib.items() if k.startswith(ANDROID)}
    return Manifest(path, root.get("package"), uses, declared, attributes)


def source(root: Path) -> Path:
    return common.main_src(root) / "AndroidManifest.xml"


def merged_release(root: Path) -> Path | None:
    """The merged release manifest, if Gradle has written one (AGP 8: .../processReleaseManifest/)."""
    found = sorted((root / MERGED_RELEASE).glob("**/AndroidManifest.xml"))
    return found[0] if found else None
