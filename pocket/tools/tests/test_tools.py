"""The CI tools: the YAML reader and the secrets file."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tests.support import REPO, TOOLS

import yaml_lite


def load_script(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), TOOLS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


secrets_file = load_script("make-secrets-file")


def plain(node):
    """PyYAML's reading in yaml_lite's terms: every scalar a string, the YAML 1.1 'on' key back to "on"."""
    if isinstance(node, dict):
        return {("on" if key is True else str(key)): plain(value) for key, value in node.items()}
    if isinstance(node, list):
        return [plain(value) for value in node]
    if isinstance(node, bool):
        return "true" if node else "false"
    return node if node is None else str(node)


class YamlLite(unittest.TestCase):
    def test_reads_the_real_workflow_exactly_like_pyyaml(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML is not installed")
        text = (REPO / ".github/workflows/pocket.yml").read_text(encoding="utf-8")
        self.assertEqual(plain(yaml.safe_load(text)), yaml_lite.load(text))

    def test_block_scalars_and_chomping(self):
        text = "a: |\n  one\n  two\n\nb: >-\n  x\n  y\nc: |+\n  keep\n\n"
        self.assertEqual({"a": "one\ntwo\n", "b": "x y", "c": "keep\n\n"}, yaml_lite.load(text))

    def test_lists_of_maps_flow_lists_and_comments(self):
        text = "on: [push, 'workflow_dispatch']  # both\nsteps:\n  - uses: a/b@c # v1\n    with:\n      k: \"v # not a comment\"\n  - run: x\n"
        self.assertEqual({"on": ["push", "workflow_dispatch"],
                          "steps": [{"uses": "a/b@c", "with": {"k": "v # not a comment"}}, {"run": "x"}]},
                         yaml_lite.load(text))

    def test_bad_indentation_is_an_error(self):
        with self.assertRaises(yaml_lite.YamlError):
            yaml_lite.load("a:\n  b: 1\n    c: 2\n")

    def test_duplicate_keys_are_an_error(self):
        with self.assertRaises(yaml_lite.YamlError):
            yaml_lite.load("a: 1\na: 2\n")


class SecretsFile(unittest.TestCase):
    FACTS = secrets_file.KeyFacts("QUJD", "store-pass", "key-pass", "pocketide", "AA:BB", "CC:DD")

    def test_lists_every_value_and_step(self):
        text = secrets_file.render(self.FACTS, "owner/repo", "release.jks")
        for expected in ("Name:\nPOCKETIDE_KEYSTORE_B64\nSecret:\nQUJD\n", "Name:\nPOCKETIDE_STORE_PASS\nSecret:\nstore-pass\n",
                         "Name:\nPOCKETIDE_KEY_PASS\nSecret:\nkey-pass\n", "Name:\nPOCKETIDE_KEY_ALIAS\nSecret:\npocketide\n",
                         "App: PocketIDE", "GitHub repository: owner/repo", "Package: com.pocketide", "SHA-1:   AA:BB",
                         "SHA-256: CC:DD", "https://github.com/owner/repo/settings/secrets/actions/new", "Run workflow"):
            self.assertIn(expected, text)
        # Each secret stands apart from the next, and no version number dates the file.
        self.assertIn("Secret:\nQUJD\n\n\n2) The key store password", text)
        self.assertNotIn("PocketIDE 4", text)
        # Version 5 signs in to nothing: no GitHub App, and no variables to fill in.
        for gone in ("GitHub App", "VARIABLES", "CLIENT_ID", "Device Flow"):
            self.assertNotIn(gone, text)
        # Every link is a full address, so it opens with a tap in any text viewer.
        for line in text.splitlines():
            if "github.com/" in line:
                self.assertTrue(line.startswith("https://"), line)

    def test_the_file_is_private_and_never_overwritten_silently(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work, "secrets.txt")
            secrets_file.write_private(path, "x", overwrite=False)
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
            with self.assertRaises(secrets_file.SetupError):
                secrets_file.write_private(path, "y", overwrite=False)

    def test_refuses_to_run_in_ci(self):
        errors = io.StringIO()
        with tempfile.TemporaryDirectory() as work, mock.patch.dict(os.environ, {"CI": "true"}), \
                contextlib.redirect_stderr(errors):
            out = Path(work, "never.txt")
            self.assertEqual(1, secrets_file.main(["missing.jks", "--out", str(out)]))
            self.assertFalse(out.exists())
        self.assertIn("not in CI", errors.getvalue())

    @unittest.skipUnless(shutil.which("keytool"), "keytool is not installed")
    def test_a_new_key_gives_matching_fingerprints(self):
        with tempfile.TemporaryDirectory() as work, mock.patch.dict(os.environ, {}, clear=False):
            for name in ("CI", "GITHUB_ACTIONS"):
                os.environ.pop(name, None)
            keystore, out = Path(work, "k.p12"), Path(work, "s.txt")
            with mock.patch("builtins.print"):
                self.assertEqual(0, secrets_file.main([str(keystore), "--create", "--out", str(out)]))
            text = out.read_text()
            lines = text.splitlines()
            at = lines.index("POCKETIDE_STORE_PASS")
            password = lines[at + 2]
            listing = subprocess.run(["keytool", "-list", "-v", "-keystore", str(keystore), "-storepass", password],
                                     capture_output=True, text=True, check=True).stdout
            sha1 = next(l.split("SHA1:")[1].strip() for l in listing.splitlines() if "SHA1:" in l)
            self.assertIn(f"SHA-1:   {sha1}", text)


if __name__ == "__main__":
    unittest.main()
