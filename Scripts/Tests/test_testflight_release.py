"""Windows-compatible synthetic release-driver checks; no real secrets or tools.

Run: python -m unittest discover -s Scripts/Tests
These tests do not establish that an Xcode archive, Apple upload or device test
has passed. Every macOS tool invocation is mocked.
"""

import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import testflight_release as release


SENSITIVE = "synthetic-sensitive-value-never-real-credentials"
SETTINGS = {
    "PRODUCT_BUNDLE_IDENTIFIER": "org.synthetic.fixture",
    "MARKETING_VERSION": "0.1.0",
    "DEVELOPMENT_TEAM": "",
}


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.work = self.root / (release.WORK_PREFIX + "fixture")
        self.work.mkdir()
        self.state = {"version": 1, "keychains": None, "profile": None}
        self.write_state()

    def write_state(self):
        (self.work / release.STATE_NAME).write_text(json.dumps(self.state), encoding="utf-8")

    def private_files(self):
        for name in ("auth.p8", "distribution.p12", "raw-tool.log", "signed.ipa"):
            (self.work / name).write_text(SENSITIVE, encoding="utf-8")
        nested = self.work / "Archive.xcarchive"
        nested.mkdir()
        (nested / "private").write_text(SENSITIVE, encoding="utf-8")

    def assert_private_files_purged(self):
        if self.work.exists():
            allowed = {release.STATE_NAME, "signing.keychain-db"}
            self.assertFalse({p.name for p in self.work.iterdir()} - allowed)

    def run_main(self, outcome=None, cleanup_error=None):
        captured_credentials = []

        def fake_release(work, credentials):
            self.assertEqual(work, self.work)
            self.assertTrue(all(name not in os.environ for name in release.SECRET_NAMES))
            self.assertTrue(all(credentials[name] == SENSITIVE for name in release.SECRET_NAMES))
            captured_credentials.append(credentials)
            if outcome:
                raise outcome

        env = {name: SENSITIVE for name in release.SECRET_NAMES}
        env["TESTFLIGHT_WORK_DIR"] = str(self.work)
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, env), \
                patch.object(release, "checked_work_dir", return_value=self.work), \
                patch.object(release, "release", side_effect=fake_release), \
                patch.object(release, "cleanup", side_effect=cleanup_error) as cleanup, \
                patch.object(release.signal, "signal"), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = release.main(["--release"])
            self.assertTrue(all(name not in os.environ for name in release.SECRET_NAMES))
        cleanup.assert_called_once_with(self.work)
        self.assertEqual(captured_credentials, [{}])
        self.assertNotIn(SENSITIVE, stdout.getvalue() + stderr.getvalue())
        return result, stdout.getvalue(), stderr.getvalue()

    def test_main_success_cleans_and_discards_secret_environment(self):
        result, stdout, stderr = self.run_main()
        self.assertEqual(result, 0)
        self.assertIn("Private signing files removed", stdout)
        self.assertEqual(stderr, "")

    def test_main_expected_failure_still_cleans(self):
        result, _, stderr = self.run_main(release.ReleaseError("SIGNED_ARCHIVE_FAILED"))
        self.assertEqual(result, 1)
        self.assertIn("SIGNED_ARCHIVE_FAILED", stderr)

    def test_main_unexpected_exception_never_prints_exception_contents(self):
        result, _, stderr = self.run_main(RuntimeError(SENSITIVE))
        self.assertEqual(result, 1)
        self.assertIn("UNEXPECTED_PRIVATE_OPERATION_FAILED", stderr)

    def test_main_interrupt_still_cleans(self):
        result, _, stderr = self.run_main(KeyboardInterrupt(SENSITIVE))
        self.assertEqual(result, 1)
        self.assertNotIn("Traceback", stderr)

    def test_main_cleanup_error_is_sanitized_and_fails_job(self):
        result, stdout, stderr = self.run_main(cleanup_error=RuntimeError(SENSITIVE))
        self.assertEqual(result, 1)
        self.assertNotIn("Private signing files removed", stdout)
        self.assertIn("CLEANUP_INCOMPLETE_RETRY_REQUIRED", stderr)

    def test_private_tools_drop_secrets_from_child_environment(self):
        with patch.dict(os.environ, {name: SENSITIVE for name in release.SECRET_NAMES}):
            tool = release.PrivateTools(self.work)
        process = Mock(returncode=0)
        process.communicate.return_value = (b"", None)
        with patch.object(release.subprocess, "Popen", return_value=process) as popen:
            tool.run("SAFE_CODE", ["synthetic-tool"])
        child = popen.call_args.kwargs["env"]
        self.assertTrue(all(name not in child for name in release.SECRET_NAMES))
        self.assertEqual(child["LC_ALL"], "C")
        self.assertTrue(child["TMPDIR"].startswith(str(self.work)))
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_private_tools_capture_output_without_console_echo(self):
        tool = release.PrivateTools(self.work)

        def fake_popen(*_args, **kwargs):
            kwargs["stderr"].write(SENSITIVE.encode())
            process = Mock(returncode=0)
            process.communicate.return_value = (SENSITIVE.encode(), None)
            return process

        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(release.subprocess, "Popen", side_effect=fake_popen), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = tool.run("SAFE_CODE", ["synthetic-tool", SENSITIVE], capture=True)
        self.assertEqual(result, SENSITIVE.encode())
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")

    def test_private_tools_failure_never_includes_command_or_raw_output(self):
        tool = release.PrivateTools(self.work)
        with patch.object(release.subprocess, "Popen", side_effect=OSError(SENSITIVE)):
            with self.assertRaisesRegex(release.ReleaseError, "^SAFE_CODE$"):
                tool.run("SAFE_CODE", ["synthetic-tool", SENSITIVE])

    def test_private_tools_nonzero_exit_is_fixed_error(self):
        tool = release.PrivateTools(self.work)
        process = Mock(returncode=9)
        process.communicate.return_value = (SENSITIVE.encode(), None)
        with patch.object(release.subprocess, "Popen", return_value=process):
            with self.assertRaisesRegex(release.ReleaseError, "^SAFE_CODE$"):
                tool.run("SAFE_CODE", ["synthetic-tool", SENSITIVE], capture=True)

    def test_private_tools_timeout_terminates_process_group_before_returning(self):
        tool = release.PrivateTools(self.work)
        process = Mock(pid=123456, returncode=-15)
        process.communicate.side_effect = [subprocess.TimeoutExpired(SENSITIVE, 1), (b"", None)]
        with patch.object(release.subprocess, "Popen", return_value=process), \
                patch.object(release.os, "killpg", create=True) as killpg:
            with self.assertRaisesRegex(release.ReleaseError, "^SAFE_CODE$"):
                tool.run("SAFE_CODE", ["synthetic-tool", SENSITIVE], timeout=1)
        killpg.assert_called_once_with(process.pid, release.signal.SIGTERM)
        self.assertEqual(process.communicate.call_args_list[0].kwargs, {"timeout": 1})
        self.assertEqual(process.communicate.call_args_list[1].kwargs, {"timeout": 5})

    def test_private_tools_timeout_escalates_to_kill_for_lingering_group(self):
        tool = release.PrivateTools(self.work)
        process = Mock(pid=123456, returncode=-9)
        process.communicate.side_effect = [
            subprocess.TimeoutExpired(SENSITIVE, 1),
            subprocess.TimeoutExpired(SENSITIVE, 5), (b"", None),
        ]
        with patch.object(release.subprocess, "Popen", return_value=process), \
                patch.object(release.os, "killpg", create=True) as killpg, \
                patch.object(release.signal, "SIGKILL", 9, create=True):
            with self.assertRaisesRegex(release.ReleaseError, "^SAFE_CODE$"):
                tool.run("SAFE_CODE", ["synthetic-tool", SENSITIVE], timeout=1)
        self.assertEqual([call.args for call in killpg.call_args_list],
                         [(123456, release.signal.SIGTERM), (123456, 9)])
        self.assertEqual(process.communicate.call_count, 3)

    def test_private_tools_interrupt_terminates_process_group(self):
        tool = release.PrivateTools(self.work)
        process = Mock(pid=123456, returncode=-15)
        process.communicate.side_effect = [KeyboardInterrupt(), (b"", None)]
        with patch.object(release.subprocess, "Popen", return_value=process), \
                patch.object(release.os, "killpg", create=True) as killpg:
            with self.assertRaises(KeyboardInterrupt):
                tool.run("SAFE_CODE", ["synthetic-tool"])
        killpg.assert_called_once_with(process.pid, release.signal.SIGTERM)
        self.assertEqual(process.communicate.call_count, 2)

    def test_apple_command_accepts_nonempty_success_object_without_console_output(self):
        tool = Mock()
        tool.run.return_value = json.dumps({"success-message": "Validation succeeded.", "delivery": {"id": SENSITIVE}}).encode()
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            release.apple_command(tool, "APPLE_FAILED", ["synthetic-altool"], {"ENV": "fixture"}, 60)
        tool.run.assert_called_once_with("APPLE_FAILED", ["synthetic-altool"], capture=True,
                                         env={"ENV": "fixture"}, timeout=60)
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")

    def test_apple_command_rejects_malformed_json_without_leaking_tool_output(self):
        tool = Mock()
        for raw in (b"", SENSITIVE.encode(), b"{", b"\xff"):
            with self.subTest(raw=raw):
                tool.run.return_value = raw
                with self.assertRaisesRegex(release.ReleaseError, "^APPLE_FAILED$"):
                    release.apple_command(tool, "APPLE_FAILED", ["synthetic-altool"], {}, 60)

    def test_apple_command_rejects_empty_or_nonobject_json(self):
        tool = Mock()
        for response in ({}, [], ["success"], True, None, 0, "success"):
            with self.subTest(response=response):
                tool.run.return_value = json.dumps(response).encode()
                with self.assertRaisesRegex(release.ReleaseError, "^APPLE_FAILED$"):
                    release.apple_command(tool, "APPLE_FAILED", ["synthetic-altool"], {}, 60)

    def test_apple_command_rejects_nested_structured_errors_even_with_exit_zero(self):
        tool = Mock()
        responses = (
            {"error": SENSITIVE},
            {"errors": [{"message": SENSITIVE}]},
            {"product-errors": [{"code": 1, "message": SENSITIVE}]},
            {"details": {"ERRORS": [{"message": SENSITIVE}]}},
            {"details": [{"result": {"product-errors": [SENSITIVE]}}]},
        )
        for response in responses:
            with self.subTest(response=response):
                tool.run.return_value = json.dumps(response).encode()
                with self.assertRaisesRegex(release.ReleaseError, "^APPLE_FAILED$"):
                    release.apple_command(tool, "APPLE_FAILED", ["synthetic-altool"], {}, 60)

    def test_apple_command_allows_empty_error_fields(self):
        tool = Mock()
        tool.run.return_value = json.dumps({"success": True, "errors": [], "error": None,
                                           "product-errors": {}}).encode()
        release.apple_command(tool, "APPLE_FAILED", ["synthetic-altool"], {}, 60)

    def test_apple_command_propagates_fixed_tool_failure(self):
        tool = Mock()
        tool.run.side_effect = release.ReleaseError("APPLE_FAILED")
        with self.assertRaisesRegex(release.ReleaseError, "^APPLE_FAILED$"):
            release.apple_command(tool, "APPLE_FAILED", ["synthetic-altool"], {}, 60)

    def test_cleanup_success_removes_all_private_files_and_restores_search_list(self):
        profiles = self.root / "profiles"
        profiles.mkdir()
        profile = profiles / "11111111-2222-3333-AAAA-555555555555.mobileprovision"
        profile.write_text(SENSITIVE, encoding="utf-8")
        self.state.update(keychains=["/synthetic/original.keychain-db"], profile=str(profile))
        self.write_state()
        self.private_files()
        (self.work / "signing.keychain-db").write_text(SENSITIVE)
        with patch.object(release, "profile_directory", return_value=profiles), \
                patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            release.cleanup(self.work)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["security", "list-keychains", "-d", "user", "-s", "/synthetic/original.keychain-db"], commands)
        self.assertIn(["security", "delete-keychain", str(self.work / "signing.keychain-db")], commands)
        self.assertFalse(profile.exists())
        self.assertFalse(self.work.exists())

    def test_cleanup_security_failure_still_purges_private_files(self):
        self.state["keychains"] = ["/synthetic/original.keychain-db"]
        self.write_state()
        self.private_files()
        (self.work / "signing.keychain-db").write_text(SENSITIVE)
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run:
            with self.assertRaises(release.ReleaseError):
                release.cleanup(self.work)
        self.assertGreaterEqual(run.call_count, 2)
        self.assert_private_files_purged()
        self.assertTrue((self.work / release.STATE_NAME).exists())

    def test_cleanup_missing_tool_still_purges_private_files(self):
        self.state["keychains"] = []
        self.write_state()
        self.private_files()
        with patch.object(release.subprocess, "run", side_effect=OSError(SENSITIVE)):
            with self.assertRaises(release.ReleaseError):
                release.cleanup(self.work)
        self.assert_private_files_purged()

    def test_cleanup_corrupt_state_still_purges_private_files(self):
        self.private_files()
        (self.work / release.STATE_NAME).write_text("{invalid", encoding="utf-8")
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaises(release.ReleaseError):
                release.cleanup(self.work)
        self.assert_private_files_purged()

    def test_cleanup_invalid_state_version_still_purges_private_files(self):
        self.private_files()
        self.state["version"] = 99
        self.write_state()
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaises(release.ReleaseError):
                release.cleanup(self.work)
        self.assert_private_files_purged()

    def test_cleanup_rejects_external_profile_but_purges_private_files(self):
        external = self.root / "do-not-delete.mobileprovision"
        external.write_text("unowned", encoding="utf-8")
        self.state["profile"] = str(external)
        self.write_state()
        self.private_files()
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaises(release.ReleaseError):
                release.cleanup(self.work)
        self.assertEqual(external.read_text(encoding="utf-8"), "unowned")
        self.assert_private_files_purged()

    def test_cleanup_missing_directory_is_idempotent(self):
        missing = self.root / (release.WORK_PREFIX + "already-cleaned")
        with patch.object(release.subprocess, "run") as run:
            release.cleanup(missing)
        run.assert_not_called()

    def test_guard_rejects_runner_root_itself(self):
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            with self.assertRaisesRegex(release.ReleaseError, "PRIVATE_WORKSPACE_REJECTED"):
                release.checked_work_dir(str(self.root), allow_missing=True)

    def test_guard_rejects_other_directory(self):
        other = self.root / "not-owned"
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            with self.assertRaisesRegex(release.ReleaseError, "PRIVATE_WORKSPACE_REJECTED"):
                release.checked_work_dir(str(other), allow_missing=True)

    def test_guard_rejects_nested_directory(self):
        nested = self.work / (release.WORK_PREFIX + "nested")
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            with self.assertRaisesRegex(release.ReleaseError, "PRIVATE_WORKSPACE_REJECTED"):
                release.checked_work_dir(str(nested), allow_missing=True)

    def test_guard_rejects_prefix_without_unique_suffix(self):
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            with self.assertRaisesRegex(release.ReleaseError, "PRIVATE_WORKSPACE_REJECTED"):
                release.checked_work_dir(str(self.root / release.WORK_PREFIX), allow_missing=True)

    def test_guard_accepts_missing_owned_path_for_repeat_cleanup(self):
        owned = self.root / (release.WORK_PREFIX + "already-cleaned")
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            self.assertEqual(release.checked_work_dir(str(owned), allow_missing=True), owned.resolve())

    def test_profile_validation_failure_prevents_archive(self):
        tool = Mock(work=self.work)
        credentials = {name: SENSITIVE for name in release.SECRET_NAMES}
        with patch.object(release.sys, "platform", "darwin"), \
                patch.dict(os.environ, {"RUNNER_DEBUG": "0"}), \
                patch.object(release, "PrivateTools", return_value=tool), \
                patch.object(release, "build_settings", return_value=SETTINGS), \
                patch.object(release, "decode_secret_file"), \
                patch.object(release, "import_identity", return_value=(self.work / "signing.keychain-db", "A" * 40, b"certificate", "A" * 10)), \
                patch.object(release, "read_profile", return_value={}), \
                patch.object(release, "validate_profile", side_effect=release.SigningValidationError("Profile invalid.")), \
                patch.object(release, "install_profile") as install:
            with self.assertRaises(release.SigningValidationError):
                release.release(self.work, credentials)
        tool.run.assert_not_called()
        install.assert_not_called()

    def test_certificate_team_extracted_only_from_subject_not_repeated_full_text(self):
        certificate = b"synthetic certificate bytes, not an actual credential"
        fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        subject = b"subject=\n    CN=Apple Distribution: Synthetic Fixture\n    OU=ABCDEFGHIJ\n"
        details = (b"Certificate:\n    Issuer:\n        OU=ABCDEFGHIJ\n"
                   b"    Subject:\n        OU=ABCDEFGHIJ\n"
                   b"    1.2.840.113635.100.6.1.4:\n"
                   b"notBefore=Jan  1 00:00:00 2020 GMT\n")

        def fake_run(_code, args, **_kwargs):
            if "find-identity" in args:
                return ('  1) ' + fingerprint + ' "Apple Distribution: Synthetic Fixture"\n').encode()
            if "find-certificate" in args:
                return b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(certificate) + b"\n-----END CERTIFICATE-----\n"
            if "list-keychains" in args and "-s" not in args:
                return b'"/synthetic/original.keychain-db"\n'
            if "-subject" in args:
                return subject + (details if "-text" in args else b"")
            if "-text" in args:
                return details
            return b""

        tool = Mock(work=self.work)
        tool.run.side_effect = fake_run
        result = release.import_identity(tool, self.state, SENSITIVE)
        self.assertEqual(result[1:], (fingerprint, certificate, "ABCDEFGHIJ"))
        subject_calls = [call.args[1] for call in tool.run.call_args_list if "-subject" in call.args[1]]
        self.assertEqual(len(subject_calls), 1)
        self.assertNotIn("-text", subject_calls[0])

    def make_app(self, **overrides):
        app = self.work / "FitPhotoSpike.app"
        app.mkdir()
        info = {
            "CFBundleIdentifier": SETTINGS["PRODUCT_BUNDLE_IDENTIFIER"],
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1.1.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "DTPlatformName": "iphoneos", "CFBundleExecutable": "FitPhotoSpike",
        }
        info.update(overrides)
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "FitPhotoSpike").write_bytes(b"synthetic Mach-O")
        return app

    def check_rejected_app(self, app, code, macho_error=None):
        tool = Mock(work=self.work)
        with patch.object(release, "inspect_macho", side_effect=macho_error):
            with self.assertRaisesRegex(release.ReleaseError, code):
                release.verify_signed_app(tool, app, SETTINGS, "1.1.0", SimpleNamespace(), b"certificate", "Archive")
        tool.run.assert_not_called()

    def test_rejects_missing_archive_app(self):
        self.check_rejected_app(self.work / "absent.app", "SIGNED_APP_MISSING")

    def test_rejects_simulator_app_platform(self):
        self.check_rejected_app(self.make_app(CFBundleSupportedPlatforms=["iPhoneSimulator"], DTPlatformName="iphonesimulator"), "SIGNED_PLATFORM_INVALID")

    def test_rejects_wrong_bundle_identifier(self):
        self.check_rejected_app(self.make_app(CFBundleIdentifier="org.other.fixture"), "SIGNED_BUNDLE_MISMATCH")

    def test_rejects_wrong_build_number(self):
        self.check_rejected_app(self.make_app(CFBundleVersion="1.0.0"), "SIGNED_VERSION_MISMATCH")

    def test_rejects_wrong_binary_architecture_without_raw_exception(self):
        self.check_rejected_app(self.make_app(), "DEVICE_BINARY_INVALID", macho_error=ValueError(SENSITIVE))

    def test_ipa_path_traversal_rejected_before_extraction(self):
        ipa = self.work / "signed.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/../../outside", b"invalid")
        tool = Mock(work=self.work)
        with self.assertRaisesRegex(release.ReleaseError, "IPA_PATH_INVALID"):
            release.extract_ipa(tool, ipa)
        tool.run.assert_not_called()

    def test_ipa_absolute_path_rejected_before_extraction(self):
        ipa = self.work / "signed.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("/outside", b"invalid")
        tool = Mock(work=self.work)
        with self.assertRaisesRegex(release.ReleaseError, "IPA_PATH_INVALID"):
            release.extract_ipa(tool, ipa)
        tool.run.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
