"""Synthetic API and release-flow tests; no real credentials or Apple tools."""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import testflight_connect as connect
import testflight_release as release


BUNDLE = "org.synthetic.fixture"
MARKETING = "1.0"
MARKER = "synthetic-private-marker-never-real"


def resource(kind, **attributes):
    attributes["untrustedDetail"] = MARKER
    return {"type": kind, "id": "synthetic-resource-id", "attributes": attributes}


def build(version="5.1", state="VALID"):
    return resource("builds", version=version, processingState=state)


def upload(version="5.1", state="PROCESSING"):
    return resource("buildUploads", cfBundleVersion=version,
                    cfBundleShortVersionString=MARKETING, platform="IOS",
                    state={"state": state, "errors": [MARKER], "warnings": [MARKER]})


def page(*records, next_url=None):
    return {"data": list(records), "links": {"next": next_url}}


def snapshot(builds=(), uploads=()):
    return [page(resource("apps", bundleId=BUNDLE)),
            page(resource("preReleaseVersions", version=MARKETING, platform="IOS")),
            page(*builds), page(*uploads)]


def client():
    api = connect.ConnectClient("SYNTHETIC", "00000000-0000-0000-0000-000000000001",
                                "unused-synthetic-path")
    api._token = Mock(side_effect=AssertionError("Authentication must not run"))
    api._opener = Mock()
    api._opener.open.side_effect = AssertionError("Network must not run")
    return api


