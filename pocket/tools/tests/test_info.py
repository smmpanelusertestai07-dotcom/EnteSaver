"""The app's look at Cloud Shell (app/src/main/assets/cloudshell/info.py), against a home folder
with each agent's chat files as the agents write them."""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

INFO = Path(__file__).resolve().parents[2] / "app" / "src" / "main" / "assets" / "cloudshell" / "info.py"
CLAUDE_ID = "11111111-2222-3333-4444-555555555555"
CODEX_ID = "019a0000-1111-7222-8333-944444444444"
AGY_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
AGY_ORPHAN = "ffffffff-0000-1111-2222-333333333333"


def iso(seconds_ago: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - seconds_ago))


def lines(path: Path, entries: list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join((entry if isinstance(entry, str) else json.dumps(entry)) + "\n" for entry in entries))


def age(path: Path, seconds: float) -> None:
    moment = time.time() - seconds
    os.utime(path, (moment, moment))


class Info(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.home = Path(self.folder.name)
        self.claude()
        self.codex()
        self.antigravity()

    def tearDown(self):
        self.folder.cleanup()

    def run_info(self, *argv: str) -> dict:
        done = subprocess.run([sys.executable, str(INFO), *argv], capture_output=True, text=True,
                              env={**os.environ, "HOME": str(self.home)}, timeout=60, check=True)
        self.assertEqual(1, len(done.stdout.splitlines()), done.stdout)
        return json.loads(done.stdout)

    def claude(self):
        usage = {"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 200}
        self.claude_chat = self.home / ".claude" / "projects" / "-home-me-projects-claude-code" / f"{CLAUDE_ID}.jsonl"
        base = {"sessionId": CLAUDE_ID, "cwd": "/home/me/projects/claude-code"}
        lines(self.claude_chat, [
            {**base, "type": "user", "isMeta": True, "timestamp": iso(600), "message": {"role": "user", "content": "Caveat: messages below"}},
            {**base, "type": "user", "timestamp": iso(590), "message": {"role": "user", "content": "Add a login page"}},
            {**base, "type": "assistant", "timestamp": iso(580),
             "message": {"id": "msg_1", "role": "assistant", "content": [{"type": "text", "text": "Sure, I'll add it."}], "usage": usage}},
            {**base, "type": "assistant", "timestamp": iso(579),
             "message": {"id": "msg_1", "role": "assistant", "content": [{"type": "tool_use", "name": "Bash", "input": {"command": "npm test"}}],
                         "usage": usage}},
            {**base, "type": "user", "timestamp": iso(570), "message": {"role": "user", "content": [{"type": "tool_result", "content": "ok"}]}},
            "not json at all",
            {**base, "type": "assistant", "timestamp": iso(560),
             "message": {"id": "msg_2", "role": "assistant", "content": [{"type": "thinking", "thinking": "hm"}, {"type": "text", "text": "Done."}],
                         "usage": {"input_tokens": 10, "output_tokens": 5}}},
        ])
        age(self.claude_chat, 300)
        old = self.home / ".claude" / "projects" / "-home-me-old" / "99999999-2222-3333-4444-555555555555.jsonl"
        lines(old, [{"type": "user", "timestamp": iso(20 * 86400), "message": {"content": "Old work"}},
                    {"type": "assistant", "timestamp": iso(20 * 86400), "message": {"id": "msg_old", "content": [], "usage": {"output_tokens": 9999}}}])
        age(old, 20 * 86400)
        lines(self.home / ".claude" / "history.jsonl", [
            {"display": "Add a login page", "sessionId": CLAUDE_ID},
            {"display": "Old work", "sessionId": "99999999-2222-3333-4444-555555555555"},
        ])
        (self.home / ".claude" / "todos").mkdir(parents=True)
        (self.home / ".claude" / "todos" / f"{CLAUDE_ID}-agent-{CLAUDE_ID}.json").write_text("[]")
        (self.home / ".claude" / ".credentials.json").write_text("{}")

    def codex(self):
        codex = self.home / ".codex"
        self.codex_chat = codex / "sessions" / "2026" / "10" / "01" / f"rollout-2026-10-01T08-00-00-{CODEX_ID}.jsonl"
        lines(self.codex_chat, [
            {"timestamp": iso(900), "type": "session_meta", "payload": {"id": CODEX_ID, "cwd": "/home/me/projects/codex"}},
            {"timestamp": iso(899), "type": "response_item",
             "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "<environment_context>cwd</environment_context>"}]}},
            {"timestamp": iso(898), "type": "event_msg", "payload": {"type": "user_message", "message": "Fix the build"}},
            {"timestamp": iso(897), "type": "response_item",
             "payload": {"type": "function_call", "name": "exec_command", "arguments": json.dumps({"cmd": ["bash", "-lc", "make"]})}},
            {"timestamp": iso(896), "type": "event_msg", "payload": {"type": "token_count", "rate_limits": None,
             "info": {"last_token_usage": {"input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": 30}}}},
            {"timestamp": iso(895), "type": "event_msg", "payload": {"type": "agent_message", "message": "Fixed."}},
            {"timestamp": iso(894), "type": "event_msg", "payload": {"type": "token_count",
             "info": {"last_token_usage": {"input_tokens": 500, "cached_input_tokens": 0, "output_tokens": 20}},
             "rate_limits": {"primary": {"used_percent": 42.5, "window_minutes": 300, "resets_at": int(time.time()) + 3600},
                             "secondary": {"used_percent": 7.0, "window_minutes": 10080, "resets_at": int(time.time()) + 86400}}}},
        ])
        age(self.codex_chat, 400)
        for name, title in (("state_4.sqlite", "From an older Codex"), ("state_5.sqlite", "Fix the build")):
            connection = sqlite3.connect(codex / name)
            connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, "
                               "updated_at INTEGER NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, tokens_used INTEGER NOT NULL DEFAULT 0, "
                               "archived INTEGER NOT NULL DEFAULT 0, first_user_message TEXT)")
            connection.execute("INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)",
                               (CODEX_ID, str(self.codex_chat), int(time.time()) - 900, int(time.time()) - 400,
                                "/home/me/projects/codex", title, 1550, "Fix the build"))
            connection.commit()
            connection.close()
        lines(codex / "history.jsonl", [{"session_id": CODEX_ID, "text": "Fix the build"}, {"session_id": "other", "text": "keep"}])

    def antigravity(self):
        root = self.home / ".gemini" / "antigravity"
        (root / "brain" / AGY_ID).mkdir(parents=True)
        (root / "brain" / AGY_ID / "task.md").write_text("# Build the app\n- [ ] the first step\n")
        (root / "brain" / AGY_ORPHAN).mkdir(parents=True)
        (root / "brain" / AGY_ORPHAN / "implementation_plan.md").write_text("\n# Plan the API\n")
        (root / "conversations").mkdir(parents=True)
        for chat_id in (AGY_ID, AGY_ORPHAN):
            (root / "conversations" / f"{chat_id}.pb").write_bytes(b"\x08\x01\x12\x03abc")
        connection = sqlite3.connect(root / "conversation_summaries.db")
        connection.execute("CREATE TABLE `conversation_summaries` (`conversation_id` text,`title` text NOT NULL DEFAULT \"\","
                           "`preview` text NOT NULL DEFAULT \"\",`step_count` integer NOT NULL DEFAULT 0,"
                           "`last_modified_time` datetime NOT NULL,`workspace_uris` text NOT NULL)")
        connection.execute("INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?, ?)",
                            (AGY_ID, "Build the app", "Make a todo app", 12,
                             time.strftime("%Y-%m-%d %H:%M:%S.123456789+00:00", time.gmtime(time.time() - 100)),
                             json.dumps(["file:///home/me/projects/antigravity"])))
        connection.commit()
        connection.close()

    def test_status(self):
        status = self.run_info("status")
        self.assertTrue(status["ok"])
        self.assertGreaterEqual(status["processors"], 1)
        self.assertGreater(status["memoryTotal"], 0)
        self.assertGreater(status["homeTotal"], 0)
        self.assertEqual(["claude-code", "codex", "antigravity"], [agent["agent"] for agent in status["agents"]])
        self.assertEqual([8080, 8081, 8082], [agent["port"] for agent in status["agents"]])
        self.assertEqual([True, False, None], [agent["signedIn"] for agent in status["agents"]])
        self.assertEqual({"version", "running", "sandbox"}, set(status["browser"]))
        self.assertIsNone(status["browser"]["version"], "no Chrome downloaded in this home")

    def test_chats_of_all_three_agents_newest_first(self):
        found = self.run_info("chats")
        self.assertTrue(found["ok"])
        self.assertEqual([], found["problems"])
        by_id = {chat["id"]: chat for chat in found["chats"]}
        old = "99999999-2222-3333-4444-555555555555"
        self.assertEqual({CLAUDE_ID, old, CODEX_ID, AGY_ID, AGY_ORPHAN}, set(by_id), "every chat, the old one too")
        self.assertEqual(old, found["chats"][-1]["id"], "the oldest last")
        self.assertEqual("Add a login page", by_id[CLAUDE_ID]["title"])
        self.assertEqual("/home/me/projects/claude-code", by_id[CLAUDE_ID]["project"])
        self.assertEqual("Fix the build", by_id[CODEX_ID]["title"], "the newest state_<n>.sqlite")
        self.assertEqual("/home/me/projects/codex", by_id[CODEX_ID]["project"])
        self.assertEqual("Build the app", by_id[AGY_ID]["title"])
        self.assertEqual("/home/me/projects/antigravity", by_id[AGY_ID]["project"])
        self.assertEqual("Plan the API", by_id[AGY_ORPHAN]["title"])
        updated = [chat["updated"] for chat in found["chats"]]
        self.assertEqual(sorted(updated, reverse=True), updated)

    def test_a_claude_chat_shows_what_was_said_not_tool_answers_or_notes(self):
        chat = self.run_info("chat", "claude-code", CLAUDE_ID)
        self.assertTrue(chat["ok"])
        self.assertEqual(["user", "agent", "tool", "agent"], [message["role"] for message in chat["messages"]])
        self.assertEqual("Add a login page", chat["messages"][0]["text"])
        self.assertEqual("Bash: npm test", chat["messages"][2]["text"])
        self.assertEqual("Done.", chat["messages"][3]["text"])

    def test_a_codex_chat_skips_its_own_context(self):
        chat = self.run_info("chat", "codex", CODEX_ID)
        self.assertEqual(["user", "tool", "agent"], [message["role"] for message in chat["messages"]])
        self.assertEqual("Fix the build", chat["messages"][0]["text"])
        self.assertEqual("exec_command: bash -lc make", chat["messages"][1]["text"])

    def test_an_antigravity_chat_shows_its_artifacts(self):
        chat = self.run_info("chat", "antigravity", AGY_ID)
        self.assertEqual(["user", "artifact"], [message["role"] for message in chat["messages"]])
        self.assertEqual("task.md", chat["messages"][1]["name"])

    def test_usage_counts_each_message_once_and_only_the_last_week(self):
        usage = self.run_info("usage")
        claude = usage["claude"]
        self.assertEqual({"input": 110, "output": 55, "cacheRead": 1000, "cacheWrite": 200}, claude["week"])
        self.assertEqual(claude["week"], claude["day"])
        self.assertEqual(1, claude["chats"])
        codex = usage["codex"]
        self.assertEqual({"input": 1100, "output": 50, "cacheRead": 400, "cacheWrite": 0}, codex["week"])
        self.assertEqual([42.5, 7.0], [window["usedPercent"] for window in codex["limits"]])
        self.assertEqual([300, 10080], [window["minutes"] for window in codex["limits"]])
        self.assertEqual(2, usage["antigravity"]["chats"])

    def test_deleting_a_claude_chat_leaves_nothing_of_it(self):
        age(self.claude_chat, 30)
        refused = self.run_info("delete", "claude-code", CLAUDE_ID)
        self.assertFalse(refused["ok"], "a chat Claude Code wrote to just now is in use")
        self.assertTrue(self.claude_chat.exists())
        age(self.claude_chat, 600)
        self.assertTrue(self.run_info("delete", "claude-code", CLAUDE_ID)["ok"])
        self.assertFalse(self.claude_chat.exists())
        self.assertEqual([], list((self.home / ".claude" / "todos").iterdir()))
        history = (self.home / ".claude" / "history.jsonl").read_text()
        self.assertNotIn(CLAUDE_ID, history)
        self.assertIn("Old work", history)
        self.assertNotIn(CLAUDE_ID, {chat["id"] for chat in self.run_info("chats")["chats"]})

    def test_deleting_a_codex_chat_removes_its_file_its_thread_and_its_history(self):
        self.assertTrue(self.run_info("delete", "codex", CODEX_ID)["ok"])
        self.assertFalse(self.codex_chat.exists())
        connection = sqlite3.connect(self.home / ".codex" / "state_5.sqlite")
        self.assertEqual(0, connection.execute("SELECT count(*) FROM threads").fetchone()[0])
        connection.close()
        history = (self.home / ".codex" / "history.jsonl").read_text()
        self.assertNotIn(CODEX_ID, history)
        self.assertIn("keep", history)

    def test_antigravity_chats_are_deleted_in_antigravity(self):
        self.assertFalse(self.run_info("delete", "antigravity", AGY_ID)["ok"])
        self.assertTrue((self.home / ".gemini" / "antigravity" / "conversations" / f"{AGY_ID}.pb").exists())

    def test_extensions_in_each_agents_vs_code(self):
        listing = self.home / ".pocketide" / "vscode" / "codex" / "extensions" / "extensions.json"
        listing.parent.mkdir(parents=True)
        listing.write_text(json.dumps([
            {"identifier": {"id": "openai.chatgpt"}, "version": "26.9.1"},
            {"identifier": {"id": "PocketIDE.layout"}, "version": "8.0.0"},
            {"identifier": {"id": "esbenp.prettier-vscode"}, "version": "12.4.0"},
            {"no identifier": True},
        ]))
        (self.home / ".pocketide" / "vscode" / "antigravity" / "extensions").mkdir(parents=True)
        (self.home / ".pocketide" / "vscode" / "antigravity" / "extensions" / "extensions.json").write_text("not json")
        found = self.run_info("extensions")
        self.assertTrue(found["ok"])
        self.assertEqual([], found["agents"]["claude-code"], "no VS Code there yet")
        self.assertEqual([], found["agents"]["antigravity"], "an unreadable list is no extensions, not an error")
        codex = found["agents"]["codex"]
        self.assertEqual(["esbenp.prettier-vscode", "openai.chatgpt", "PocketIDE.layout"], [item["id"] for item in codex])
        self.assertEqual([False, True, True], [item["own"] for item in codex], "the agent and PocketIDE's layout stay")

    def test_an_added_agent_shows_with_its_own_name_port_and_extensions(self):
        (self.home / ".pocketide").mkdir(exist_ok=True)
        (self.home / ".pocketide" / "agents").write_text(
            "x-claude-dev:8083:saoudrizwan/claude-dev\n"
            "x-roo:8084:RooVeterinaryInc/roo-cline:any\n"
            "codex:8085:openai/chatgpt\n"
            "x-bad:8080:a/b\n"
            "x-evil:8086:a/b; rm -rf ~\n")
        cline = self.home / ".pocketide" / "vscode" / "x-claude-dev" / "extensions"
        (cline / "saoudrizwan.claude-dev-4.1.22").mkdir(parents=True)
        (cline / "saoudrizwan.claude-dev-4.1.22" / "package.json").write_text(json.dumps({"displayName": "Cline"}))
        (cline / "extensions.json").write_text(json.dumps([{"identifier": {"id": "saoudrizwan.claude-dev"}, "version": "4.1.22"}]))
        roo = self.home / ".pocketide" / "vscode" / "x-roo" / "extensions" / "rooveterinaryinc.roo-cline-3.54.0"
        roo.mkdir(parents=True)
        (roo / "package.json").write_text(json.dumps({"displayName": "%extension.displayName%"}))
        (roo / "package.nls.json").write_text(json.dumps({"extension.displayName": "Roo Code"}))
        status = self.run_info("status")
        added = [agent for agent in status["agents"] if agent["agent"].startswith("x-")]
        self.assertEqual([("x-claude-dev", 8083, "saoudrizwan.claude-dev", "Cline", "4.1.22"),
                          ("x-roo", 8084, "rooveterinaryinc.roo-cline", "Roo Code", "3.54.0")],
                         [(a["agent"], a["port"], a["extension"], a["name"], a["version"]) for a in added],
                         "only lines the launcher writes; PocketIDE's own ports and names are never an added agent's")
        self.assertNotIn("extension", status["agents"][0], "PocketIDE's own agents carry no extension field")
        found = self.run_info("extensions")["agents"]
        self.assertEqual([{"id": "saoudrizwan.claude-dev", "version": "4.1.22", "own": True}], found["x-claude-dev"])

    def test_nothing_outside_the_agents_folders(self):
        for argv in (("chat", "claude-code", "../../etc/passwd"), ("delete", "codex", "../x"), ("chat", "vim", CLAUDE_ID),
                     ("delete", "claude-code", "*"), ("rm", "-rf"), ()):
            with self.subTest(argv=argv):
                self.assertFalse(self.run_info(*argv)["ok"])

    def test_an_empty_home_has_no_chats_and_no_usage(self):
        self.folder.cleanup()
        self.home.mkdir()
        self.assertEqual([], self.run_info("chats")["chats"])
        self.assertEqual(0, self.run_info("usage")["claude"]["week"]["output"])

    def test_the_script_fits_in_one_command_line(self):
        # The app sends it base64-encoded as one argument: Linux takes up to 128 KB in one.
        self.assertLess(INFO.stat().st_size * 4 / 3, 96 * 1024)


if __name__ == "__main__":
    unittest.main()
