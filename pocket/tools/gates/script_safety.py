#!/usr/bin/env python3
"""No script PocketIDE ships or runs pipes a download straight into an interpreter.

A download piped into a shell runs whatever the server sends at that moment, unverified; every
download here is checked by SHA-256 before it is used (plan §15). Checked: everything under
app/src/main/assets, pocket/cloudshell (the script the owner runs in Google Cloud Shell) and
pocket/tools, except the tools' tests, which hold broken samples on purpose. Comment lines are skipped, so a script may still
explain why it does not do this.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import common

FETCH = r"\b(curl|wget)\b"
INTERPRETER = r"(sudo\s+(-\S+\s+)*)?(env\s+(\S+=\S*\s+)*)?(ba|z|da|k|fi)?sh\b|\b(python3?|node|perl|ruby|php)\b"
PATTERNS = [
    (re.compile(FETCH + r"[^\n|]*\|\s*(" + INTERPRETER + ")"), "pipes a download into an interpreter"),
    (re.compile(r"\b(ba|z|da|k)?sh\s+(-\w+\s+)*-c\s+[\"']?\$\(\s*" + FETCH), "runs a download through sh -c"),
    (re.compile(r"\b(ba|z|da|k)?sh\s+<\(\s*" + FETCH), "runs a download through process substitution"),
    (re.compile(r"\b(source|\.)\s+<\(\s*" + FETCH), "sources a download"),
    (re.compile(r"\beval\s+[\"']?\$\(\s*" + FETCH), "evals a download"),
]
COMMENT_PREFIXES = {".sh": "#", ".bash": "#", ".py": "#", ".yml": "#", ".yaml": "#", ".toml": "#",
                    ".kt": "//", ".kts": "//", ".js": "//", ".ts": "//"}
TEXT_SUFFIXES = tuple(COMMENT_PREFIXES) + (".json", ".txt", ".conf", ".service", ".desktop")


def scan(name: str, text: str) -> list[str]:
    prefix = COMMENT_PREFIXES.get(Path(name).suffix)
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        if prefix and line.lstrip().startswith(prefix):
            continue
        for pattern, what in PATTERNS:
            if pattern.search(line):
                found.append(f"{name}:{number}: {what}; download to a file, check its SHA-256, then run it")
                break
    return found


def check(root: Path = common.POCKET) -> common.Report:
    report = common.Report()
    for base in (common.assets(root), root / "cloudshell", root / "tools"):
        for path in common.files_under(base, TEXT_SUFFIXES):
            if "__pycache__" in path.parts or path.is_relative_to(root / "tools" / "tests"):
                continue
            text = common.read_text(path)
            if text is not None:
                for problem in scan(path.relative_to(root).as_posix(), text):
                    report.fail(problem)
    return report


if __name__ == "__main__":
    sys.exit(common.run_standalone("script safety", check))
