#!/usr/bin/env python3
"""The brand's colours exist once, in branding/tokens.json, and are mirrored twice.

res/values/colors.xml carries every "brand" token as brand_<name> (the window and splash use
it), and ui/theme/Theme.kt's Brand object carries every token as a CamelCase name. This gate
fails when a mirror disagrees with the source, lacks a token, or has one the source does not.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import common


def camel(name: str) -> str:
    return "".join(part.capitalize() for part in name.split("_"))


def normalise(colour: str) -> str:
    """#RRGGBB, #AARRGGBB or 0xAARRGGBB -> RRGGBB, requiring an opaque alpha where given."""
    value = colour.strip().upper().removeprefix("#").removeprefix("0X")
    if len(value) == 8:
        if value[:2] != "FF":
            raise ValueError(f"{colour} is not opaque")
        value = value[2:]
    if not re.fullmatch(r"[0-9A-F]{6}", value):
        raise ValueError(f"{colour} is not a colour")
    return value


def read_tokens(root: Path) -> tuple[dict[str, str], dict[str, str]]:
    data = json.loads((root / "branding" / "tokens.json").read_text(encoding="utf-8"))
    brand = {k: normalise(v) for k, v in data.get("brand", {}).items()}
    semantic = {k: normalise(v) for k, v in data.get("semantic", {}).items()}
    return brand, semantic


def read_colors_xml(root: Path) -> dict[str, str]:
    text = common.strip_xml_comments(
        (common.main_src(root) / "res" / "values" / "colors.xml").read_text(encoding="utf-8"))
    return {name: value for name, value in re.findall(r'<color\s+name="([^"]+)"\s*>([^<]+)</color>', text)}


def read_brand_object(root: Path) -> dict[str, str]:
    text = (common.kotlin_sources(root) / "ui" / "theme" / "Theme.kt").read_text(encoding="utf-8")
    match = re.search(r"\bobject\s+Brand\s*\{(.*?)\n\}", text, re.S)
    if not match:
        return {}
    return dict(re.findall(r"val\s+(\w+)\s*=\s*Color\((0x[0-9A-Fa-f]{8})\)", match.group(1)))


def compare(label: str, expected: dict[str, str], actual: dict[str, str], report: common.Report) -> None:
    for name, value in expected.items():
        if name not in actual:
            report.fail(f"{label}: {name} is missing (tokens.json has #{value})")
            continue
        try:
            got = normalise(actual[name])
        except ValueError as error:
            report.fail(f"{label}: {name}: {error}")
            continue
        if got != value:
            report.fail(f"{label}: {name} is #{got}, tokens.json says #{value}")
    for name in sorted(set(actual) - set(expected)):
        report.fail(f"{label}: {name} is not in branding/tokens.json; add it there first")


def check(root: Path = common.POCKET) -> common.Report:
    report = common.Report()
    try:
        brand, semantic = read_tokens(root)
        xml = read_colors_xml(root)
        kotlin = read_brand_object(root)
    except (OSError, ValueError) as error:
        report.fail(f"cannot read the brand sources: {error}")
        return report
    if not kotlin:
        report.fail("ui/theme/Theme.kt has no Brand object with Color(0xAARRGGBB) values")
    xml_brand = {name.removeprefix("brand_"): value for name, value in xml.items() if name.startswith("brand_")}
    compare("res/values/colors.xml (brand_*)", brand, xml_brand, report)
    compare("Theme.kt Brand", {camel(k): v for k, v in {**brand, **semantic}.items()}, kotlin, report)
    return report


if __name__ == "__main__":
    sys.exit(common.run_standalone("brand tokens", check))
