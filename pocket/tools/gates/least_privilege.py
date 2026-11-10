#!/usr/bin/env python3
"""The GitHub App holds Administration: write only to create repositories.

That one permission would also let the app delete a repository, change its visibility, archive
it or transfer it away, and PocketIDE promises none of that ever happens. This gate reads the
Kotlin sources and fails when a code path could do any of those things:
  - an HTTP DELETE whose URL is a repository itself (repos/{owner}/{name}); deleting things
    inside a repository, such as a session branch or an Actions secret, is fine;
  - a PATCH to a repository that sends "private", "visibility" or "archived";
  - a transfer (repos/{owner}/{name}/transfer), or GraphQL's deleteRepository,
    archiveRepository, transferRepository or updateRepository mutations;
  - a DELETE or PATCH added to the GitHub client's `enum class Verb` without a reviewed entry
    in least_privilege_allow.txt (4.0.0 has one: deleting a codespace, moving a branch).

Both ways of writing a call are read: a string path ("repos/$o/$n" with "DELETE", .delete() or
@DELETE), and the app's own idiom, rest.send(Verb.DELETE, repoUrl(owner, name, ...)) or
rest.url("repos", owner, name, ...), where the path is built from segments and a repository
itself is repoUrl with no segment after owner and name.

A call is judged from the lines around it (the statement building the request), so the rule
is a source-text rule: a reviewer can see why it fired. A reviewed exception goes in
least_privilege_allow.txt as "<path relative to com/pocketide>: <the exact trimmed line>".
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import common

ALLOW_FILE = Path(__file__).with_name("least_privilege_allow.txt")
WINDOW = 6
METHOD_DELETE = re.compile(r'"DELETE"|@DELETE\b|\.delete\(\s*\)|\.delete\(\s*(null|body|[\w.]*RequestBody)|\bdelete\(\s*"')
METHOD_PATCH = re.compile(r'"PATCH"|@PATCH\b|\.patch\(|\bpatch\(\s*"')
VERB_DELETE = re.compile(r"\bVerb\.DELETE\b")
VERB_PATCH = re.compile(r"\bVerb\.PATCH\b")
# repoUrl(owner, name) or rest.url("repos", owner, name): the repository itself, no segment after.
ARGUMENT = r'\s*[^,()"\s][^,()"]*'
REPO_ROOT_CALL = re.compile(r"\brepoUrl\(" + ARGUMENT + "," + ARGUMENT + r"\)"
                            r'|\burl\(\s*"repos"\s*,' + ARGUMENT + "," + ARGUMENT + r"\)")
TRANSFER_CALL = re.compile(r'\brepoUrl\([^()]*"transfer"|\burl\(\s*"repos"[^()]*"transfer"')
VERB_ENUM = re.compile(r"\benum\s+class\s+Verb\b[^{]*\{([^}]*)\}")
WRITE_VERBS = re.compile(r"\b(DELETE|PATCH)\b")
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
TEMPLATE = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\}")
# "repos/{}/{}" or "repos/{}" when one variable holds owner/name.
REPO_ROOT = re.compile(r"(^|/)repos/\{\}(/\{\})?/?(\?.*)?$")
TRANSFER = re.compile(r"(^|/)repos/\{\}(/\{\})?/transfer\b")
VISIBILITY_FIELDS = re.compile(r'"(private|visibility|archived)"')
GRAPHQL = re.compile(r"\b(deleteRepository|archiveRepository|transferRepository|updateRepository)\b")


def normalise(literal: str) -> str:
    """A Kotlin string template (or a {placeholder} path) with every $name, ${…} and {name} as {}."""
    return TEMPLATE.sub("{}", literal)


def literals(lines: list[str]) -> list[str]:
    return [normalise(m.group(1)) for line in lines for m in STRING.finditer(line)]


def is_comment(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith(("//", "*", "/*"))


def rest_of_call(lines: list[str], index: int, start: int) -> str:
    """The text from column [start] of line [index] to the close of the call it sits in."""
    text = "\n".join([lines[index][start:]] + [l for l in lines[index + 1:index + WINDOW + 1] if not is_comment(l)])
    depth = 0
    in_string = False
    for position, char in enumerate(text):
        if char == '"' and text[position - 1:position] != "\\":
            in_string = not in_string
        elif not in_string and char == "(":
            depth += 1
        elif not in_string and char == ")":
            depth -= 1
            if depth < 0:
                return text[:position]
    return text


def verb_targets_repository(lines: list[str], index: int, verb: re.Pattern[str]) -> bool:
    """rest.send(Verb.X, repoUrl(owner, name), ...): a call with [verb] on the repository itself."""
    match = verb.search(lines[index])
    return match is not None and REPO_ROOT_CALL.search(rest_of_call(lines, index, match.end())) is not None


def verb_enum_problems(relative: str, text: str, allowed: set[str]) -> list[str]:
    problems = []
    for match in VERB_ENUM.finditer(text):
        verbs = WRITE_VERBS.findall(match.group(1))
        index = text.count("\n", 0, match.start())
        if verbs and f"{relative}: {text.splitlines()[index].strip()}" not in allowed:
            problems.append(f"{relative}:{index + 1}: the GitHub client gained {' and '.join(verbs)} without a reviewed "
                            "entry in least_privilege_allow.txt")
    return problems


def scan(relative: str, text: str, allowed: set[str]) -> list[str]:
    lines = text.splitlines()
    problems = verb_enum_problems(relative, text, allowed)
    for index, line in enumerate(lines):
        if is_comment(line) or f"{relative}: {line.strip()}" in allowed:
            continue
        window = [l for l in lines[max(0, index - WINDOW):index + WINDOW + 1] if not is_comment(l)]
        found = literals(window)
        where = f"{relative}:{index + 1}"
        if (METHOD_DELETE.search(line) and any(REPO_ROOT.search(s) for s in found)) \
                or verb_targets_repository(lines, index, VERB_DELETE):
            problems.append(f"{where}: sends DELETE to a repository itself; PocketIDE never deletes a repository")
        if ((METHOD_PATCH.search(line) and any(REPO_ROOT.search(s) for s in found))
                or verb_targets_repository(lines, index, VERB_PATCH)) \
                and any(VISIBILITY_FIELDS.search(l) for l in window):
            problems.append(f"{where}: PATCHes a repository's visibility or archived state; "
                            "PocketIDE never changes who can see a repository")
        if any(TRANSFER.search(s) for s in literals([line])) or TRANSFER_CALL.search(line):
            problems.append(f"{where}: transfers a repository; PocketIDE never does")
        if GRAPHQL.search(line):
            problems.append(f"{where}: uses a GraphQL repository mutation "
                            f"({GRAPHQL.search(line).group(1)}); PocketIDE never changes a repository that way")
    return problems


def read_allowed(path: Path = ALLOW_FILE) -> set[str]:
    if not path.is_file():
        return set()
    return {l.strip() for l in path.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.lstrip().startswith("#")}


def check(root: Path = common.POCKET, allow: Path = ALLOW_FILE) -> common.Report:
    report = common.Report()
    base = common.kotlin_sources(root)
    allowed = read_allowed(allow)
    files = common.files_under(base, [".kt"])
    if not files:
        report.fail(f"no Kotlin sources under {base}")
    for path in files:
        for problem in scan(path.relative_to(base).as_posix(), path.read_text(encoding="utf-8"), allowed):
            report.fail(problem)
    return report


if __name__ == "__main__":
    sys.exit(common.run_standalone("least privilege (GitHub Administration)", check))
