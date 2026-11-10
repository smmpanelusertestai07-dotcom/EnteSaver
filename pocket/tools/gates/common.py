"""What every gate shares: where things live, one report shape, and one way to print it.

Each gate module exposes check(root) -> Report, where root is the pocket/ directory. The
default root is this checkout's pocket/, and the tests pass a temporary tree laid out the same
way, which is how every gate is also exercised against a tree that is broken on purpose.
"""
from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

POCKET = Path(__file__).resolve().parents[2]


def app(root: Path) -> Path:
    return root / "app"


def main_src(root: Path) -> Path:
    return root / "app" / "src" / "main"


def assets(root: Path) -> Path:
    return main_src(root) / "assets"


def kotlin_sources(root: Path) -> Path:
    return main_src(root) / "java" / "com" / "pocketide"


@dataclass
class Report:
    problems: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def fail(self, message: str) -> None:
        self.problems.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)

    def extend(self, other: "Report") -> None:
        self.problems.extend(other.problems)
        self.notes.extend(other.notes)

    @property
    def ok(self) -> bool:
        return not self.problems


def print_report(name: str, report: Report) -> None:
    mark = "ok  " if report.ok else "FAIL"
    print(f"[{mark}] {name}")
    for note in report.notes:
        print(f"         note: {note}")
    for problem in report.problems:
        print(f"         {problem}")


def run_standalone(name: str, check: Callable[[], Report]) -> int:
    report = check()
    print_report(name, report)
    return 0 if report.ok else 1


def tracked_files(root: Path) -> list[Path]:
    """Files git tracks under root, relative to root. Untracked build output never counts."""
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "."],
        check=True, capture_output=True,
    ).stdout
    return [Path(p.decode()) for p in out.split(b"\0") if p]


def read_text(path: Path) -> str | None:
    """The file as text, or None for a binary file (a NUL byte in the first 8 KB)."""
    data = path.read_bytes()
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


def strip_xml_comments(text: str) -> str:
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def files_under(directory: Path, suffixes: Iterable[str]) -> list[Path]:
    wanted = tuple(suffixes)
    if not directory.is_dir():
        return []
    return sorted(p for p in directory.rglob("*") if p.is_file() and p.name.endswith(wanted))


if __name__ == "__main__":
    sys.exit("common.py is a library for the gates; run run_all.py instead.")
