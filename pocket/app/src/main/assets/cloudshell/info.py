"""PocketIDE's look at Cloud Shell, for the app's Chats and Usage tabs.

The app sends this file over its own connection (Google's gcloud, its ssh) and runs it with
Cloud Shell's python3; it prints one line of JSON and ends. It reads the machine's own numbers and
each agent's own chat files in the owner's home folder. It never reads a sign-in (it only looks
whether an agent's sign-in file is there), sends nothing anywhere, and writes nothing, except
`delete`, which removes the one chat the owner chose, with that chat's lines in the agent's prompt
history.

  status            the machine: how long it has run, processors, memory, the home folder's disk,
                    each agent's VS Code, and PocketIDE's browser
  chats             every chat of the three agents, newest first
  chat AGENT ID     one chat's messages (text; long ones cut, only the newest kept)
  usage             what the agents used in the last day and week, from their own files, and
                    Codex's limits when Codex wrote them down
  extensions        the extensions in each agent's VS Code
  delete AGENT ID   removes one chat of Claude Code or Codex
"""
import glob
import json
import os
import re
import sqlite3
import sys
import time
import urllib.request
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
AGENTS = (("claude-code", 8080, "anthropic.claude-code"), ("codex", 8081, "openai.chatgpt"),
          ("antigravity", 8082, "google.google-antigravity"))
# Agents the owner added (pocketide agent add), each with its own VS Code and port.
ADDED = os.path.join(HOME, ".pocketide", "agents")
ADDED_ENTRY = re.compile(r"^(x-[a-z0-9-]{1,30}):(80(?:8[3-9]|9[0-9])):([A-Za-z0-9][A-Za-z0-9_-]{0,63})/"
                         r"([A-Za-z0-9][A-Za-z0-9_-]{0,63})(?::any)?$")
SIGN_INS = {"claude-code": ".claude/.credentials.json", "codex": ".codex/auth.json"}
CLAUDE = os.path.join(HOME, ".claude")
CODEX = os.path.join(HOME, ".codex")
GEMINI = os.path.join(HOME, ".gemini")
ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
TITLE_CHARS = 120
TEXT_CHARS = 6000
TOOL_CHARS = 300
MESSAGES = 300
CHATS = 500
HEAD_BYTES = 512 * 1024
IN_USE_SECONDS = 120
DAY = 86400
WEEK = 7 * DAY
DEADLINE = time.monotonic() + 25
BROWSER_DEVTOOLS_PORT = 9222
# What Claude Code writes as a user's message but the owner never typed.
NOT_TYPED = ("<command-", "<local-command", "Caveat:", "<system-reminder>", "<bash-", "[Request interrupted")
# What Codex sends as the user's first message: its own context, not the owner's words.
CODEX_CONTEXT = ("<environment_context>", "<user_instructions>", "# AGENTS.md", "<permissions", "<user_shell_command>")


def now_ms():
    return int(time.time() * 1000)


def late():
    return time.monotonic() > DEADLINE


def one_line(text, limit=TITLE_CHARS):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def cut(text, limit=TEXT_CHARS):
    text = str(text).strip()
    return text if len(text) <= limit else text[:limit] + "\n…"


def ms_of(value):
    """Epoch milliseconds of an ISO time, epoch seconds or epoch milliseconds; 0 when unknown."""
    if value is None or value == "":
        return 0
    if isinstance(value, (int, float)):
        return int(value if value > 10**12 else value * 1000)
    text = str(value).strip()
    if text.isdigit():
        return ms_of(int(text))
    # Go and SQLite write up to nine digits of a second and a space before the zone; Python reads six.
    text = re.sub(r"(\.\d{6})\d+", r"\1", text.replace("Z", "+00:00"))
    text = re.sub(r"\s+([+-]\d{2}:?\d{2})(\s+\S+)?$", r"\1", text)
    try:
        moment = datetime.fromisoformat(text.replace(" ", "T", 1))
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=timezone.utc)
        return int(moment.timestamp() * 1000)
    except ValueError:
        return 0


