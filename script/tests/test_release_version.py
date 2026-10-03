"""Source release policy checks; no website, network, signing, or DMG required."""

from pathlib import Path
import re
import unittest

from test_release_manifest import manifest

ROOT = Path(__file__).resolve().parents[2]
TAG = "v0.3.0-beta.1"
CORE = "0.3.0"
BUILD = 6
ARTIFACT = "QuotaMew-v0.3.0-beta.1.dmg"


class ReleaseVersionTests(unittest.TestCase):
    def app_settings(self):
        project = (ROOT / "QuotaMew.xcodeproj/project.pbxproj").read_text()
        blocks = re.findall(r"buildSettings = \{(.*?)\n\s*\};\n\s*name = (Debug|Release);", project, re.S)
        app = {}
        for block, configuration in blocks:
            match = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = (dev\.quotapulse\.(?:development\.)?app);", block)
            if match:
                self.assertNotIn(configuration, app)
                app[configuration] = (block, match[1])
        self.assertEqual(set(app), {"Debug", "Release"})
        return app

    def test_app_source_version_and_generated_plist(self):
        for configuration, (block, _) in self.app_settings().items():
            with self.subTest(configuration=configuration):
                self.assertRegex(block, rf"MARKETING_VERSION = {re.escape(CORE)};")
                self.assertRegex(block, rf"CURRENT_PROJECT_VERSION = {BUILD};")
                self.assertIn("GENERATE_INFOPLIST_FILE = YES;", block)
                self.assertNotIn("INFOPLIST_FILE = ", block.replace("GENERATE_INFOPLIST_FILE = YES;", ""))

    def test_beta_generator_accepts_app_core_and_build(self):
        data = manifest.candidate(TAG, "preview", ARTIFACT, {
            "CFBundleShortVersionString": CORE, "CFBundleVersion": str(BUILD),
            "CFBundleIdentifier": "dev.quotapulse.app", "LSMinimumSystemVersion": "14.0",
        }, manifest.signing_facts("apple-development", 65, 65))
        self.assertEqual(data["version"], "0.3.0-beta.1")
        self.assertEqual(data["build"], BUILD)
        self.assertEqual(data["channel"], "preview")
        self.assertEqual(data["artifact"]["filename"], ARTIFACT)
        self.assertEqual(manifest.MANIFEST_FILENAME, "quotamew-release-manifest.json")

    def test_stable_and_preview_identity_are_distinct(self):
        self.assertEqual(manifest.identity(TAG, "preview", ARTIFACT), ("0.3.0-beta.1", CORE))
        self.assertEqual(manifest.identity("v0.2.0", "stable", "QuotaMew-v0.2.0.dmg"), ("0.2.0", "0.2.0"))
        for tag, channel, filename in [(TAG, "stable", ARTIFACT), ("v0.2.0", "preview", "QuotaMew-v0.2.0.dmg")]:
            with self.assertRaises(manifest.ManifestError):
                manifest.identity(tag, channel, filename)

    def test_bundle_identity_and_signing_configuration_remain_compatible(self):
        app = self.app_settings()
        self.assertEqual(app["Debug"][1], "dev.quotapulse.development.app")
        self.assertEqual(app["Release"][1], "dev.quotapulse.app")
        for block, _ in app.values():
            self.assertIn('CODE_SIGN_IDENTITY = "Apple Development";', block)
            self.assertIn('"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Apple Development";', block)
            self.assertIn("CODE_SIGN_STYLE = Automatic;", block)


if __name__ == "__main__":
    unittest.main()
