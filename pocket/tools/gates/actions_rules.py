"""Rules shared by the workflow gate and the templates gate: how a `uses:` must be pinned."""
from __future__ import annotations

import re

USES_LINE = re.compile(r"^\s*(?:-\s+)?uses:\s*(?P<value>[^\s#]+)(?P<comment>\s+#.*)?$")
SHA = re.compile(r"^[0-9a-f]{40}$")
DOCKER_DIGEST = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")
TAG_COMMENT = re.compile(r"#\s*v\d+(\.\d+)*\b")


def uses_lines(text: str) -> list[tuple[int, str, str]]:
    """(line number, action reference, trailing comment) for every `uses:` line."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        match = USES_LINE.match(line)
        if match:
            found.append((number, match.group("value").strip("'\""), (match.group("comment") or "").strip()))
    return found


def pin_problem(reference: str) -> str | None:
    """Why this reference is not pinned to an exact, immutable version, or None when it is."""
    if reference.startswith("./"):
        return None
    if reference.startswith("docker://"):
        return None if DOCKER_DIGEST.match(reference) else "a container must be pinned by @sha256 digest"
    action, _, ref = reference.partition("@")
    if not ref:
        return "has no version at all"
    if not SHA.match(ref):
        return f"is pinned to '{ref}', which can move; pin the full 40-character commit SHA"
    if action.count("/") < 1:
        return "is not an owner/repo reference"
    return None


def action_name(reference: str) -> str:
    return reference.partition("@")[0]


def walk(node, path=()):
    """Yields (path, value) for every scalar in a parsed YAML tree."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield from walk(value, path + (key,))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from walk(value, path + (index,))
    else:
        yield path, node


def write_grants(permissions) -> list[str]:
    """The scopes a `permissions:` value grants write access to."""
    if permissions in ("write-all",):
        return ["everything (write-all)"]
    if isinstance(permissions, dict):
        return sorted(scope for scope, level in permissions.items() if str(level).strip() == "write")
    return []