def lines_of(path, head=None):
    """Each line of a JSON-lines file as an object; unreadable lines are skipped."""
    read = 0
    try:
        with open(path, "rb") as source:
            for raw in source:
                read += len(raw)
                if head is not None and read > head:
                    return
                try:
                    value = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def database(path):
    """A read-only connection to an agent's SQLite file, or None."""
    try:
        connection = sqlite3.connect("file:" + path + "?mode=ro", uri=True, timeout=2)
        connection.row_factory = sqlite3.Row
        return connection
    except sqlite3.Error:
        return None


def columns(connection, table):
    try:
        return {row[1] for row in connection.execute("PRAGMA table_info(" + table + ")")}
    except sqlite3.Error:
        return set()


def newest(pattern):
    """The file with the highest number in its name (state_5.sqlite before state_4.sqlite)."""
    def number(path):
        found = re.findall(r"(\d+)", os.path.basename(path))
        return int(found[-1]) if found else -1
    paths = sorted(glob.glob(pattern), key=number)
    return paths[-1] if paths else None


# The machine.

def running(port):
    wanted = ("127.0.0.1:%d" % port).encode()
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/" + pid + "/cmdline", "rb") as source:
                line = source.read()
        except OSError:
            continue
        if b"code-server" in line and wanted in line:
            return True
    return False


def added_agents():
    """The agents the owner added: (name, port, extension id in lower case) each."""
    found = []
    try:
        with open(ADDED, encoding="utf-8") as lines:
            for line in lines:
                match = ADDED_ENTRY.match(line.strip())
                if match:
                    found.append((match.group(1), int(match.group(2)), (match.group(3) + "." + match.group(4)).lower()))
    except OSError:
        pass
    return found


def every_agent():
    return AGENTS + tuple(added_agents())


def extension_title(prefix, key):
    """An installed extension's own name, from its manifest (its translations too); None when unknown."""
    folder = os.path.join(HOME, ".pocketide", "vscode", key, "extensions")
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not re.match(re.escape(prefix) + r"-\d", name.lower()):
            continue
        try:
            with open(os.path.join(folder, name, "package.json"), encoding="utf-8") as source:
                title = str(json.load(source).get("displayName") or "")
            if title.startswith("%") and title.endswith("%"):
                with open(os.path.join(folder, name, "package.nls.json"), encoding="utf-8") as source:
                    title = str(json.load(source).get(title.strip("%")) or "")
        except (OSError, ValueError, AttributeError):
            continue
        return title.strip()[:80] or None
    return None


def extension_version(prefix, key):
    folder = os.path.join(HOME, ".pocketide", "vscode", key, "extensions")
    found = []
    for name in os.listdir(folder) if os.path.isdir(folder) else []:
        match = re.match(re.escape(prefix) + r"-(\d+(?:\.\d+)+)", name)
        if match:
            found.append(tuple(int(part) for part in match.group(1).split(".")))
    return ".".join(str(part) for part in max(found)) if found else None


def answers(port, path):
    """True when this computer's [port] answers [path]: never through a proxy the environment may name."""
    local = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with local.open("http://127.0.0.1:%d%s" % (port, path), timeout=1) as answer:
            return answer.status == 200
    except OSError:
        return False


def browser():
    """PocketIDE's browser: Chrome's version once downloaded, whether it runs, and with Chrome's own sandbox or not."""
    base = os.path.join(HOME, ".pocketide", "browser")
    try:
        with open(os.path.join(base, "chrome", "VERSION")) as source:
            version = source.read().strip() or None
    except OSError:
        version = None
    running = answers(BROWSER_DEVTOOLS_PORT, "/json/version")
    try:
        with open(os.path.join(base, "sandbox")) as source:
            sandbox = source.read().strip() == "on"
    except OSError:
        sandbox = None
    return {"version": version, "running": running, "sandbox": sandbox if running else None}


