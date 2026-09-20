"""Synthetic tests: never use real signing files, identities, or credentials."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import testflight_release as release


SENTINEL = "SYNTHETIC_PRIVATE_SENTINEL_DO_NOT_PRINT"
ERROR = "SIGNED_ARCHIVE_FAILED"
TASKS = {
    "CODE_SIGN", "SWIFT_COMPILE", "SWIFT_MODULE", "SWIFT_DRIVER",
    "COMPILE_C", "LINK", "ASSET_CATALOG", "APP_INTENTS_METADATA",
    "INFO_PLIST", "BUILD_SCRIPT",
}
HINTS = {
    "PROFILE_LOOKUP", "PROFILE_COMPATIBILITY", "SIGNING_IDENTITY_LOOKUP",
    "SDK_OR_DESTINATION", "SECURITY_TOOL_ERROR", "KEYCHAIN_INTERACTION",
    "DISK_SPACE", "NO_RECOGNIZED_HINT",
}


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.log = Path(self.temp.name) / "synthetic.log"

    def summarize(self, data, start=0, outcome="NONZERO_EXIT", code=65):
        self.log.write_bytes(data)
        result = release.archive_failure_summary(self.log, start, outcome, code)
        self.assert_safe(result)
        return result

    def assert_safe(self, result):
        self.assertEqual(set(result), {"outcome", "exit_code", "failed_tasks", "hints", "log_scope"})
        self.assertTrue(set(result["failed_tasks"]) <= TASKS)
        self.assertTrue(set(result["hints"]) <= HINTS)
        self.assertIn(result["outcome"], {"NONZERO_EXIT", "TIMEOUT", "START_OR_LOG_IO_ERROR", "SUBPROCESS_ERROR", "UNKNOWN"})
        self.assertIn(result["log_scope"], {"FULL_INVOCATION", "TAIL_ONLY", "UNAVAILABLE"})
        self.assertTrue(result["exit_code"] is None or (type(result["exit_code"]) is int and -255 <= result["exit_code"] <= 255))
        self.assertNotIn(SENTINEL, json.dumps(result))

    def test_failed_command_identifies_task_without_arguments(self):
        result = self.summarize(("Command CodeSign failed with a nonzero exit code\n" + SENTINEL).encode())
        self.assertEqual(result["failed_tasks"], ["CODE_SIGN"])
        self.assertEqual(result["exit_code"], 65)

    def test_failed_build_summary_classifies_only_known_task_tokens(self):
        result = self.summarize((
            "The following build commands failed:\n"
            "\tSwiftCompile normal arm64 /private/" + SENTINEL + "\n"
            "    ExtractAppIntentsMetadata /private/" + SENTINEL + "\n"
            "    UnknownTask /private/" + SENTINEL + "\n"
            "(3 failures)\n"
        ).encode())
        self.assertEqual(result["failed_tasks"], ["APP_INTENTS_METADATA", "SWIFT_COMPILE"])

    def test_successful_command_mentions_are_not_failed_tasks(self):
        result = self.summarize((
            "CodeSign /private/" + SENTINEL + "\n"
            "SwiftCompile normal arm64 /private/source.swift\n"
            "ExtractAppIntentsMetadata /private/app\n"
            "** ARCHIVE SUCCEEDED **\n"
        ).encode())
        self.assertEqual(result["failed_tasks"], [])
        self.assertEqual(result["hints"], ["NO_RECOGNIZED_HINT"])

    def test_summary_section_ends_before_later_commands(self):
        result = self.summarize(b"The following build commands failed:\n    Ld /private/app\n(1 failure)\n    CodeSign /private/app\n")
        self.assertEqual(result["failed_tasks"], ["LINK"])

    def test_failure_task_variants_map_to_fixed_categories(self):
        cases = {
            "SwiftEmitModule": "SWIFT_MODULE", "SwiftDriver": "SWIFT_DRIVER",
            "CompileC": "COMPILE_C", "CompileAssetCatalog": "ASSET_CATALOG",
            "CompileAssetCatalogVariant": "ASSET_CATALOG", "ProcessInfoPlistFile": "INFO_PLIST",
            "PhaseScriptExecution": "BUILD_SCRIPT",
        }
        for token, category in cases.items():
            with self.subTest(token=token):
                result = self.summarize(("Command " + token + " failed with a nonzero exit code\n").encode())
                self.assertEqual(result["failed_tasks"], [category])

    def test_error_hints_do_not_include_profile_or_identity_values(self):
        cases = {
            "error: Target requires a provisioning profile ": "PROFILE_LOOKUP",
            "error: Provisioning profile doesn't include signing certificate ": "PROFILE_COMPATIBILITY",
            "error: No signing certificate found for ": "SIGNING_IDENTITY_LOOKUP",
            "error: Unable to find a destination matching ": "SDK_OR_DESTINATION",
            "error: SDK iphoneos cannot be located ": "SDK_OR_DESTINATION",
            "errSecInternalComponent ": "SECURITY_TOOL_ERROR",
            "User interaction is not allowed ": "KEYCHAIN_INTERACTION",
            "No space left on device ": "DISK_SPACE",
        }
        for message, hint in cases.items():
            with self.subTest(hint=hint):
                result = self.summarize((message + SENTINEL).encode())
                self.assertEqual(result["hints"], [hint])

    def test_normal_profile_mentions_do_not_produce_error_hint(self):
        result = self.summarize(("note: Provisioning profile doesn't match cached candidate " + SENTINEL).encode())
        self.assertEqual(result["hints"], ["NO_RECOGNIZED_HINT"])

    def test_unknown_output_remains_unknown_without_reflection(self):
        result = self.summarize((SENTINEL + "\nunknown Xcode condition\n").encode())
        self.assertEqual(result["failed_tasks"], [])
        self.assertEqual(result["hints"], ["NO_RECOGNIZED_HINT"])
        self.assertEqual(result["log_scope"], "FULL_INVOCATION")

    def test_previous_signing_output_is_excluded(self):
        prior = b"Command CodeSign failed with a nonzero exit code\nerrSecInternalComponent\n"
        result = self.summarize(prior + b"Command SwiftCompile failed with a nonzero exit code\n", start=len(prior))
        self.assertEqual(result["failed_tasks"], ["SWIFT_COMPILE"])
        self.assertEqual(result["hints"], ["NO_RECOGNIZED_HINT"])

    def test_large_invocation_reads_tail_and_reports_truncation(self):
        result = self.summarize(
            b"Command CodeSign failed with a nonzero exit code\n"
            + (b"unrecognized synthetic output\n" * 20000)
            + b"Command SwiftCompile failed with a nonzero exit code\n"
        )
        self.assertEqual(result["log_scope"], "TAIL_ONLY")
        self.assertEqual(result["failed_tasks"], ["SWIFT_COMPILE"])

    def test_tail_does_not_classify_partial_first_line(self):
        # The first visible tail bytes look like an error, but are a continuation
        # of an oversized previous line; a partial line must be ignored.
        tail = b"Command CodeSign failed with a nonzero exit code\n"
        padding = b"x" * (256 * 1024 - len(tail))
        result = self.summarize(b"discarded-prefix" + tail + padding)
        self.assertEqual(result["log_scope"], "TAIL_ONLY")
        self.assertEqual(result["failed_tasks"], [])

    def test_unreadable_log_fails_closed(self):
        result = release.archive_failure_summary(self.log, 0, "NONZERO_EXIT", 65)
        self.assert_safe(result)
        self.assertEqual(result["log_scope"], "UNAVAILABLE")
        self.assertEqual(result["failed_tasks"], [])

    def test_invalid_offsets_do_not_expose_prior_output(self):
        for start in (None, -1, True, 10000, SENTINEL):
            with self.subTest(start=start):
                result = self.summarize(b"errSecInternalComponent\n", start=start)
                self.assertEqual(result["log_scope"], "UNAVAILABLE")
                self.assertEqual(result["hints"], ["NO_RECOGNIZED_HINT"])

    def test_multiline_control_and_non_utf8_data_are_not_reflected(self):
        data = ("::error::" + SENTINEL + "\n\x1b[31m" + SENTINEL + "\r\x00").encode() + b"\xff\xfe\n"
        result = self.summarize(data)
        rendered = json.dumps(result)
        self.assertNotIn("::error::", rendered)
        self.assertNotIn("\\u001b", rendered)
        self.assertNotIn("\\u0000", rendered)

    def test_outcome_and_exit_code_reject_unbounded_or_arbitrary_values(self):
        for code in (SENTINEL, 999999, -999999, True, 65.0):
            with self.subTest(code=code):
                result = self.summarize(b"", outcome=SENTINEL, code=code)
                self.assertEqual(result["outcome"], "UNKNOWN")
                self.assertIsNone(result["exit_code"])

    def test_negative_signal_returncode_is_bounded_numeric_value(self):
        result = self.summarize(b"", code=-15)
        self.assertEqual(result["exit_code"], -15)
        self.assertEqual(result["outcome"], "NONZERO_EXIT")


class PrivateToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.tool = release.PrivateTools(self.work)
        self.output = io.StringIO()
        self.errors = io.StringIO()

    def process_factory(self, data=b"", returncode=65, communications=None):
        process = mock.Mock(pid=12345, returncode=returncode)
        if communications is None:
            process.communicate.return_value = (None, None)
        else:
            process.communicate.side_effect = communications

        def launch(*args, **kwargs):
            kwargs["stderr"].write(data)
            kwargs["stderr"].flush()
            return process

        return process, launch

    def run_failure(self, launch, **kwargs):
        with mock.patch.object(release.subprocess, "Popen", side_effect=launch), redirect_stdout(self.output), redirect_stderr(self.errors):
            with self.assertRaises(release.ReleaseError) as caught:
                self.tool.run(ERROR, ["synthetic-tool", SENTINEL], **kwargs)
        self.assertEqual(str(caught.exception), ERROR)
        self.assertNotIn(SENTINEL, self.output.getvalue() + self.errors.getvalue())
        self.assertEqual(self.errors.getvalue(), "")
        return self.output.getvalue()

    def diagnostic(self, text):
        self.assertEqual(len(text.splitlines()), 1)
        self.assertTrue(text.startswith("Archive diagnostics: "))
        return json.loads(text[len("Archive diagnostics: "):])

    def test_archive_failure_prints_only_summary_and_preserves_error(self):
        _, launch = self.process_factory(("Command CodeSign failed with a nonzero exit code\n" + SENTINEL).encode())
        result = self.diagnostic(self.run_failure(launch, diagnose_archive=True))
        self.assertEqual(result["outcome"], "NONZERO_EXIT")
        self.assertEqual(result["exit_code"], 65)
        self.assertEqual(result["failed_tasks"], ["CODE_SIGN"])

    def test_private_tools_offset_excludes_previous_commands(self):
        (self.work / "private-tool.log").write_bytes(b"errSecInternalComponent\nCommand CodeSign failed with a nonzero exit code\n")
        _, launch = self.process_factory(b"Command SwiftCompile failed with a nonzero exit code\n")
        result = self.diagnostic(self.run_failure(launch, diagnose_archive=True))
        self.assertEqual(result["failed_tasks"], ["SWIFT_COMPILE"])
        self.assertEqual(result["hints"], ["NO_RECOGNIZED_HINT"])

    def test_default_flag_keeps_other_tool_failures_silent(self):
        _, launch = self.process_factory(("errSecInternalComponent\n" + SENTINEL).encode())
        self.assertEqual(self.run_failure(launch), "")

    def test_success_does_not_emit_diagnostics_or_captured_output(self):
        process, launch = self.process_factory(SENTINEL.encode(), returncode=0)
        process.communicate.return_value = (SENTINEL.encode(), None)
        with mock.patch.object(release.subprocess, "Popen", side_effect=launch), redirect_stdout(self.output), redirect_stderr(self.errors):
            result = self.tool.run(ERROR, ["synthetic-tool"], capture=True, diagnose_archive=True)
        self.assertEqual(result, SENTINEL.encode())
        self.assertEqual(self.output.getvalue() + self.errors.getvalue(), "")

    def test_negative_signal_failure_is_identified_without_tool_output(self):
        _, launch = self.process_factory(SENTINEL.encode(), returncode=-15)
        result = self.diagnostic(self.run_failure(launch, diagnose_archive=True))
        self.assertEqual(result["exit_code"], -15)
        self.assertEqual(result["outcome"], "NONZERO_EXIT")

    def test_start_error_does_not_print_exception_arguments(self):
        result = self.diagnostic(self.run_failure(OSError(SENTINEL), diagnose_archive=True))
        self.assertEqual(result["outcome"], "START_OR_LOG_IO_ERROR")
        self.assertIsNone(result["exit_code"])

    def test_timeout_terminates_group_and_keeps_original_failure(self):
        process, launch = self.process_factory(SENTINEL.encode(), communications=[
            subprocess.TimeoutExpired(["synthetic-tool", SENTINEL], 2, output=SENTINEL),
            (None, None),
        ])
        with mock.patch.object(release.os, "killpg", create=True) as terminate:
            result = self.diagnostic(self.run_failure(launch, diagnose_archive=True, timeout=2))
        self.assertEqual(result["outcome"], "TIMEOUT")
        self.assertIsNone(result["exit_code"])
        terminate.assert_called_once_with(process.pid, release.signal.SIGTERM)

    def test_generic_subprocess_error_is_not_reflected(self):
        result = self.diagnostic(self.run_failure(subprocess.SubprocessError(SENTINEL), diagnose_archive=True))
        self.assertEqual(result["outcome"], "SUBPROCESS_ERROR")

    def test_diagnostic_failure_cannot_replace_archive_failure(self):
        _, launch = self.process_factory(SENTINEL.encode())
        with mock.patch.object(release, "archive_failure_summary", side_effect=ValueError(SENTINEL)):
            self.assertEqual(self.run_failure(launch, diagnose_archive=True), "")

    def test_malicious_multiline_log_cannot_inject_actions_commands(self):
        _, launch = self.process_factory((
            "::error::" + SENTINEL + "\n::add-mask::" + SENTINEL + "\n"
            "\x1b[31m" + SENTINEL + "\x00\r\n"
            "Command CodeSign failed with a nonzero exit code\n"
        ).encode())
        text = self.run_failure(launch, diagnose_archive=True)
        result = self.diagnostic(text)
        self.assertEqual(result["failed_tasks"], ["CODE_SIGN"])
        self.assertNotIn("::error::", text)
        self.assertNotIn("::add-mask::", text)
        self.assertNotIn("\x1b", text)


if __name__ == "__main__":
    unittest.main()
