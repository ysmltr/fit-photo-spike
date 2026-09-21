"""Synthetic verification regression tests; no Apple tools or real certificates."""

import contextlib
import io
from pathlib import Path
import plistlib
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import testflight_release as release


LEAF = b"synthetic expected leaf bytes; not a certificate"
OTHER = b"synthetic different leaf bytes; not a certificate"
SETTINGS = {"PRODUCT_BUNDLE_IDENTIFIER": "org.synthetic.fixture", "MARKETING_VERSION": "1.0"}


class CertificateExtractionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name) / "private workspace with spaces"
        self.work.mkdir()
        self.app = self.work / "fixture app with spaces.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": SETTINGS["PRODUCT_BUNDLE_IDENTIFIER"],
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1.1.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos",
            "CFBundleExecutable": "FitPhotoSpike",
        }))
        (self.app / "FitPhotoSpike").write_bytes(b"synthetic executable; not Mach-O")
        (self.app / "embedded.mobileprovision").write_bytes(b"synthetic placeholder; not CMS")
        release.write_state(self.work, {"version": 1, "keychains": None, "profile": None})
        self.identity = SimpleNamespace(team_id="FAKETEAM01", uuid="synthetic-profile-id")

    @contextlib.contextmanager
    def verification(self, label="Archive", leaf=LEAF, fail=False, omit_leaf=False):
        tool = Mock(work=self.work)
        output = io.StringIO()

        def fake_run(code, args, **_kwargs):
            argv = [str(value) for value in args]
            if code == "SIGNED_CERTIFICATE_UNAVAILABLE":
                if fail:
                    raise release.ReleaseError(code)
                # codesign requires its optional prefix attached to this option.
                # Whitespace inside a path must remain in this one argument.
                prefix = str(self.work / (label + "-certificate-"))
                self.assertEqual(argv, ["codesign", "--display",
                                       "--extract-certificates=" + prefix, str(self.app)])
                if not omit_leaf:
                    Path(prefix + "0").write_bytes(leaf)
                Path(prefix + "1").write_bytes(LEAF)
            if code == "SIGNED_ENTITLEMENTS_UNAVAILABLE":
                return plistlib.dumps({"synthetic": True})
            return b""

        tool.run.side_effect = fake_run
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                patch.object(release, "inspect_macho"), \
                patch.object(release, "inspect_metadata"), \
                patch.object(release, "read_profile", return_value={}) as read_profile, \
                patch.object(release, "validate_profile", return_value=self.identity), \
                patch.object(release, "validate_signed_entitlements") as entitlements:
            yield tool, output, read_profile, entitlements
        text = output.getvalue()
        for forbidden in (str(self.work), str(self.app), LEAF.decode(), OTHER.decode(),
                          "--extract-certificates", self.identity.team_id, self.identity.uuid):
            self.assertNotIn(forbidden, text)

    def verify(self, tool, label="Archive"):
        release.verify_signed_app(tool, self.app, SETTINGS, "1.1.0", self.identity, LEAF, label)

    def test_archive_extraction_uses_attached_prefix_and_checks_following_policy(self):
        with self.verification() as (tool, output, read_profile, entitlements):
            self.verify(tool)
            read_profile.assert_called_once_with(tool, self.app / "embedded.mobileprovision")
            entitlements.assert_called_once()
            self.assertIn("Archive:", output.getvalue())

    def test_ipa_extraction_uses_its_private_prefix_with_spaces_intact(self):
        with self.verification(label="IPA") as (tool, output, _, entitlements):
            self.verify(tool, "IPA")
            self.assertTrue((self.work / "IPA-certificate-0").is_file())
            entitlements.assert_called_once()
            self.assertIn("IPA:", output.getvalue())

    def test_different_leaf_is_rejected_even_if_chain_certificate_matches(self):
        with self.verification(leaf=OTHER) as (tool, output, read_profile, entitlements):
            with self.assertRaisesRegex(release.ReleaseError, "^SIGNED_CERTIFICATE_MISMATCH$"):
                self.verify(tool)
            read_profile.assert_not_called()
            entitlements.assert_not_called()
            self.assertEqual(output.getvalue(), "")

    def test_extraction_failure_still_stops_verification(self):
        with self.verification(fail=True) as (tool, output, read_profile, entitlements):
            with self.assertRaisesRegex(release.ReleaseError, "^SIGNED_CERTIFICATE_UNAVAILABLE$"):
                self.verify(tool)
            read_profile.assert_not_called()
            entitlements.assert_not_called()
            self.assertEqual(output.getvalue(), "")

    def test_missing_leaf_never_accepts_a_matching_intermediate(self):
        with self.verification(omit_leaf=True) as (tool, output, read_profile, entitlements):
            with self.assertRaises(FileNotFoundError):
                self.verify(tool)
            read_profile.assert_not_called()
            entitlements.assert_not_called()
            self.assertEqual(output.getvalue(), "")

    def test_existing_cleanup_removes_synthetic_extracted_chain(self):
        with self.verification() as (tool, _, _, _):
            self.verify(tool)
        self.assertTrue((self.work / "Archive-certificate-0").exists())
        with patch.object(release.subprocess, "run") as external:
            release.cleanup(self.work)
            external.assert_not_called()
        self.assertFalse(self.work.exists())


if __name__ == "__main__":
    unittest.main()