def status():
    with open("/proc/uptime") as source:
        uptime = float(source.read().split()[0])
    memory = {}
    with open("/proc/meminfo") as source:
        for line in source:
            name, _, rest = line.partition(":")
            parts = rest.split()
            if parts and parts[0].isdigit():
                memory[name] = int(parts[0]) * 1024
    disk = os.statvfs(HOME)
    total = disk.f_blocks * disk.f_frsize
    try:
        with open(os.path.join(HOME, ".pocketide", "updated")) as source:
            updated = int(source.read().strip()) * 1000
    except (OSError, ValueError):
        updated = 0
    current = os.path.join(HOME, ".pocketide", "code-server", "current")
    agents = []
    for key, port, prefix in every_agent():
        sign_in = SIGN_INS.get(key)
        agent = {
            "agent": key,
            "port": port,
            "running": running(port),
            "version": extension_version(prefix, key),
            "signedIn": os.path.isfile(os.path.join(HOME, sign_in)) if sign_in else None,
        }
        if key.startswith("x-"):
            agent["extension"] = prefix
            agent["name"] = extension_title(prefix, key) or prefix
        agents.append(agent)
    return {
        "ok": True,
        "now": now_ms(),
        "uptimeSeconds": int(uptime),
        "processors": os.cpu_count() or 1,
        "load": [round(value, 2) for value in os.getloadavg()],
        "memoryTotal": memory.get("MemTotal", 0),
        "memoryAvailable": memory.get("MemAvailable", memory.get("MemFree", 0)),
        "homeTotal": total,
        "homeUsed": total - disk.f_bfree * disk.f_frsize,
        "homeFree": disk.f_bavail * disk.f_frsize,
        "codeServer": os.path.basename(os.path.realpath(current)) if os.path.exists(current) else None,
        "updated": updated,
        "agents": agents,
        "browser": browser(),
    }


# Claude Code: ~/.claude/projects/<the project's folder, as a name>/<session id>.jsonl

def claude_files(chat_id="*"):
    return [path for path in glob.glob(os.path.join(CLAUDE, "projects", "*", chat_id + ".jsonl")) if os.path.isfile(path)]


