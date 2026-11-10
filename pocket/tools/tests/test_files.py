"""PocketIDE's files in Cloud Shell (files.py and `pocketide link`, from the set-up script), against
a home folder of their own: what an agent links opens as a page, downloads whole or in ranges
(an APK too, which the phone's Files app installs: PocketIDE asks for no install permission), and
never reaches past ~/projects."""
from __future__ import annotations

import http.client
import io
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
import zipfile
import zlib
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "cloudshell" / "pocketide-cloudshell.sh"


def heredoc(start: str, end: str) -> str:
    text = SCRIPT.read_text(encoding="utf-8")
    return text.split(start, 1)[1].split(end, 1)[0]


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def png(side: int) -> bytes:
    """A square, opaque PNG [side] pixels wide, with real checksums (aapt2 checks them)."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    rows = b"".join(b"\x00" + b"\x0b\x57\xd0" * side for _ in range(side))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def android_tools() -> tuple[Path, Path] | None:
    """aapt2 and an android.jar from the Android SDK (CI's build job installs them), to make a real APK."""
    for root in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"), "/opt/android-sdk"):
        if not root or not Path(root).is_dir():
            continue
        aapt2 = sorted(Path(root).glob("build-tools/*/aapt2"))
        jars = sorted(Path(root).glob("platforms/android-*/android.jar"))
        if aapt2 and jars:
            return aapt2[-1], jars[-1]
    return None


class Files(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.home = Path(self.folder.name)
        self.projects = self.home / "projects"
        (self.projects / "codex").mkdir(parents=True)
        (self.home / ".pocketide").mkdir()
        self.port = free_port()
        server = self.home / ".pocketide" / "files.py"
        server.write_text(heredoc("cat >\"$BASE/files.py\" <<'FILES'\n", "\nFILES\n"), encoding="utf-8")
        self.process = subprocess.Popen([sys.executable, str(server)], cwd=self.home,
                                        env={**os.environ, "HOME": str(self.home), "FILES_PORT": str(self.port)},
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                if self.get("/state")[0] == 200:
                    break
            except OSError:
                time.sleep(0.05)
        else:
            self.fail("files.py did not start: " + self.process.stderr.read().decode())

    def tearDown(self):
        self.process.kill()
        self.process.wait()
        self.process.stderr.close()
        self.folder.cleanup()

    def get(self, path: str, headers: dict | None = None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        try:
            connection.request("GET", path, headers=headers or {})
            answer = connection.getresponse()
            return answer.status, {k.lower(): v for k, v in answer.getheaders()}, answer.read()
        finally:
            connection.close()

    def raw_request(self, path: str) -> int:
        """As sent, without a client tidying the path (.. and %2e%2e stay as they are)."""
        with socket.create_connection(("127.0.0.1", self.port), timeout=30) as raw:
            raw.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
            first = raw.makefile("rb").readline().decode()
        return int(first.split()[1])

    def put(self, relative: str, data: bytes | str) -> Path:
        path = self.projects / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode() if isinstance(data, str) else data)
        return path

    def test_a_file_opens_as_its_page_with_download_and_open(self):
        self.put("codex/app/notes.txt", "line one\nline two\n")
        status, headers, body = self.get("/f/codex/app/notes.txt")
        page = body.decode()
        self.assertEqual(200, status)
        self.assertTrue(headers["content-type"].startswith("text/html"))
        self.assertIn("notes.txt", page)
        self.assertIn('href="/f/codex/app/notes.txt?download"', page)
        self.assertIn('href="/r/codex/app/notes.txt"', page)
        self.assertIn("<span>line one</span>", page)
        # Its own scripts only (a fresh nonce), and nothing another page could read from it.
        nonce = re.search(r"'nonce-([^']+)'", headers["content-security-policy"]).group(1)
        self.assertIn(f'<script nonce="{nonce}">', page)
        self.assertNotIn("access-control-allow-origin", headers)
        self.assertEqual("nosniff", headers["x-content-type-options"])

    def test_raw_ranges_and_downloads(self):
        data = bytes(range(256)) * 4
        self.put("codex/video.mp4", data)
        status, headers, body = self.get("/f/codex/video.mp4?raw")
        self.assertEqual((200, data, "bytes"), (status, body, headers["accept-ranges"]))
        status, headers, body = self.get("/f/codex/video.mp4?raw", {"Range": "bytes=10-19"})
        self.assertEqual((206, data[10:20], "bytes 10-19/1024"), (status, body, headers["content-range"]))
        status, headers, body = self.get("/f/codex/video.mp4?raw", {"Range": "bytes=-24"})
        self.assertEqual((206, data[-24:]), (status, body))
        self.assertEqual(416, self.get("/f/codex/video.mp4?raw", {"Range": "bytes=5000-"})[0])
        # A name in any language reaches the phone whole (RFC 5987), and plainly for older readers.
        self.put("codex/रिपोर्ट \"final\".txt", "x")
        status, headers, _ = self.get("/f/codex/" + urllib.parse.quote("रिपोर्ट \"final\".txt") + "?download")
        self.assertEqual(200, status)
        disposition = headers["content-disposition"]
        self.assertTrue(disposition.startswith("attachment; filename=\""), disposition)
        self.assertIn("filename*=UTF-8''%E0%A4%B0", disposition)
        self.assertNotIn('"final"', disposition.split(";")[1])
        # A file opened as a page runs sandboxed: it cannot read the owner's other files.
        self.put("codex/site/index.html", "<script>fetch('/f/codex/secret.txt')</script>")
        headers = self.get("/r/codex/site/index.html")[1]
        self.assertTrue(headers["content-security-policy"].startswith("sandbox "))
        self.assertNotIn("allow-same-origin", headers["content-security-policy"])
        # A web page opens from its own page's Open page, at /s/<a secret of this files.py>/, where its own
        # scripts and styles load too (from its sandbox, so from no origin). A folder is its index.html,
        # reached with a / so that its own links work; /r/ leads there.
        page = self.get("/f/codex/site/index.html")[2].decode()
        opened = re.search(r'href="(/s/[A-Za-z0-9_-]+/codex/site/index\.html)"', page).group(1)
        site = opened[:-len("codex/site/index.html")]
        self.assertEqual(200, self.get(opened, {"Sec-Fetch-Dest": "script", "Sec-Fetch-Site": "cross-site"})[0])
        self.assertEqual(404, self.get("/s/guessed/codex/site/index.html")[0])
        for folder in ("/r/codex/site", site + "codex/site"):
            status, headers, _ = self.get(folder)
            self.assertEqual((302, site + "codex/site/"), (status, headers["location"]), folder)

    def test_nothing_outside_projects(self):
        (self.home / "secret.txt").write_text("the owner's key")
        os.symlink(self.home / "secret.txt", self.projects / "codex" / "leak.txt")
        for path in ("/f/codex/../../secret.txt", "/f/codex/%2e%2e/%2e%2e/secret.txt", "/r/codex/../../secret.txt",
                     "/f/codex/leak.txt?raw", "/r/codex/leak.txt", "/_/../files.py"):
            self.assertIn(self.raw_request(path), (400, 404), path)
        listing = self.get("/f/codex")[2].decode()
        self.assertNotIn("leak.txt", listing)
        self.assertNotIn("the owner's key", listing)

    def test_what_a_file_holds_is_shown_escaped(self):
        self.put("codex/<img src=x onerror=alert(1)>.txt", "<script>alert(2)</script>")
        page = self.get("/f/codex/%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E.txt")[2].decode()
        self.assertNotIn("<img src=x", page)
        self.assertNotIn("<script>alert(2)", page)
        self.assertIn("&lt;script&gt;alert(2)&lt;/script&gt;", page)
        self.put("codex/README.md", "# Title\n\n<script>alert(3)</script> [bad](javascript:alert(4)) [good](docs/a.md) **bold**\n\n"
                                    "| a | b |\n|---|---|\n| 1 | 2 |\n\n```\n<b>code</b>\n```\n")
        page = self.get("/f/codex/README.md")[2].decode()
        self.assertIn("<h2>Title</h2>", page)
        self.assertNotIn("<script>alert(3)", page)
        self.assertNotIn("javascript:", page)
        self.assertIn('<a href="/f/codex/docs/a.md">good</a>', page)
        self.assertIn("<strong>bold</strong>", page)
        self.assertIn("<th>a</th>", page)
        self.assertIn("&lt;b&gt;code&lt;/b&gt;", page)

    def test_a_folder_lists_its_files_and_downloads_as_one_zip(self):
        self.put("codex/out/a.txt", "a")
        self.put("codex/out/deep/b.txt", "b")
        page = self.get("/f/codex/out")[2].decode()
        self.assertIn('href="/f/codex/out/deep"', page)
        self.assertIn('href="/f/codex/out/a.txt"', page)
        self.assertIn('href="/f/codex/out?zip"', page)
        status, headers, body = self.get("/f/codex/out?zip")
        self.assertEqual(200, status)
        self.assertIn('filename="out.zip"', headers["content-disposition"])
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            self.assertEqual({"out/a.txt", "out/deep/b.txt"}, set(archive.namelist()))
            self.assertEqual(b"b", archive.read("out/deep/b.txt"))

    def test_an_apk_shows_its_name_version_and_icon_and_downloads(self):
        tools = android_tools()
        if tools is None:
            if os.environ.get("CI"):
                self.fail("CI's build job has the Android SDK: aapt2 makes the APK this test reads")
            self.skipTest("no Android SDK here to make an APK with")
        aapt2, android_jar = tools
        work = self.home / "apk-source"
        (work / "res" / "values").mkdir(parents=True)
        (work / "res" / "mipmap-xxxhdpi").mkdir()
        (work / "AndroidManifest.xml").write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.hello"'
            ' android:versionCode="7" android:versionName="1.2.3"><uses-sdk android:minSdkVersion="24"'
            ' android:targetSdkVersion="35"/><uses-permission android:name="android.permission.INTERNET"/>'
            '<application android:label="@string/app_name" android:icon="@mipmap/ic_launcher"/></manifest>')
        (work / "res" / "values" / "strings.xml").write_text('<resources><string name="app_name">Hello Pocket</string></resources>')
        (work / "res" / "mipmap-xxxhdpi" / "ic_launcher.png").write_bytes(png(48))
        subprocess.run([str(aapt2), "compile", "--dir", str(work / "res"), "-o", str(work / "compiled.zip")], check=True, capture_output=True)
        apk = self.projects / "codex" / "app" / "app-debug.apk"
        apk.parent.mkdir(parents=True)
        subprocess.run([str(aapt2), "link", "-o", str(apk), "-I", str(android_jar), "--manifest", str(work / "AndroidManifest.xml"),
                        str(work / "compiled.zip")], check=True, capture_output=True)
        page = self.get("/f/codex/app/app-debug.apk")[2].decode()
        for shown in ("Hello Pocket", "com.example.hello", "1.2.3 (7)", "Android 7 or newer", "Android 15", "android.permission.INTERNET"):
            self.assertIn(shown, page)
        # Download only: the phone's Files app installs it (PocketIDE has no install permission).
        self.assertIn('href="/f/codex/app/app-debug.apk?download"', page)
        self.assertNotIn("install&", page)
        self.assertNotIn(">Install<", page)
        status, headers, body = self.get("/f/codex/app/app-debug.apk?icon=bitmap")
        self.assertEqual((200, "image/png", b"\x89PNG"), (status, headers["content-type"], body[:4]))
        headers = self.get("/f/codex/app/app-debug.apk?download")[1]
        self.assertEqual("application/vnd.android.package-archive", headers["content-type"])
        self.assertTrue(headers["content-disposition"].startswith('attachment; filename="app-debug.apk"'))

    def test_only_an_agents_vs_code_uploads_and_no_other_page_embeds_the_owners_files(self):
        # PocketIDE's door passes an agent's VS Code page on as the drop's own address, and any other page
        # (a dev server's) as its own port's; a program here sends no origin at all.
        for origin, status in (("http://localhost:5173", 403), (f"http://localhost:{self.port}", 200), (None, 200)):
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
            headers = {"Content-Length": "1", **({"Origin": origin} if origin else {})}
            connection.request("POST", "/upload?agent=codex&name=o.txt", body=b"x", headers=headers)
            answer = connection.getresponse()
            answer.read()
            connection.close()
            self.assertEqual(status, answer.status, origin)
            self.assertIsNone(answer.getheader("Access-Control-Allow-Origin"), "no other page reads the answer")
        self.assertFalse((self.projects / "codex" / "uploads" / "o (3).txt").exists())
        # A script of the owner's, embedded by a page of another port (a dev server's): refused, its globals
        # would be that page's to read. As PocketIDE's door passes it on: its own port's localhost.
        self.put("codex/app/config.js", "var TOKEN = 'secret';")
        elsewhere = {"Sec-Fetch-Dest": "script", "Sec-Fetch-Site": "cross-site"}
        for path in ("/r/codex/app/config.js", "/f/codex/app/config.js?raw", "/f/codex/app/config.js?download"):
            self.assertEqual(403, self.get(path, {**elsewhere, "Referer": "http://localhost:5173/"})[0], path)
            self.assertEqual(403, self.get(path, elsewhere)[0], path + " with no Referer")
        here = f"http://localhost:{self.port}/"
        allowed = (
            {**elsewhere, "Referer": here},  # a page opened from /r/: sandboxed, so from no origin, but sent from here
            {"Sec-Fetch-Dest": "image", "Sec-Fetch-Site": "same-origin"},  # files.py's own page
            {"Sec-Fetch-Dest": "document", "Sec-Fetch-Site": "cross-site"},  # opened, as a page
            {"Sec-Fetch-Dest": "empty", "Sec-Fetch-Site": "cross-site"},  # a fetch, which no other page may read
            {},  # a program here (PocketIDE's downloads come with none of these)
        )
        for headers in allowed:
            status, answer_headers, body = self.get("/r/codex/app/config.js", headers)
            self.assertEqual((200, b"var TOKEN = 'secret';"), (status, body), headers)
            self.assertNotIn("access-control-allow-origin", answer_headers)
        self.assertEqual("strict-origin", self.get("/r/codex/app/config.js")[1]["referrer-policy"])

    def test_files_from_the_phone_still_land_in_the_agents_uploads(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        connection.request("POST", "/upload?agent=codex&name=photo.png", body=b"png", headers={"Content-Length": "3"})
        answer = connection.getresponse()
        self.assertEqual(200, answer.status, answer.read())
        connection.close()
        uploads = self.projects / "codex" / "uploads"
        self.assertEqual(b"png", (uploads / "photo.png").read_bytes())
        self.assertIn("*", (uploads / ".gitignore").read_text())


class Link(unittest.TestCase):
    """`pocketide link`: the named link an agent gives the owner."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.home = Path(self.folder.name)
        (self.home / "projects" / "codex" / "app").mkdir(parents=True)
        self.launcher = self.home / "pocketide"
        self.launcher.write_text(heredoc("cat >\"$BIN/pocketide\" <<'LAUNCHER'\n", "\nLAUNCHER\n"), encoding="utf-8")

    def tearDown(self):
        self.folder.cleanup()

    def link(self, *paths: str, agent: str = "codex") -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(self.launcher), "link", *paths], capture_output=True, text=True, timeout=60,
                              cwd=self.home, env={**os.environ, "HOME": str(self.home), "POCKETIDE_AGENT": agent})

    def test_a_file_in_projects_is_linked_where_it_is(self):
        apk = self.home / "projects" / "codex" / "app" / "my app [debug].apk"
        apk.write_bytes(b"x" * 2048)
        done = self.link(str(apk))
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertEqual(r"[my app \[debug\].apk · 2 KB](http://localhost:6081/f/codex/app/my%20app%20%5Bdebug%5D.apk)", done.stdout.strip())

    def test_a_file_elsewhere_is_copied_into_the_agents_outbox_first(self):
        outside = Path(tempfile.mkdtemp(dir="/tmp"))
        try:
            (outside / "shot.png").write_bytes(b"png")
            done = self.link(str(outside / "shot.png"))
            self.assertEqual(0, done.returncode, done.stderr)
            self.assertEqual("[shot.png · 3 bytes](http://localhost:6081/f/codex/outbox/shot.png)", done.stdout.strip())
            self.assertEqual(b"png", (self.home / "projects" / "codex" / "outbox" / "shot.png").read_bytes())
            self.assertIn("*", (self.home / "projects" / "codex" / "outbox" / ".gitignore").read_text())
            self.assertIn("copied", done.stderr)
        finally:
            shutil.rmtree(outside)

    def test_keys_and_sign_ins_are_never_linked(self):
        secret = self.home / ".ssh" / "id_ed25519"
        secret.parent.mkdir()
        secret.write_text("PRIVATE KEY")
        done = self.link(str(secret))
        self.assertNotEqual(0, done.returncode)
        self.assertEqual("", done.stdout)
        self.assertFalse((self.home / "projects" / "codex" / "outbox").exists())
        self.assertNotEqual(0, self.link("/etc/hostname").returncode)


if __name__ == "__main__":
    unittest.main()
