#!/usr/bin/env python3
"""Nothing that looks like a live credential may be tracked under pocket/.

The patterns are the shapes real providers issue, so a match is almost never a coincidence.
They apply to tests too: a test needs no real credential.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import common

PATTERNS = [
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36}\b"), "a GitHub token"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{60,}"), "a GitHub fine-grained token"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), "an Anthropic API key"),
    (re.compile(r"\bsk-(proj-)?[A-Za-z0-9_-]{32,}"), "an OpenAI API key"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), "a Google API key"),
    (re.compile(r"\bGOCSPX-[A-Za-z0-9_-]{20,}"), "a Google OAuth client secret"),
    (re.compile(r"\bya29\.[0-9A-Za-z_-]{20,}"), "a Google access token"),
    (re.compile(r"\b1//0[0-9A-Za-z_-]{30,}"), "a Google refresh token"),
    (re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"), "an AWS access key"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), "a Slack token"),
    (re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"), "an npm token"),
    (re.compile(r"-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"), "a private key"),
    (re.compile(r"\bAGE-SECRET-KEY-1[0-9A-Z]{58}\b"), "an age secret key"),
]


def scan(relative: str, text: str) -> list[str]:
    found = []
    for pattern, what in PATTERNS:
        match = pattern.search(text)
        if match:
            line = text.count("\n", 0, match.start()) + 1
            found.append(f"pocket/{relative}:{line}: looks like {what}")
    return found


def check(root: Path = common.POCKET, tracked: list[Path] | None = None) -> common.Report:
    """tracked: the files to scan, relative to root (default: what git tracks)."""
    report = common.Report()
    for path in common.tracked_files(root) if tracked is None else tracked:
        full = root / path
        if not full.is_file():
            continue
        text = common.read_text(full)
        if text is None:
            continue
        for problem in scan(path.as_posix(), text):
            report.fail(problem + " (remove it and revoke it at the provider)")
    return report


if __name__ == "__main__":
    sys.exit(common.run_standalone("no secrets", check))
