"""A small, valid pocket/ tree for the gate tests, which each test then breaks on purpose."""
from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
REPO = TOOLS.parents[1]
sys.path.insert(0, str(TOOLS / "gates"))
sys.path.insert(0, str(TOOLS))

PAGE = 0x4000
PT_LOAD, PT_GNU_RELRO = 1, 0x6474E552
PF_R, PF_W, PF_X = 4, 2, 1


def elf(segments: list[tuple[int, int, int, int, int]], machine: int = 183) -> bytes:
    """A 64-bit little-endian ELF with only program headers: (type, flags, vaddr, memsz, align)."""
    header = bytearray(64)
    header[:4] = b"\x7fELF"
    header[4], header[5], header[6] = 2, 1, 1
    struct.pack_into("<HHI", header, 0x10, 3, machine, 1)
    struct.pack_into("<Q", header, 0x20, 64)
    struct.pack_into("<HHHH", header, 0x34, 64, 56, len(segments), 0)
    table = b"".join(struct.pack("<IIQQQQQQ", t, f, 0, v, v, m, m, a) for t, f, v, m, a in segments)
    return bytes(header) + table


GOOD_LIB = elf([(PT_LOAD, PF_R | PF_X, 0, 0x37EC0, PAGE), (PT_LOAD, PF_R | PF_W, 0x3BEC0, 0x2140, PAGE),
                (PT_LOAD, PF_R | PF_W, 0x41550, 0x3440, PAGE), (PT_GNU_RELRO, PF_R, 0x3BEC0, 0x2140, 1)])

FILES = {
    "branding/tokens.json": '{"brand": {"tile_top": "#7A3CD6"}, "semantic": {"running": "#129150"}}',
    "app/src/main/res/values/colors.xml":
        '<resources>\n  <color name="brand_tile_top">#FF7A3CD6</color>\n'
        '  <color name="window_light">#FFFAF9F6</color>\n</resources>\n',
    "app/src/main/java/com/pocketide/ui/theme/Theme.kt":
        "object Brand {\n    val TileTop = Color(0xFF7A3CD6)\n    val Running = Color(0xFF129150)\n}\n",
    "app/src/main/AndroidManifest.xml":
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '  <uses-permission android:name="android.permission.INTERNET" />\n'
        '  <application android:allowBackup="false"\n'
        '      android:dataExtractionRules="@xml/data_extraction_rules"\n'
        '      android:fullBackupContent="@xml/backup_rules" />\n</manifest>\n',
    "app/src/main/res/xml/data_extraction_rules.xml":
        "<data-extraction-rules>\n"
        + "".join(f"  <{s}>\n" + "".join(f'    <exclude domain="{d}" path="." />\n'
                                        for d in ("root", "file", "database", "sharedpref", "external"))
                  + f"  </{s}>\n" for s in ("cloud-backup", "device-transfer"))
        + "</data-extraction-rules>\n",
    "app/src/main/res/xml/backup_rules.xml":
        "<full-backup-content>\n" + "".join(f'  <exclude domain="{d}" path="." />\n'
                                            for d in ("root", "file", "database", "sharedpref", "external"))
        + "</full-backup-content>\n",
    "app/src/main/java/com/pocketide/docs/Guide.kt":
        'object Guide {\n    private val permissions = section(\n        "permissions",\n'
        '        table(listOf("Permission", "Why"), row("INTERNET", "To reach GitHub.")),\n    )\n'
        "    val all = listOf(permissions)\n}\n",
    "app/build.gradle.kts": 'val appVersion = "8.0.0"\n\nfun versionCodeOf(version: String): Int {\n'
                            '    val (major, minor, patch) = version.split(".").map { it.toInt() }\n'
                            '    return major * 10000 + minor * 100 + patch\n}\n\n'
                            'android {\n    defaultConfig {\n        versionCode = versionCodeOf(appVersion)\n'
                            '        versionName = appVersion\n    }\n}\n',
    "app/src/main/assets/scripts/example.sh": "#!/bin/bash\nset -eu\necho ready\n",
}


class TreeTest(unittest.TestCase):
    """Gives each test a fresh valid tree at self.root (the pocket/ directory)."""

    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.root = Path(self._temp.name) / "pocket"
        for name, text in FILES.items():
            self.write(name, text)
        lib = self.root / "app/src/main/jniLibs/arm64-v8a/libexample.so"
        lib.parent.mkdir(parents=True)
        lib.write_bytes(GOOD_LIB)
        self.allow = self.root.parent / "permissions.txt"
        self.allow.write_text("# test allow-list\nandroid.permission.INTERNET\n")

    def write(self, name: str, text: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def edit(self, name: str, old: str, new: str) -> None:
        path = self.root / name
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text, f"fixture {name} lacks {old!r}")
        path.write_text(text.replace(old, new), encoding="utf-8")

    def assertPasses(self, report) -> None:
        self.assertEqual([], report.problems)

    def assertFailsWith(self, report, *fragments: str) -> None:
        self.assertTrue(report.problems, "expected the gate to fail")
        joined = "\n".join(report.problems)
        for fragment in fragments:
            self.assertIn(fragment, joined)