class ConflictDiagnosticTests(unittest.TestCase):
    def check(self, pages, expected=None, error="BUILD_NUMBER_NO_LONGER_AVAILABLE"):
        api = client()
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(api, "_get", side_effect=pages), \
                patch.object(release, "report_build_conflict", wraps=release.report_build_conflict) as report, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            if expected is None:
                api.assert_build_still_available(BUNDLE, MARKETING, "5.1.0", report_conflict=report)
            else:
                with self.assertRaisesRegex(connect.ConnectError, "^" + error + "$"):
                    api.assert_build_still_available(BUNDLE, MARKETING, "5.1.0", report_conflict=report)
        api._token.assert_not_called()
        api._opener.open.assert_not_called()
        self.assertEqual(errors.getvalue(), "")
        if expected:
            report.assert_called_once()
            self.assertEqual(output.getvalue(), "BUILD_AVAILABILITY_DIAGNOSTIC " + json.dumps({
                "phase": "POST_APPLE_VALIDATION", "outcome": "CONFLICT",
                "categories": sorted(expected),
            }, separators=(",", ":")) + "\n")
        else:
            report.assert_not_called()
            self.assertEqual(output.getvalue(), "")

    def test_existing_build_states_have_fixed_categories(self):
        for state in ["VALID", "PROCESSING", "FAILED", "INVALID"]:
            with self.subTest(state=state):
                self.check(snapshot(builds=[build(state=state)]), {"BUILD_RESOURCE_" + state + "_EQUAL"})

    def test_build_unknown_states_cannot_leak(self):
        for state in [MARKER, None, {}, [MARKER], 7]:
            with self.subTest(kind=type(state).__name__):
                self.check(snapshot(builds=[build(state=state)]), {"BUILD_RESOURCE_UNKNOWN_STATE_EQUAL"})

    def test_active_and_completed_upload_states_have_fixed_categories(self):
        for state in ["AWAITING_UPLOAD", "PROCESSING", "COMPLETE"]:
            with self.subTest(state=state):
                self.check(snapshot(uploads=[upload(state=state)]), {"UPLOAD_" + state + "_EQUAL"})

    def test_unknown_missing_and_malformed_upload_state_cannot_leak(self):
        for state in [None, MARKER, "FAILED", {}, {"state": MARKER}, {"state": [MARKER]}, [MARKER]]:
            record = upload()
            if state is None:
                record["attributes"].pop("state")
            else:
                record["attributes"]["state"] = state
            with self.subTest(kind=type(state).__name__):
                self.check(snapshot(uploads=[record]), {"UPLOAD_UNKNOWN_STATE_EQUAL"})

    def test_equal_normalization_and_higher_relation_do_not_print_numbers(self):
        self.check(snapshot(builds=[build("0005.01.00")], uploads=[upload("6.1")]),
                   {"BUILD_RESOURCE_VALID_EQUAL", "UPLOAD_PROCESSING_HIGHER"})

    def test_mixed_sources_are_deduplicated_and_lower_versions_excluded(self):
        self.check(snapshot(builds=[build(), build()], uploads=[upload("4.99"), upload("6.1"),
                   upload(state="COMPLETE"), upload("9.1", state="FAILED")]),
                   {"BUILD_RESOURCE_VALID_EQUAL", "UPLOAD_PROCESSING_HIGHER", "UPLOAD_COMPLETE_EQUAL"})

    def test_failed_upload_and_available_candidate_stay_silent(self):
        self.check(snapshot(uploads=[upload("9.1", "FAILED"), upload("4.99")]))
        self.check(snapshot())

    def test_pagination_reports_all_blocking_sources_without_urls(self):
        pages = snapshot(uploads=[upload()])
        pages[-1]["links"]["next"] = connect.API_ROOT + "/v1/apps/synthetic-resource-id/buildUploads?cursor=two"
        pages.append(page(upload("6.1", "COMPLETE")))
        self.check(pages, {"UPLOAD_PROCESSING_EQUAL", "UPLOAD_COMPLETE_HIGHER"})

    def test_failed_api_query_or_invalid_version_never_reports_partial_evidence(self):
        self.check(snapshot(builds=[build()])[:-1] + [connect.ConnectError("ASC_REQUEST_FAILED")],
                   set(), error="ASC_REQUEST_FAILED")
        self.check(snapshot(builds=[build(MARKER)]), set(), error="BUILD_NUMBER_INVALID")
        self.check(snapshot(uploads=[upload(MARKER, "FAILED")]), set(), error="BUILD_NUMBER_INVALID")

    def test_reporter_revalidates_allowlist_and_has_fixed_fallback(self):
        for values, expected in [
            (["UPLOAD_PROCESSING_EQUAL", MARKER, {}, None, [MARKER]], ["UPLOAD_PROCESSING_EQUAL"]),
            ([MARKER, "UPLOAD_PROCESSING_EQUAL\n" + MARKER], ["UNCLASSIFIED_CONFLICT"]),
        ]:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                release.report_build_conflict(values)
            self.assertEqual(output.getvalue(), "BUILD_AVAILABILITY_DIAGNOSTIC " + json.dumps({
                "phase": "POST_APPLE_VALIDATION", "outcome": "CONFLICT", "categories": expected,
            }, separators=(",", ":")) + "\n")

    def test_reporting_is_optional_and_does_not_change_conflict(self):
        api = client()
        output = io.StringIO()
        with patch.object(api, "_get", side_effect=snapshot(uploads=[upload()])), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaisesRegex(connect.ConnectError, "^BUILD_NUMBER_NO_LONGER_AVAILABLE$"):
                api.assert_build_still_available(BUNDLE, MARKETING, "5.1.0")
        self.assertEqual(output.getvalue(), "")


