"""Synthetic metadata/tool boundaries; no fabricated signed beta DMG."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release_manifest", Path(__file__).parents[1] / "release_manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class ReleaseManifestTests(unittest.TestCase):
    def metadata(self, version="0.3.0"):
        return {"CFBundleShortVersionString": version, "CFBundleVersion": "42", "CFBundleIdentifier": manifest.BUNDLE_ID, "LSMinimumSystemVersion": "14.0"}

    def development(self):
        return manifest.signing_facts("apple-development", 65, 65)

    def fixture(self, tag="v0.3.0-beta.1", channel="preview"):
        return manifest.candidate(tag, channel, f"QuotaMew-{tag}.dmg", self.metadata(), self.development())

    def test_supported_identities(self):
        for tag, channel in [("v0.3.0-beta.1", "preview"), ("v0.3.0-rc.1", "preview"), ("v0.3.0-alpha.2", "preview"), ("v0.3.0", "stable"), ("v0.3.0-test-1", "preview")]:
            with self.subTest(tag=tag):
                data = self.fixture(tag, channel)
                self.assertEqual(data["version"], tag[1:])
                self.assertEqual(data["build"], 42)  # Synthetic, not the next build policy.

    def test_invalid_identities(self):
        for tag in ["0.3.0", "v00.3.0", "v0.03.0", "v0.3.00", "v0.3", "v0.3.0-", "v0.3.0-beta..1", "v0.3.0-beta.01", "v0.3.0+build", "v0.3.0-beta.1\n", "v0.3.0-β.1", "v0.3.0-１"]:
            with self.subTest(tag=tag), self.assertRaises(manifest.ManifestError):
                manifest.identity(tag, "preview", f"QuotaMew-{tag}.dmg")
        for tag, channel in [("v0.3.0", "preview"), ("v0.3.0-rc.1", "stable")]:
            with self.assertRaises(manifest.ManifestError):
                self.fixture(tag, channel)
        with self.assertRaises(manifest.ManifestError):
            manifest.identity("v0.3.0", "stable", "QuotaMew-v0.2.0.dmg")

    def test_release_core_and_bundle_policy(self):
        for key, value in [("CFBundleShortVersionString", "0.3.0-beta.1"), ("CFBundleShortVersionString", "0.2.0"), ("CFBundleVersion", "1.2"), ("CFBundleVersion", "01"), ("CFBundleVersion", "9007199254740992"), ("CFBundleVersion", 42), ("CFBundleIdentifier", "dev.quotapulse.development.app"), ("LSMinimumSystemVersion", "14.0\n")]:
            with self.subTest(key=key, value=value), self.assertRaises(manifest.ManifestError):
                metadata = self.metadata()
                metadata[key] = value
                manifest.candidate("v0.3.0-beta.1", "preview", "QuotaMew-v0.3.0-beta.1.dmg", metadata, self.development())

    def test_exact_v1_contract(self):
        data = self.fixture()
        self.assertEqual(set(data), {"schemaVersion", "tag", "version", "build", "channel", "minimumMacOS", "bundleID", "artifact", "signing"})
        self.assertEqual(data["artifact"], {"filename": "QuotaMew-v0.3.0-beta.1.dmg"})
        self.assertEqual(data["signing"], {"type": "apple-development", "codesignVerified": True, "notarized": False, "stapled": False})
        for mutation in [lambda d: d.update(schemaVersion=2), lambda d: d.update(schemaVersion=True), lambda d: d.update(generatedAt="now"), lambda d: d.update(build=True), lambda d: d.update(build=-1), lambda d: d.update(version="0.3.0"), lambda d: d["artifact"].update(sizeBytes=1), lambda d: d["signing"].update(teamID="private"), lambda d: d["signing"].update(type="ad-hoc"), lambda d: d["signing"].update(stapled=True), lambda d: d["signing"].update(codesignVerified=1), lambda d: d["signing"].update(type="unsigned")]:
            with self.subTest(mutation=mutation), self.assertRaises(manifest.ManifestError):
                invalid = copy.deepcopy(data)
                mutation(invalid)
                manifest.validate_manifest(invalid)

    def test_signing_evidence_matrix(self):
        self.assertEqual(manifest.signing_facts("developer-id", 0, 0)["notarized"], True)
        self.assertEqual(manifest.signing_facts("developer-id", 0, 65)["stapled"], True)
        for kind, app, dmg in [("developer-id", 65, 65), ("developer-id", 65, 0), ("apple-development", 0, 65), ("unsigned", 65, 65), ("ad-hoc", 65, 65), ("apple-development", 1, 65), ("developer-id", 0, 69)]:
            with self.subTest(kind=kind, app=app, dmg=dmg), self.assertRaises(manifest.ManifestError):
                manifest.signing_facts(kind, app, dmg)

    def test_codesign_tools_and_trust_anchor(self):
        with patch.object(manifest, "run_tool", side_effect=[(0, b""), (0, b""), (0, b"Authority=Apple Development: PRIVATE PERSON\nAuthority=Apple Worldwide Developer Relations\nAuthority=Apple Root CA\n"), (65, b"PRIVATE PATH"), (65, b"PRIVATE PATH")]) as tool:
            data = manifest.inspect_signing(Path("fake.app"), Path("fake.dmg"))
            self.assertEqual(data, self.development())
            self.assertIn("--deep", tool.call_args_list[0].args[0])
            self.assertIn("--strict", tool.call_args_list[0].args[0])
            self.assertIn("-R=anchor apple generic", tool.call_args_list[1].args[0])
            self.assertNotIn("PRIVATE", json.dumps(data))
        for results in [[(1, b"private")], [(0, b""), (1, b"private")], [(0, b""), (0, b""), (0, b"Authority=Unknown: PRIVATE\nAuthority=Apple Root CA")]]:
            with patch.object(manifest, "run_tool", side_effect=results), self.assertRaises(manifest.ManifestError):
                manifest.inspect_signing(Path("fake.app"), Path("fake.dmg"))

    def test_deterministic_serialization_and_privacy(self):
        data = self.fixture()
        reversed_data = dict(reversed(list(data.items())))
        reversed_data["signing"] = dict(reversed(list(data["signing"].items())))
        raw = manifest.serialize(data)
        self.assertEqual(raw, manifest.serialize(reversed_data))
        self.assertEqual(raw, manifest.serialize(self.fixture()))
        self.assertTrue(raw.endswith(b"\n"))
        self.assertFalse(raw.endswith(b"\n\n"))
        for private in [b"/Users/", b"/tmp/", b"/Volumes/", b"@", b"hostname", b"generatedAt", b"PRIVATE"]:
            self.assertNotIn(private, raw)

    def test_atomic_write_and_replace_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / manifest.MANIFEST_FILENAME
            output.write_bytes(b"original")
            with patch.object(manifest.os, "replace", side_effect=OSError("private path")), self.assertRaises(OSError):
                manifest.atomic_write(output, manifest.serialize(self.fixture()))
            self.assertEqual(output.read_bytes(), b"original")
            self.assertEqual(list(Path(directory).iterdir()), [output])
            manifest.atomic_write(output, manifest.serialize(self.fixture()))
            self.assertEqual(output.read_bytes(), manifest.serialize(self.fixture()))
            with patch.object(manifest.os, "fsync", side_effect=OSError()), self.assertRaises(OSError):
                manifest.atomic_write(output, b"bad")
            self.assertEqual(output.read_bytes(), manifest.serialize(self.fixture()))
            with self.assertRaises(manifest.ManifestError):
                manifest.atomic_write(Path(directory) / "wrong.json", b"bad")

    def test_failure_and_dry_run_do_not_write(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / manifest.MANIFEST_FILENAME
            output.write_bytes(b"original")
            args = ["--tag", "v0.3.0-beta.1", "--channel", "preview", "--dmg", "fake.dmg"]
            with patch.object(manifest, "inspect_dmg", side_effect=manifest.ManifestError("sanitized")), patch.object(manifest.sys, "stderr"):
                self.assertEqual(manifest.main(args + ["--output", str(output)]), 1)
            self.assertEqual(output.read_bytes(), b"original")
            with patch.object(manifest, "inspect_dmg", return_value=self.fixture()), patch.object(manifest.sys, "stdout") as stdout:
                self.assertEqual(manifest.main(args + ["--dry-run"]), 0)
                stdout.buffer.write.assert_called_once_with(manifest.serialize(self.fixture()))
            self.assertEqual(output.read_bytes(), b"original")

    def test_packaging_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(manifest.ManifestError):
                manifest.packaged_app(root)
            app = root / "QuotaMew.app"
            app.mkdir()
            (root / "Applications").symlink_to("/Applications")
            self.assertEqual(manifest.packaged_app(root), app)
            (app / "nested" / "QuotaMew.app").mkdir(parents=True)
            with self.assertRaises(manifest.ManifestError):
                manifest.packaged_app(root)
            (app / "nested" / "QuotaMew.app").rmdir()
            (root / "Other.app").mkdir()
            with self.assertRaises(manifest.ManifestError):
                manifest.packaged_app(root)

    def test_bundle_metadata_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / "Contents").mkdir()
            plist = app / "Contents" / "Info.plist"
            plist.write_bytes(plistlib.dumps({**self.metadata(), "unrelated": "PRIVATE"}))
            self.assertEqual(manifest.bundle_metadata(app), self.metadata())
            plist.write_bytes(b"x" * (manifest.MAX_BYTES + 1))
            with self.assertRaises(manifest.ManifestError):
                manifest.bundle_metadata(app)
            plist.write_bytes(b"broken")
            with self.assertRaises(manifest.ManifestError):
                manifest.bundle_metadata(app)
            plist.write_bytes(b'<?xml version="1.0"?><plist><dict>')
            with self.assertRaises(manifest.ManifestError):
                manifest.bundle_metadata(app)

    def test_mount_cleanup_on_failure_and_interruption(self):
        for failure in [manifest.ManifestError("validation"), KeyboardInterrupt()]:
            with patch.object(manifest, "checked", return_value=b""), patch.object(manifest.os.path, "ismount", side_effect=[True, True, False, False]), patch.object(manifest, "run_tool", return_value=(0, b"")) as tool:
                with self.assertRaises(type(failure)):
                    with manifest.mounted_dmg(Path("fake.dmg")):
                        raise failure
                self.assertEqual(tool.call_args.args[0][1], "detach")

    def test_mount_flags_and_detach_retry(self):
        with patch.object(manifest, "checked", return_value=b"") as checked, patch.object(manifest.os.path, "ismount", side_effect=[True, True, False, False]), patch.object(manifest, "run_tool", side_effect=[(1, b""), (0, b"")]) as tool:
            with manifest.mounted_dmg(Path("fake.dmg")):
                pass
            self.assertIn("-nocache", checked.call_args_list[0].args[0])
            self.assertIn("-readonly", checked.call_args_list[1].args[0])
            self.assertIn("-noverify", checked.call_args_list[1].args[0])
            self.assertIn("-force", tool.call_args_list[1].args[0])

    @unittest.skipUnless(os.environ.get("QUOTAMEW_WEBSITE_REPO"), "Optional read-only website checkout cross-check")
    def test_actual_website_parser(self):
        data = [self.fixture(), self.fixture("v0.3.0-rc.1", "preview"), self.fixture("v0.3.0", "stable")]
        developer_id = copy.deepcopy(data[0])
        developer_id["signing"] = manifest.signing_facts("developer-id", 0, 65)
        data.append(developer_id)
        with tempfile.TemporaryDirectory() as directory:
            fixtures = Path(directory) / "synthetic.json"
            fixtures.write_text(json.dumps(data), encoding="utf-8")
            result = subprocess.run([os.environ.get("BUN_BINARY", "bun"), str(Path(__file__).with_name("check_website_contract.ts")), os.environ["QUOTAMEW_WEBSITE_REPO"], str(fixtures)], capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, "Website parser compatibility failed")

    def test_process_bounds_and_reaping(self):
        with self.assertRaises(manifest.ManifestError):
            manifest.run_tool([sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.1)
        with self.assertRaises(manifest.ManifestError):
            manifest.run_tool([sys.executable, "-c", "print('x' * 70000)"])
        self.assertEqual(manifest.run_tool([sys.executable, "-c", "print('ok')"]), (0, b"ok\n"))


if __name__ == "__main__":
    unittest.main()
