"""Just enough YAML to read a GitHub Actions workflow, with the standard library only.

Block maps, block lists (including "- key: value" items), flow lists, quoted and plain scalars
and block scalars (| and >). Every scalar stays a string, and "on" stays the key "on": YAML 1.1
readers turn it into True, which is exactly the key a workflow gate needs to find. Anchors, tags
and multi-document files are not supported; a workflow that needs them fails to parse, loudly.
"""
from __future__ import annotations


class YamlError(ValueError):
    pass


def load(text: str):
    return _Parser(text).document()


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _strip_comment(value: str) -> str:
    """Removes a trailing " # comment" outside quotes."""
    quote = None
    for i, ch in enumerate(value):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or value[i - 1] in " \t"):
            return value[:i].rstrip()
    return value.rstrip()


def _split_key(content: str) -> tuple[str, str] | None:
    """("key", "rest") for "key: rest" or "key:", honouring a quoted key; None otherwise."""
    if content[:1] and content[0] in "'\"":
        end = content.find(content[0], 1)
        if end < 0 or content[end + 1:end + 2] != ":":
            return None
        rest = content[end + 2:]
        if rest and not rest.startswith((" ", "\t")):
            return None
        return content[1:end], rest.strip()
    for i, ch in enumerate(content):
        if ch == ":" and (i + 1 == len(content) or content[i + 1] in " \t"):
            key = content[:i].strip()
            if not key or key.startswith(("[", "{", "#")):
                return None
            return key, content[i + 1:].strip()
        if ch == "#" and i > 0 and content[i - 1] in " \t":
            return None
    return None


def _scalar(raw: str):
    value = _strip_comment(raw).strip()
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        return [_scalar(item) for item in _split_flow(inner)] if inner else []
    if value.startswith("{") and value.endswith("}"):
        inner = value[1:-1].strip()
        result = {}
        for item in _split_flow(inner) if inner else []:
            pair = _split_key(item.strip())
            if pair is None:
                raise YamlError(f"cannot read flow map entry {item!r}")
            result[pair[0]] = _scalar(pair[1]) if pair[1] else None
        return result
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        body = value[1:-1]
        return body.replace("''", "'") if value[0] == "'" else body.replace('\\"', '"')
    if value in ("", "~", "null"):
        return None
    return value


def _split_flow(inner: str) -> list[str]:
    items, depth, quote, start = [], 0, None, 0
    for i, ch in enumerate(inner):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == "," and depth == 0:
            items.append(inner[start:i].strip())
            start = i + 1
    items.append(inner[start:].strip())
    return [item for item in items if item]


class _Parser:
    def __init__(self, text: str):
        self.lines = text.replace("\t", "    ").splitlines()
        self.i = 0

    def _peek(self) -> tuple[int, str] | None:
        while self.i < len(self.lines):
            stripped = self.lines[self.i].strip()
            if stripped and not stripped.startswith("#") and stripped != "---":
                return _indent(self.lines[self.i]), stripped
            self.i += 1
        return None

    def _error(self, message: str) -> YamlError:
        return YamlError(f"line {self.i + 1}: {message}")

    def document(self):
        first = self._peek()
        if first is None:
            return None
        value = self._node(first[0])
        if self._peek() is not None:
            raise self._error("unexpected content after the document")
        return value

    def _node(self, indent: int):
        _, content = self._peek()
        if content == "-" or content.startswith("- "):
            return self._list(indent)
        return self._map(indent)

    def _map(self, indent: int) -> dict:
        result: dict = {}
        while (line := self._peek()) is not None:
            at, content = line
            if at < indent or (at == indent and (content == "-" or content.startswith("- "))):
                break
            if at > indent:
                raise self._error("unexpected indentation")
            pair = _split_key(content)
            if pair is None:
                raise self._error(f"expected 'key: value', found {content!r}")
            key, rest = pair
            if key in result:
                raise self._error(f"duplicate key {key!r}")
            self.i += 1
            result[key] = self._value(rest, indent)
        return result

    def _value(self, rest: str, indent: int):
        rest = _strip_comment(rest)
        if rest[:1] and rest[0] in "|>":
            return self._block_scalar(indent, header=rest)
        if rest:
            return _scalar(rest)
        line = self._peek()
        if line is None:
            return None
        at, content = line
        if at > indent:
            return self._node(at)
        if at == indent and (content == "-" or content.startswith("- ")):
            return self._list(indent)
        return None

    def _list(self, indent: int) -> list:
        items = []
        while (line := self._peek()) is not None:
            at, content = line
            if at != indent or not (content == "-" or content.startswith("- ")):
                break
            body = content[1:].lstrip()
            if not body:
                self.i += 1
                items.append(self._value("", indent))
            elif _split_key(body) is not None and body[:1] not in "[{":
                # "- key: value": the item is a map whose first key sits where body starts.
                column = at + (len(content) - len(body))
                self.lines[self.i] = " " * column + body
                items.append(self._map(column))
            else:
                self.i += 1
                items.append(_scalar(body))
        return items

    def _block_scalar(self, indent: int, header: str) -> str:
        """A | or > block: "-" strips the final line break, "+" keeps every trailing one."""
        collected = []
        while self.i < len(self.lines):
            line = self.lines[self.i]
            if line.strip() and _indent(line) <= indent:
                break
            collected.append(line)
            self.i += 1
        trailing = 0
        while collected and not collected[-1].strip():
            collected.pop()
            trailing += 1
        body_indent = min((_indent(l) for l in collected if l.strip()), default=0)
        text_lines = [l[body_indent:] for l in collected]
        body = (" " if header.startswith(">") else "\n").join(text_lines)
        if "-" in header or not body:
            return body
        return body + "\n" * (1 + trailing if "+" in header else 1)