class ReleaseDiagnosticWiringTests(unittest.TestCase):
    def run_release(self, conflict=False, validation_failure=False):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / "synthetic-work"
            work.mkdir()
            release.write_state(work, {"version": 1, "keychains": None, "profile": None})
            tool = Mock(work=work, env={})
            tool.run.return_value = b""
            api = client()
            pages = snapshot() + snapshot(uploads=[upload()] if conflict else [])
            events = []
            real_check = api.assert_build_still_available

            def check(*args, **kwargs):
                events.append("CHECK")
                return real_check(*args, **kwargs)

            def apple(_tool, code, _args, **_kwargs):
                if code == "APPLE_IPA_VALIDATION_FAILED":
                    events.append("VALIDATE")
                    if validation_failure:
                        raise release.ReleaseError(code)
                else:
                    events.append("UPLOAD")

            env = {name: MARKER for name in release.SECRET_NAMES}
            env.update({"APP_STORE_CONNECT_KEY_ID": "SYNTHETIC", "GITHUB_RUN_NUMBER": "5",
                        "GITHUB_RUN_ATTEMPT": "1", "TESTFLIGHT_WORK_DIR": str(work),
                        "APP_STORE_CONNECT_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nNOT A KEY"})
            settings = {"PRODUCT_BUNDLE_IDENTIFIER": BUNDLE, "MARKETING_VERSION": MARKETING}
            identity = SimpleNamespace(team_id="SYNTHETICTEAM", uuid="synthetic-profile")
            output = io.StringIO()
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.dict(release.os.environ, env, clear=True))
                stack.enter_context(patch.object(release.sys, "platform", "darwin"))
                stack.enter_context(patch.object(release.signal, "signal"))
                stack.enter_context(patch.object(release, "checked_work_dir", return_value=work))
                stack.enter_context(patch.object(release, "PrivateTools", return_value=tool))
                stack.enter_context(patch.object(release, "build_settings", return_value=settings))
                stack.enter_context(patch.object(release, "decode_secret_file"))
                stack.enter_context(patch.object(release, "import_identity", return_value=(
                    work / "synthetic-keychain", MARKER, b"not a certificate", identity.team_id)))
                stack.enter_context(patch.object(release, "read_profile", return_value={}))
                stack.enter_context(patch.object(release, "validate_profile", return_value=identity))
                stack.enter_context(patch.object(release, "install_profile"))
                stack.enter_context(patch.object(release, "private_write"))
                stack.enter_context(patch.object(release, "export_options", return_value={}))
                verified = stack.enter_context(patch.object(release, "verify_signed_app"))
                stack.enter_context(patch.object(release, "extract_ipa", return_value=work / "fake-app"))
                stack.enter_context(patch.object(Path, "glob", return_value=[work / "not-created.ipa"]))
                stack.enter_context(patch.object(release, "ConnectClient", return_value=api))
                get = stack.enter_context(patch.object(api, "_get", side_effect=pages))
                stack.enter_context(patch.object(api, "assert_build_still_available", side_effect=check))
                stack.enter_context(patch.object(release, "apple_command", side_effect=apple))
                cleaned = stack.enter_context(patch.object(release, "cleanup", wraps=release.cleanup))
                external = stack.enter_context(patch.object(release.subprocess, "run",
                                                side_effect=AssertionError("External tools forbidden")))
                stack.enter_context(contextlib.redirect_stdout(output))
                stack.enter_context(contextlib.redirect_stderr(output))
                status = release.main(["--release"])
                self.assertTrue(all(name not in release.os.environ for name in release.SECRET_NAMES))
            self.assertEqual(verified.call_count, 2)
            cleaned.assert_called_once_with(work)
            self.assertFalse(work.exists())
            external.assert_not_called()
            api._token.assert_not_called()
            api._opener.open.assert_not_called()
            for private in (MARKER, BUNDLE, str(work), identity.team_id, identity.uuid,
                            "synthetic-resource-id", "PRIVATE KEY", "--validate-app", "https://"):
                self.assertNotIn(private, output.getvalue())
            return status, events, output.getvalue(), get.call_count

    def test_actual_post_validation_check_reports_and_stops_upload_then_cleans(self):
        status, events, output, calls = self.run_release(conflict=True)
        self.assertEqual((status, events, calls), (1, ["VALIDATE", "CHECK"], 8))
        diagnostic = [line for line in output.splitlines() if line.startswith("BUILD_AVAILABILITY_DIAGNOSTIC ")]
        self.assertEqual(diagnostic, ['BUILD_AVAILABILITY_DIAGNOSTIC {"phase":"POST_APPLE_VALIDATION",'
                                    '"outcome":"CONFLICT","categories":["UPLOAD_PROCESSING_EQUAL"]}'])
        self.assertIn("Release stopped: BUILD_NUMBER_NO_LONGER_AVAILABLE", output)

    def test_available_build_keeps_validation_check_upload_order(self):
        status, events, output, calls = self.run_release()
        self.assertEqual((status, events, calls), (0, ["VALIDATE", "CHECK", "UPLOAD"], 8))
        self.assertNotIn("BUILD_AVAILABILITY_DIAGNOSTIC", output)

    def test_apple_validation_failure_never_runs_second_check_or_upload(self):
        status, events, output, calls = self.run_release(validation_failure=True)
        self.assertEqual((status, events, calls), (1, ["VALIDATE"], 4))
        self.assertNotIn("BUILD_AVAILABILITY_DIAGNOSTIC", output)
        self.assertIn("Release stopped: APPLE_IPA_VALIDATION_FAILED", output)


if __name__ == "__main__":
    unittest.main()
