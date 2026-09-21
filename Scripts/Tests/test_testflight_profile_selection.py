"""Synthetic UUID transport checks; these do not emulate Xcode profile lookup.

No real credentials or Apple tools are used. Tests establish literal UUID
preservation and cleanup behavior, not Xcode's UUID case-sensitivity or the cause
of a real archive failure. Run with: python -m unittest discover -s Scripts/Tests
"""

import contextlib
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import testflight_release as release
import testflight_signing as signing


LOWER_UUID = "01234567-89ab-4cde-8f01-23456789abcd"
UPPER_UUID = LOWER_UUID.upper()
MIXED_UUID = "01234567-89aB-4cDe-8F01-23456789AbCd"
UUIDS = (LOWER_UUID, UPPER_UUID, MIXED_UUID)
TEAM = "FAKETEAM01"
BUNDLE = "org.synthetic.profilefixture"
CERTIFICATE = b"synthetic certificate bytes; not DER or signing material"
PROFILE_BYTES = b"synthetic profile bytes; not CMS or provisioning material"
NOW = datetime(2026, 9, 20, tzinfo=timezone.utc)


def synthetic_profile(uuid):
    return {
        "UUID": uuid,
        "Name": "Synthetic Profile Name Distinct From UUID",
        "TeamIdentifier": [TEAM],
        "ApplicationIdentifierPrefix": [TEAM],
        "Platform": ["iOS"],
        "CreationDate": NOW - timedelta(days=1),
        "ExpirationDate": NOW + timedelta(days=30),
        "DeveloperCertificates": [CERTIFICATE],
        "Entitlements": {
            "application-identifier": TEAM + "." + BUNDLE,
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": False,
            "beta-reports-active": True,
        },
    }


def validated_identity(uuid):
    return signing.validate_profile(
        synthetic_profile(uuid), BUNDLE, TEAM, CERTIFICATE, now=NOW)


class ProfileSelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.work = self.root / "private-work"
        self.work.mkdir()
        self.profiles = self.root / "synthetic-installed-profiles"
        self.profiles.mkdir()
        self.state = {"version": 1, "keychains": None, "profile": None}
        release.write_state(self.work, self.state)

    def test_lowercase_uuid_is_preserved_after_validation(self):
        self.assertEqual(validated_identity(LOWER_UUID).uuid, LOWER_UUID)

    def test_uppercase_uuid_is_preserved_after_validation(self):
        self.assertEqual(validated_identity(UPPER_UUID).uuid, UPPER_UUID)

    def test_mixed_case_uuid_is_preserved_after_validation(self):
        self.assertEqual(validated_identity(MIXED_UUID).uuid, MIXED_UUID)

    def test_export_profile_map_preserves_each_literal_uuid(self):
        for uuid in UUIDS:
            with self.subTest(case=UUIDS.index(uuid)):
                options = signing.export_options(BUNDLE, TEAM, uuid, "A" * 40)
                self.assertEqual(options["provisioningProfiles"], {BUNDLE: uuid})

    def test_installation_preserves_uuid_filename_and_profile_bytes_without_output(self):
        (self.work / "profile.mobileprovision").write_bytes(PROFILE_BYTES)
        output = io.StringIO()
        for uuid in UUIDS:
            with self.subTest(case=UUIDS.index(uuid)), \
                    patch.object(release, "profile_directory", return_value=self.profiles), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                release.install_profile(self.work, self.state, validated_identity(uuid))
                installed = self.profiles / (uuid + ".mobileprovision")
                self.assertEqual(installed.read_bytes(), PROFILE_BYTES)
                self.assertEqual(self.state["profile"], str(installed))
                self.assertEqual(json.loads((self.work / release.STATE_NAME).read_text())["profile"],
                                 str(installed))
                installed.unlink()  # Windows/macOS may use a case-insensitive filesystem.
        self.assertEqual(output.getvalue(), "")

    def test_archive_arguments_preserve_uuid_without_using_profile_name_or_logging_values(self):
        for uuid in UUIDS:
            with self.subTest(case=UUIDS.index(uuid)):
                release.write_state(self.work, {"version": 1, "keychains": None, "profile": None})
                key_folder = self.work / "private_keys"
                if key_folder.exists():
                    key_folder.rmdir()
                profile = synthetic_profile(uuid)
                tool = Mock(work=self.work, env={})

                def fake_run(code, _args, **_kwargs):
                    if code == "SIGNED_ARCHIVE_FAILED":
                        raise release.ReleaseError("SYNTHETIC_ARCHIVE_STOP")
                    return b""

                tool.run.side_effect = fake_run
                credentials = {name: "synthetic-only" for name in release.SECRET_NAMES}
                credentials["APP_STORE_CONNECT_KEY_ID"] = "SYNTHETIC"
                credentials["APP_STORE_CONNECT_PRIVATE_KEY"] = (
                    "-----BEGIN PRIVATE KEY-----\nnot-a-key; synthetic-only\n")
                client = Mock(spec=release.ConnectClient)
                client.existing_build_versions.return_value = []
                output = io.StringIO()
                settings = {"PRODUCT_BUNDLE_IDENTIFIER": BUNDLE,
                            "MARKETING_VERSION": "0.1.0", "DEVELOPMENT_TEAM": ""}
                with patch.object(release.sys, "platform", "darwin"), \
                        patch.dict(os.environ, {"RUNNER_DEBUG": "0"}), \
                        patch.object(release, "PrivateTools", return_value=tool), \
                        patch.object(release, "build_settings", return_value=settings), \
                        patch.object(release, "decode_secret_file"), \
                        patch.object(release, "import_identity", return_value=(
                            self.work / "synthetic.keychain-db", "A" * 40, CERTIFICATE, TEAM)), \
                        patch.object(release, "read_profile", return_value=profile), \
                        patch.object(release, "validate_profile", side_effect=lambda *args:
                                     signing.validate_profile(*args, now=NOW)), \
                        patch.object(release, "install_profile"), \
                        patch.object(release, "private_write"), \
                        patch.object(release, "ConnectClient", return_value=client), \
                        patch.object(release, "choose_build_number", return_value="1.1.0"), \
                        contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    with self.assertRaisesRegex(release.ReleaseError, "^SYNTHETIC_ARCHIVE_STOP$"):
                        release.release(self.work, credentials)
                archive_calls = [call for call in tool.run.call_args_list
                                 if call.args[0] == "SIGNED_ARCHIVE_FAILED"]
                self.assertEqual(len(archive_calls), 1)
                arguments = archive_calls[0].args[1]
                specifiers = [arg for arg in arguments if isinstance(arg, str)
                              and arg.startswith("PROVISIONING_PROFILE_SPECIFIER=")]
                self.assertEqual(specifiers, ["PROVISIONING_PROFILE_SPECIFIER=" + uuid])
                self.assertNotIn(profile["Name"], arguments)
                for value in (uuid, profile["Name"], TEAM, BUNDLE, str(self.work), "synthetic-only"):
                    self.assertNotIn(value, output.getvalue())
                client.assert_build_still_available.assert_not_called()

    def test_invalid_uuid_inputs_still_fail_with_fixed_message_and_no_output(self):
        invalid = (None, 123, "", "0" * 32, "00000000-0000-0000-0000-000000000000",
                   LOWER_UUID.replace("-", ""), "{" + LOWER_UUID + "}",
                   LOWER_UUID + "\n", "../" + LOWER_UUID, "g" + LOWER_UUID[1:])
        output = io.StringIO()
        for index, uuid in enumerate(invalid):
            with self.subTest(index=index), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                with self.assertRaisesRegex(signing.SigningValidationError, "^Profile UUID is invalid\\.$"):
                    validated_identity(uuid)
        self.assertEqual(output.getvalue(), "")

    def test_cleanup_removes_owned_lowercase_and_mixed_case_profiles_without_output(self):
        output = io.StringIO()
        for uuid in (LOWER_UUID, MIXED_UUID):
            with self.subTest(case=UUIDS.index(uuid)):
                self.work.mkdir(exist_ok=True)
                installed = self.profiles / (uuid + ".mobileprovision")
                installed.write_bytes(PROFILE_BYTES)
                release.write_state(self.work, {"version": 1, "keychains": None,
                                                "profile": str(installed)})
                with patch.object(release, "profile_directory", return_value=self.profiles), \
                        contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    release.cleanup(self.work)
                self.assertFalse(installed.exists())
                self.assertFalse(self.work.exists())
        self.assertEqual(output.getvalue(), "")

    def test_cleanup_rejects_foreign_parent_without_removing_file_or_printing_path(self):
        foreign = self.root / (LOWER_UUID + ".mobileprovision")
        foreign.write_bytes(PROFILE_BYTES)
        release.write_state(self.work, {"version": 1, "keychains": None, "profile": str(foreign)})
        output = io.StringIO()
        with patch.object(release, "profile_directory", return_value=self.profiles), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaisesRegex(release.ReleaseError, "^CLEANUP_INCOMPLETE_RETRY_REQUIRED$"):
                release.cleanup(self.work)
        self.assertEqual(foreign.read_bytes(), PROFILE_BYTES)
        self.assertEqual(output.getvalue(), "")

    def test_cleanup_rejects_symlink_status_without_removing_target_or_printing_path(self):
        installed = self.profiles / (MIXED_UUID + ".mobileprovision")
        installed.write_bytes(PROFILE_BYTES)
        release.write_state(self.work, {"version": 1, "keychains": None, "profile": str(installed)})
        original_is_symlink = Path.is_symlink
        output = io.StringIO()
        # Simulate symlink metadata so Windows does not require elevated privileges.
        with patch.object(release, "profile_directory", return_value=self.profiles), \
                patch.object(Path, "is_symlink", lambda path:
                             path == installed or original_is_symlink(path)), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaisesRegex(release.ReleaseError, "^CLEANUP_INCOMPLETE_RETRY_REQUIRED$"):
                release.cleanup(self.work)
        self.assertEqual(installed.read_bytes(), PROFILE_BYTES)
        self.assertEqual(output.getvalue(), "")

    def test_profile_directory_remains_modern_xcode_user_directory(self):
        with patch.object(Path, "home", return_value=self.root):
            self.assertEqual(release.profile_directory(), self.root /
                             "Library/Developer/Xcode/UserData/Provisioning Profiles")


if __name__ == "__main__":
    unittest.main()
