"""Synthetic two-query regressions; no credentials, Apple tools, or network."""

import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import testflight_connect as connect
import testflight_release as release


BUNDLE = "org.synthetic.fixture"
MARKETING = "1.0"


def resource(kind, identifier, **attributes):
    return {"type": kind, "id": identifier, "attributes": attributes}


def page(*items, next_url=None):
    return {"data": list(items), "links": {"next": next_url}}


def upload(version, state="PROCESSING", **overrides):
    attributes = {"cfBundleVersion": version, "cfBundleShortVersionString": MARKETING,
                  "platform": "IOS", "state": {"state": state}}
    attributes.update(overrides)
    return resource("buildUploads", "synthetic-upload", **attributes)


def snapshot(uploads=(), builds=None):
    pages = [page(resource("apps", "synthetic-app", bundleId=BUNDLE))]
    if builds is None:
        pages.append(page())
    else:
        pages.extend([page(resource("preReleaseVersions", "synthetic-release",
                                    version=MARKETING, platform="IOS")), page(*builds)])
    return pages + [page(*uploads)]


class BuildAvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.api = connect.ConnectClient("SYNTHETIC", "00000000-0000-0000-0000-000000000001",
                                         "unused-synthetic-path")
        self.api._token = Mock(side_effect=AssertionError("Authentication must not run"))
        self.api._opener = Mock()
        self.api._opener.open.side_effect = AssertionError("Network must not run")
        self.output = io.StringIO()
        self.addCleanup(self.assert_silent)
        self.enterContext(contextlib.redirect_stdout(self.output))
        self.enterContext(contextlib.redirect_stderr(self.output))

    def assert_silent(self):
        self.assertEqual(self.output.getvalue(), "")
        self.api._token.assert_not_called()
        self.api._opener.open.assert_not_called()

    def choose(self, run=42, attempt=1):
        return connect.choose_build_number(run, attempt,
                                           self.api.existing_build_versions(BUNDLE, MARKETING))

    def recheck(self, version):
        self.api.assert_build_still_available(BUNDLE, MARKETING, version)

    def test_unchanged_snapshot_never_rejects_selected_candidate(self):
        cases = [([], 42, 1), (["42.1", "0042.01.0"], 42, 1),
                 (["50.2.8", "9.99.99"], 3, 2), (["42.8.99"], 1, 1),
                 (["42.99.99"], 1, 1)]
        for versions, run, attempt in cases:
            with self.subTest(versions=versions):
                pages = snapshot([upload(v) for v in versions])
                with patch.object(self.api, "_get", side_effect=pages + pages):
                    self.recheck(self.choose(run, attempt))

    def test_failed_upload_alone_does_not_raise_initial_candidate(self):
        with patch.object(self.api, "_get", side_effect=snapshot([upload("90.1", "FAILED")])):
            self.assertEqual(self.choose(), "42.1.0")

    def test_newly_visible_failed_upload_cannot_reject_selected_candidate(self):
        for version in ["42.1", "0042.01.0", "90.1.0"]:
            with self.subTest(version=version), patch.object(self.api, "_get", side_effect=
                    snapshot() + snapshot([upload(version, "FAILED")])):
                self.recheck(self.choose())

    def test_new_active_or_complete_upload_still_blocks_equal_or_newer(self):
        for state in ["AWAITING_UPLOAD", "PROCESSING", "COMPLETE"]:
            for version in ["42.1", "0042.01.0", "43.1"]:
                with self.subTest(state=state, version=version), patch.object(self.api, "_get",
                        side_effect=snapshot() + snapshot([upload(version, state)])):
                    selected = self.choose()
                    with self.assertRaisesRegex(connect.ConnectError,
                                                "^BUILD_NUMBER_NO_LONGER_AVAILABLE$"):
                        self.recheck(selected)

    def test_lower_active_upload_does_not_block(self):
        with patch.object(self.api, "_get", side_effect=snapshot() + snapshot([upload("41.99.99")])):
            self.recheck(self.choose())

    def test_failed_record_never_hides_existing_build(self):
        for state in ["PROCESSING", "VALID", "FAILED", "INVALID"]:
            build = resource("builds", "synthetic-build", version="42.1", processingState=state)
            with self.subTest(state=state), patch.object(self.api, "_get", side_effect=
                    snapshot([upload("42.1", "FAILED")], builds=[build])):
                with self.assertRaisesRegex(connect.ConnectError, "^BUILD_NUMBER_NO_LONGER_AVAILABLE$"):
                    self.recheck("42.1.0")

    def test_failed_record_never_hides_another_active_upload(self):
        records = [upload("42.1", "FAILED"), upload("42.1", "PROCESSING")]
        with patch.object(self.api, "_get", side_effect=snapshot(records)):
            with self.assertRaisesRegex(connect.ConnectError, "^BUILD_NUMBER_NO_LONGER_AVAILABLE$"):
                self.recheck("42.1.0")

    def test_only_explicit_nested_failed_state_is_excluded(self):
        for state in [None, "FAILED", {}, [], True, {"state": "UNKNOWN"},
                      {"state": "failed"}, {"state": None}, {"state": ["FAILED"]}]:
            record = upload("42.1")
            if state is None:
                record["attributes"].pop("state")
            else:
                record["attributes"]["state"] = state
            with self.subTest(state=state), patch.object(self.api, "_get", side_effect=
                    snapshot([record])):
                with self.assertRaisesRegex(connect.ConnectError, "^BUILD_NUMBER_NO_LONGER_AVAILABLE$"):
                    self.recheck("42.1.0")

    def test_failed_upload_still_requires_valid_version(self):
        with patch.object(self.api, "_get", side_effect=snapshot([upload("synthetic-invalid", "FAILED")])):
            with self.assertRaisesRegex(connect.ConnectError, "^BUILD_NUMBER_INVALID$"):
                self.choose()

    def test_failed_upload_still_requires_matching_scope(self):
        for overrides in [{"platform": "MAC_OS"}, {"cfBundleShortVersionString": "2.0"}]:
            with self.subTest(overrides=overrides), patch.object(self.api, "_get", side_effect=
                    snapshot([upload("42.1", "FAILED", **overrides)])):
                with self.assertRaisesRegex(connect.ConnectError, "^ASC_UPLOAD_MISMATCH$"):
                    self.recheck("42.1.0")

    def test_pagination_after_failed_upload_still_finds_active_conflict(self):
        pages = snapshot([upload("90.1", "FAILED")])
        pages[-1]["links"]["next"] = connect.API_ROOT + "/v1/apps/synthetic-app/buildUploads?cursor=two"
        pages.append(page(upload("42.1")))
        with patch.object(self.api, "_get", side_effect=pages):
            with self.assertRaisesRegex(connect.ConnectError, "^BUILD_NUMBER_NO_LONGER_AVAILABLE$"):
                self.recheck("42.1.0")

    def test_recheck_endpoint_failure_never_becomes_available(self):
        pages = snapshot() + snapshot()[:-1] + [connect.ConnectError("ASC_REQUEST_FAILED")]
        with patch.object(self.api, "_get", side_effect=pages):
            selected = self.choose()
            with self.assertRaisesRegex(connect.ConnectError, "^ASC_REQUEST_FAILED$"):
                self.recheck(selected)

    def test_conflict_still_runs_cleanup_and_only_reports_fixed_error(self):
        output = io.StringIO()
        with patch.dict(release.os.environ, {}, clear=True), \
                patch.object(release, "checked_work_dir", return_value=Path("synthetic-work")), \
                patch.object(release, "release", side_effect=connect.ConnectError(
                    "BUILD_NUMBER_NO_LONGER_AVAILABLE")), \
                patch.object(release, "cleanup") as cleanup, \
                patch.object(release.signal, "signal"), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(release.main(["--release"]), 1)
        cleanup.assert_called_once_with(Path("synthetic-work"))
        self.assertEqual(output.getvalue(),
                         "Release stopped: BUILD_NUMBER_NO_LONGER_AVAILABLE\n"
                         "Private signing files removed; keychain search list restored.\n")


if __name__ == "__main__":
    unittest.main()