def claude_text(content):
    """What the owner typed in a Claude Code user message; None for a tool's answer or Claude Code's own note."""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = "\n".join(block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text")
        if any(isinstance(block, dict) and block.get("type") == "image" for block in content):
            text = (text + "\n[image]").strip()
    else:
        return None
    text = text.strip()
    if not text or text.startswith(NOT_TYPED):
        return None
    return text


def claude_chats():
    found = []
    for path in claude_files():
        if late():
            break
        chat_id = os.path.basename(path)[: -len(".jsonl")]
        if not ID.match(chat_id):
            continue
        info = os.stat(path)
        summary = typed = cwd = None
        created = 0
        for entry in lines_of(path, HEAD_BYTES):
            kind = entry.get("type")
            if kind == "summary" and entry.get("summary") and not summary:
                summary = entry["summary"]
            if not cwd and entry.get("cwd"):
                cwd = entry["cwd"]
            if not created and entry.get("timestamp"):
                created = ms_of(entry["timestamp"])
            if kind == "user" and not typed and not entry.get("isMeta") and not entry.get("isSidechain"):
                typed = claude_text((entry.get("message") or {}).get("content"))
            if summary and typed and cwd:
                break
        if not typed and not summary:
            continue  # nothing the owner said: no chat to show
        found.append({
            "agent": "claude-code",
            "id": chat_id,
            "title": one_line(summary or typed),
            "project": cwd or "",
            "created": created or int(info.st_mtime * 1000),
            "updated": int(info.st_mtime * 1000),
            "bytes": info.st_size,
        })
    return found


def tool_line(name, given):
    """A tool call in a few words: the command, the file or the address it was for."""
    if isinstance(given, str):
        try:
            given = json.loads(given)
        except ValueError:
            return one_line(name + ": " + given, TOOL_CHARS)
    detail = ""
    if isinstance(given, dict):
        for field in ("command", "cmd", "file_path", "path", "pattern", "url", "query", "description", "prompt"):
            value = given.get(field)
            if value:
                detail = " ".join(value) if isinstance(value, list) else str(value)
                break
    return one_line(name + (": " + detail if detail else ""), TOOL_CHARS)


def claude_chat(chat_id):
    paths = claude_files(chat_id)
    if not paths:
        return None
    messages = []
    title = None
    for entry in lines_of(paths[0]):
        kind = entry.get("type")
        when = ms_of(entry.get("timestamp"))
        if kind == "summary" and entry.get("summary"):
            title = entry["summary"]
        if entry.get("isSidechain") or entry.get("isMeta"):
            continue
        message = entry.get("message") or {}
        if kind == "user":
            text = claude_text(message.get("content"))
            if text:
                messages.append({"role": "user", "text": cut(text), "time": when})
                title = title or text
        elif kind == "assistant":
            for block in message.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text" and block.get("text", "").strip():
                    last = messages[-1] if messages else None
                    if last and last["role"] == "agent" and last.get("key") == message.get("id"):
                        last["text"] = cut(last["text"] + "\n\n" + block["text"])
                    else:
                        messages.append({"role": "agent", "text": cut(block["text"]), "time": when, "key": message.get("id")})
                elif block.get("type") == "tool_use":
                    messages.append({"role": "tool", "text": tool_line(block.get("name", "tool"), block.get("input")), "time": when})
    for message in messages:
        message.pop("key", None)
    return {"title": one_line(title or "Chat"), "messages": messages}


# Codex: its threads in ~/.codex/state_<n>.sqlite, each chat in a rollout file under ~/.codex/sessions

def codex_threads():
    path = newest(os.path.join(CODEX, "state_*.sqlite"))
    connection = database(path) if path else None
    if connection is None:
        return None
    try:
        have = columns(connection, "threads")
        wanted = [name for name in ("id", "title", "first_user_message", "cwd", "created_at", "updated_at",
                                    "rollout_path", "tokens_used", "archived") if name in have]
        if "id" not in wanted:
            return None
        rows = connection.execute("SELECT " + ", ".join(wanted) + " FROM threads").fetchall()
        return [dict(row) for row in rows]
    except sqlite3.Error:
        return None
    finally:
        connection.close()


def codex_rollouts(since=0):
    paths = glob.glob(os.path.join(CODEX, "sessions", "*", "*", "*", "rollout-*.jsonl"))
    paths += glob.glob(os.path.join(CODEX, "archived_sessions", "rollout-*.jsonl"))
    return [path for path in paths if os.path.getmtime(path) >= since]


def codex_rollout_of(chat_id, thread=None):
    path = (thread or {}).get("rollout_path")
    if path and os.path.isfile(path):
        return path
    for candidate in codex_rollouts():
        if os.path.basename(candidate).endswith(chat_id + ".jsonl"):
            return candidate
    return None


def codex_typed(text):
    text = (text or "").strip()
    return None if not text or text.startswith(CODEX_CONTEXT) else text


def codex_chats():
    threads = codex_threads()
    found = []
    if threads is not None:
        for thread in threads:
            chat_id = str(thread.get("id") or "")
            if not ID.match(chat_id):
                continue
            title = thread.get("title") or codex_typed(thread.get("first_user_message")) or "Chat"
            found.append({
                "agent": "codex",
                "id": chat_id,
                "title": one_line(title),
                "project": thread.get("cwd") or "",
                "created": ms_of(thread.get("created_at")),
                "updated": ms_of(thread.get("updated_at")),
                "tokens": thread.get("tokens_used") or 0,
                "archived": bool(thread.get("archived")),
            })
        return found
    for path in codex_rollouts():
        if late():
            break
        chat_id = cwd = typed = None
        for entry in lines_of(path, HEAD_BYTES):
            payload = entry.get("payload") or {}
            if entry.get("type") == "session_meta":
                chat_id = payload.get("id") or chat_id
                cwd = payload.get("cwd") or cwd
            elif entry.get("type") == "event_msg" and payload.get("type") == "user_message" and not typed:
                typed = codex_typed(payload.get("message"))
            if chat_id and typed:
                break
        chat_id = chat_id or os.path.basename(path)[: -len(".jsonl")].split("-", 6)[-1]
        if not typed or not ID.match(str(chat_id)):
            continue
        found.append({
            "agent": "codex",
            "id": str(chat_id),
            "title": one_line(typed),
            "project": cwd or "",
            "created": int(os.path.getctime(path) * 1000),
            "updated": int(os.path.getmtime(path) * 1000),
        })
    return found


def codex_chat(chat_id):
    threads = codex_threads() or []
    thread = next((each for each in threads if str(each.get("id")) == chat_id), None)
    path = codex_rollout_of(chat_id, thread)
    if not path:
        return None
    messages = []
    said = []
    for entry in lines_of(path):
        payload = entry.get("payload") or {}
        kind = payload.get("type")
        when = ms_of(entry.get("timestamp"))
        if entry.get("type") == "event_msg" and kind == "user_message":
            text = codex_typed(payload.get("message"))
            if text:
                messages.append({"role": "user", "text": cut(text), "time": when})
        elif entry.get("type") == "event_msg" and kind == "agent_message" and (payload.get("message") or "").strip():
            messages.append({"role": "agent", "text": cut(payload["message"]), "time": when})
        elif entry.get("type") == "response_item" and kind in ("function_call", "custom_tool_call", "local_shell_call"):
            given = payload.get("arguments") or payload.get("input") or payload.get("action") or {}
            messages.append({"role": "tool", "text": tool_line(payload.get("name") or "shell", given), "time": when})
        elif entry.get("type") == "response_item" and kind == "message":
            role = payload.get("role")
            text = "\n".join(part.get("text", "") for part in payload.get("content") or []
                             if isinstance(part, dict) and part.get("type") in ("input_text", "output_text"))
            if role in ("user", "assistant") and text.strip():
                said.append({"role": "user" if role == "user" else "agent", "text": cut(text), "time": when})
    if not any(message["role"] != "tool" for message in messages):
        # An older rollout, without the events: the messages themselves, without Codex's own context.
        messages = [message for message in said if message["role"] == "agent" or codex_typed(message["text"])] + \
            [message for message in messages if message["role"] == "tool"]
        messages.sort(key=lambda message: message["time"])
    title = (thread or {}).get("title") or next((message["text"] for message in messages if message["role"] == "user"), "Chat")
    return {"title": one_line(title), "messages": messages}


# Antigravity: ~/.gemini/antigravity (its VS Code extension) and ~/.gemini/antigravity-cli (agy):
# a list of the chats in conversation_summaries.db, each chat's own files in brain/<id>.

def antigravity_roots():
    return [path for path in (os.path.join(GEMINI, "antigravity"), os.path.join(GEMINI, "antigravity-cli")) if os.path.isdir(path)]


def antigravity_rows(root):
    connection = database(os.path.join(root, "conversation_summaries.db"))
    if connection is None:
        return []
    try:
        have = columns(connection, "conversation_summaries")
        wanted = [name for name in ("conversation_id", "title", "preview", "step_count", "last_modified_time", "workspace_uris")
                  if name in have]
        if "conversation_id" not in wanted:
            return []
        return [dict(row) for row in connection.execute("SELECT " + ", ".join(wanted) + " FROM conversation_summaries")]
    except sqlite3.Error:
        return []
    finally:
        connection.close()


def workspace(uris):
    """The first folder of a chat's workspace list (a JSON list or plain text of file:// addresses)."""
    text = str(uris or "")
    try:
        value = json.loads(text)
        if isinstance(value, list) and value:
            text = str(value[0])
    except ValueError:
        pass
    match = re.search(r"file://([^\s\"',\]]+)", text)
    return match.group(1) if match else ""


def antigravity_chats():
    found = {}
    for root in antigravity_roots():
        for row in antigravity_rows(root):
            chat_id = str(row.get("conversation_id") or "")
            if not ID.match(chat_id):
                continue
            found[chat_id] = {
                "agent": "antigravity",
                "id": chat_id,
                "title": one_line(row.get("title") or row.get("preview") or "Chat"),
                "project": workspace(row.get("workspace_uris")),
                "created": 0,
                "updated": ms_of(row.get("last_modified_time")),
                "steps": row.get("step_count") or 0,
            }
        for path in glob.glob(os.path.join(root, "conversations", "*.pb")):
            chat_id = os.path.basename(path)[: -len(".pb")]
            if ID.match(chat_id) and chat_id not in found:
                found[chat_id] = {
                    "agent": "antigravity",
                    "id": chat_id,
                    "title": one_line(antigravity_heading(root, chat_id) or "Chat"),
                    "project": "",
                    "created": 0,
                    "updated": int(os.path.getmtime(path) * 1000),
                }
    for chat in found.values():
        chat["created"] = chat["created"] or chat["updated"]
    return list(found.values())


def antigravity_heading(root, chat_id):
    for name in ("task.md", "implementation_plan.md", "walkthrough.md"):
        try:
            with open(os.path.join(root, "brain", chat_id, name), encoding="utf-8", errors="replace") as source:
                for line in source:
                    if line.strip():
                        return line.strip().lstrip("#").strip()
        except OSError:
            continue
    return None


def antigravity_chat(chat_id):
    for root in antigravity_roots():
        row = next((each for each in antigravity_rows(root) if str(each.get("conversation_id")) == chat_id), None)
        brain = os.path.join(root, "brain", chat_id)
        if row is None and not os.path.isdir(brain) and not os.path.isfile(os.path.join(root, "conversations", chat_id + ".pb")):
            continue
        messages = []
        if row and row.get("preview"):
            messages.append({"role": "user", "text": cut(row["preview"]), "time": ms_of(row.get("last_modified_time"))})
        # Antigravity keeps the conversation itself in its own binary format; its artifacts (the task,
        # the plan, the walkthrough) are plain text.
        for path in sorted(glob.glob(os.path.join(brain, "*.md")), key=os.path.getmtime):
            try:
                with open(path, encoding="utf-8", errors="replace") as source:
                    text = source.read()
            except OSError:
                continue
            messages.append({"role": "artifact", "name": os.path.basename(path), "text": cut(text), "time": int(os.path.getmtime(path) * 1000)})
        title = (row or {}).get("title") or antigravity_heading(root, chat_id) or "Chat"
        return {"title": one_line(title), "messages": messages}
    return None


def chats():
    found = []
    problems = []
    for agent, collect in (("claude-code", claude_chats), ("codex", codex_chats), ("antigravity", antigravity_chats)):
        try:
            found.extend(collect())
        except Exception as error:  # one agent's files must never hide the others' chats
            problems.append({"agent": agent, "error": type(error).__name__})
    found.sort(key=lambda chat: chat["updated"], reverse=True)
    return {"ok": True, "now": now_ms(), "chats": found[:CHATS], "more": max(0, len(found) - CHATS), "problems": problems, "partial": late()}


def chat(agent, chat_id):
    read = {"claude-code": claude_chat, "codex": codex_chat, "antigravity": antigravity_chat}.get(agent)
    if read is None or not ID.match(chat_id):
        return {"ok": False, "error": "No such chat."}
    found = read(chat_id)
    if found is None:
        return {"ok": False, "error": "That chat is not in Cloud Shell any more."}
    messages = found["messages"]
    return {"ok": True, "agent": agent, "id": chat_id, "title": found["title"], "messages": messages[-MESSAGES:],
            "earlier": max(0, len(messages) - MESSAGES)}


# Deleting a chat: its own file, and its lines in the agent's prompt history.

def drop_history(path, field, chat_id):
    """Rewrites a JSON-lines prompt history without [chat_id]'s lines (a new file, moved into place)."""
    if not os.path.isfile(path):
        return
    kept = []
    with open(path, "rb") as source:
        for raw in source:
            try:
                value = json.loads(raw)
            except ValueError:
                kept.append(raw)
                continue
            if not (isinstance(value, dict) and str(value.get(field)) == chat_id):
                kept.append(raw)
    temporary = path + ".pocketide"
    with open(temporary, "wb") as out:
        out.writelines(kept)
    os.chmod(temporary, os.stat(path).st_mode & 0o777)
    os.replace(temporary, path)


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        for root, folders, files in os.walk(path, topdown=False):
            for name in files:
                os.remove(os.path.join(root, name))
            for name in folders:
                target = os.path.join(root, name)
                os.remove(target) if os.path.islink(target) else os.rmdir(target)
        os.rmdir(path)
    elif os.path.lexists(path):
        os.remove(path)


def in_use(path):
    return time.time() - os.path.getmtime(path) < IN_USE_SECONDS


def delete(agent, chat_id):
    if not ID.match(chat_id):
        return {"ok": False, "error": "No such chat."}
    if agent == "claude-code":
        paths = claude_files(chat_id)
        if not paths:
            return {"ok": False, "error": "That chat is not in Cloud Shell any more."}
        if any(in_use(path) for path in paths):
            return {"ok": False, "error": "Claude Code wrote to this chat in the last two minutes. Close it there first."}
        for path in paths:
            remove(path)
            remove(path[: -len(".jsonl")])  # its subagents' chats
        for path in glob.glob(os.path.join(CLAUDE, "todos", chat_id + "-*.json")):
            remove(path)
        for folder in ("file-history", "session-env"):
            remove(os.path.join(CLAUDE, folder, chat_id))
        drop_history(os.path.join(CLAUDE, "history.jsonl"), "sessionId", chat_id)
        return {"ok": True}
    if agent == "codex":
        threads = codex_threads() or []
        thread = next((each for each in threads if str(each.get("id")) == chat_id), None)
        path = codex_rollout_of(chat_id, thread)
        if thread is None and path is None:
            return {"ok": False, "error": "That chat is not in Cloud Shell any more."}
        if path and in_use(path):
            return {"ok": False, "error": "Codex wrote to this chat in the last two minutes. Close it there first."}
        if path:
            remove(path)
        if thread is not None:
            state = newest(os.path.join(CODEX, "state_*.sqlite"))
            connection = sqlite3.connect(state, timeout=5)
            try:
                connection.execute("PRAGMA foreign_keys = ON")
                connection.execute("DELETE FROM threads WHERE id = ?", (chat_id,))
                connection.commit()
            finally:
                connection.close()
        drop_history(os.path.join(CODEX, "history.jsonl"), "session_id", chat_id)
        return {"ok": True}
    if agent == "antigravity":
        return {"ok": False, "error": "Delete Antigravity's chats in Antigravity itself, in its chat history."}
    return {"ok": False, "error": "No such chat."}


# Usage: from the agents' own files, never from a sign-in.

def tokens():
    return {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}


def add(total, usage, read, write, given, made):
    total["input"] += int(usage.get(given) or 0)
    total["output"] += int(usage.get(made) or 0)
    total["cacheRead"] += int(usage.get(read) or 0)
    total["cacheWrite"] += int(usage.get(write) or 0)


def claude_usage(now):
    day, week = tokens(), tokens()
    chats_week = set()
    for path in claude_files():
        if late():
            break
        if os.path.getmtime(path) * 1000 < now - WEEK * 1000:
            continue
        seen = set()
        with open(path, "rb") as source:
            for raw in source:
                if b'"usage"' not in raw or b'"assistant"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                message = entry.get("message") or {}
                usage = message.get("usage")
                key = message.get("id") or entry.get("uuid")
                if entry.get("type") != "assistant" or not isinstance(usage, dict) or key in seen:
                    continue
                seen.add(key)
                when = ms_of(entry.get("timestamp"))
                if when < now - WEEK * 1000:
                    continue
                chats_week.add(path)
                for total, span in ((week, WEEK), (day, DAY)):
                    if when >= now - span * 1000:
                        add(total, usage, "cache_read_input_tokens", "cache_creation_input_tokens", "input_tokens", "output_tokens")
    return {"day": day, "week": week, "chats": len(chats_week)}


def codex_usage(now):
    day, week = tokens(), tokens()
    limits = None
    limits_at = 0
    chats_week = set()
    for path in codex_rollouts(since=(now - WEEK * 1000) / 1000):
        if late():
            break
        with open(path, "rb") as source:
            for raw in source:
                if b'"token_count"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                payload = entry.get("payload") or {}
                if payload.get("type") != "token_count":
                    continue
                when = ms_of(entry.get("timestamp"))
                if isinstance(payload.get("rate_limits"), dict) and when >= limits_at:
                    limits, limits_at = payload["rate_limits"], when
                last = ((payload.get("info") or {}).get("last_token_usage")) or {}
                if when < now - WEEK * 1000 or not last:
                    continue
                chats_week.add(path)
                for total, span in ((week, WEEK), (day, DAY)):
                    if when >= now - span * 1000:
                        total["input"] += int(last.get("input_tokens") or 0) - int(last.get("cached_input_tokens") or 0)
                        total["cacheRead"] += int(last.get("cached_input_tokens") or 0)
                        total["output"] += int(last.get("output_tokens") or 0)
    windows = []
    for name in ("primary", "secondary"):
        window = (limits or {}).get(name)
        if isinstance(window, dict) and window.get("used_percent") is not None:
            windows.append({"usedPercent": float(window["used_percent"]), "minutes": window.get("window_minutes"),
                            "resetsAt": ms_of(window.get("resets_at"))})
    return {"day": day, "week": week, "chats": len(chats_week), "limits": windows, "limitsAt": limits_at}


def antigravity_usage(now):
    chats_day = chats_week = steps_week = 0
    for chat in antigravity_chats():
        if chat["updated"] >= now - WEEK * 1000:
            chats_week += 1
            steps_week += int(chat.get("steps") or 0)
            if chat["updated"] >= now - DAY * 1000:
                chats_day += 1
    return {"chatsDay": chats_day, "chats": chats_week, "steps": steps_week}


def usage():
    now = now_ms()
    result = {"ok": True, "now": now}
    for agent, measure in (("claude", claude_usage), ("codex", codex_usage), ("antigravity", antigravity_usage)):
        try:
            result[agent] = measure(now)
        except Exception as error:  # one agent's files must never hide the others' numbers
            result[agent] = {"error": type(error).__name__}
    result["partial"] = late()
    return result


def extensions():
    """The extensions in each agent's VS Code, from VS Code's own list of them (newest version each)."""
    found = {}
    for key, _port, own in every_agent():
        listed = {}
        path = os.path.join(HOME, ".pocketide", "vscode", key, "extensions", "extensions.json")
        try:
            with open(path, encoding="utf-8") as source:
                entries = json.load(source)
        except (OSError, ValueError):
            entries = []
        for entry in entries if isinstance(entries, list) else []:
            ident = str(((entry or {}).get("identifier") or {}).get("id") or "")
            if not ident:
                continue
            listed[ident.lower()] = {
                "id": ident,
                "version": str(entry.get("version") or ""),
                "own": ident.lower() in (own, "pocketide.layout"),
            }
        found[key] = sorted(listed.values(), key=lambda item: item["id"].lower())
    return {"ok": True, "agents": found}


def main(argv):
    command = argv[0] if argv else ""
    try:
        if command == "status" and len(argv) == 1:
            result = status()
        elif command == "chats" and len(argv) == 1:
            result = chats()
        elif command == "chat" and len(argv) == 3:
            result = chat(argv[1], argv[2])
        elif command == "usage" and len(argv) == 1:
            result = usage()
        elif command == "delete" and len(argv) == 3:
            result = delete(argv[1], argv[2])
        elif command == "extensions" and len(argv) == 1:
            result = extensions()
        else:
            result = {"ok": False, "error": "PocketIDE asked for something this script does not do."}
    except Exception as error:
        result = {"ok": False, "error": "%s: %s" % (type(error).__name__, error)}
    sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main(sys.argv[1:])
