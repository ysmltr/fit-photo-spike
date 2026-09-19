"""Synthetic ASC/JWT/build-number tests. No credentials or network calls."""

import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.parse


SCRIPT = Path(__file__).resolve().parents[1] / "testflight_connect.py"
spec = importlib.util.spec_from_file_location("testflight_connect", SCRIPT)
connect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(connect)


def der(r, s):
    def integer(value):
        data = value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")
        if data[0] & 0x80:
            data = b"\0" + data
        return b"\x02" + bytes([len(data)]) + data
    sequence = integer(r) + integer(s)
    return b"\x30" + bytes([len(sequence)]) + sequence


def resource(kind, identifier, **attributes):
    return {"type": kind, "id": identifier, "attributes": attributes}


def page(*resources, next_url=None):
    return {"data": list(resources), "links": {"next": next_url}}


def client():
    return connect.ConnectClient("DUMMYKEY", "00000000-0000-0000-0000-000000000001", Path("unused-key.p8"))


APP = resource("apps", "123", bundleId="com.example.FitPhotoSpike")
RELEASE = resource("preReleaseVersions", "abc-123", version="1.0", platform="IOS")


class BuildNumberTests(unittest.TestCase):
    def test_parse_all_supported_component_counts(self):
        for value, expected in [("1", (1, 0, 0)), ("42.7", (42, 7, 0)), ("9999.99.99", (9999, 99, 99))]:
            self.assertEqual(connect.parse_build_number(value), expected)

    def test_leading_zeros_compare_numerically(self):
        self.assertEqual(connect.parse_build_number("0001.002.03"), (1, 2, 3))

    def test_reject_invalid_build_numbers(self):
        for value in [None, True, 1, "", "1.2.3.4", "1a1", "1.2b1", " 1", "1\n", "-1", "1.-2", "１.２", "1..2"]:
            with self.subTest(value=value), self.assertRaises(connect.ConnectError):
                connect.parse_build_number(value)

    def test_reject_out_of_range_builds(self):
        for value in ["0", "10000", "1.100", "1.1.100", "0" * 65 + "1"]:
            with self.subTest(value=value), self.assertRaises(connect.ConnectError):
                connect.parse_build_number(value)

    def test_first_candidate_uses_run_and_attempt(self):
        self.assertEqual(connect.choose_build_number("42", "2", []), "42.2.0")

    def test_higher_ci_candidate_beats_previous_builds(self):
        self.assertEqual(connect.choose_build_number(42, 1, ["9.99.99", "41.9"]), "42.1.0")

    def test_existing_candidate_moves_forward(self):
        self.assertEqual(connect.choose_build_number(42, 1, ["42.1"]), "42.1.1")

    def test_old_run_rerun_moves_past_newest_existing(self):
        self.assertEqual(connect.choose_build_number(3, 2, ["42.8", "50.2.8"]), "50.2.9")

    def test_numeric_not_lexical_order(self):
        self.assertEqual(connect.choose_build_number(1, 1, ["9.99.99", "10.1.5"]), "10.1.6")

    def test_patch_carry(self):
        self.assertEqual(connect.choose_build_number(1, 1, ["42.8.99"]), "42.9.0")

    def test_minor_carry(self):
        self.assertEqual(connect.choose_build_number(1, 1, ["42.99.99"]), "43.0.0")

    def test_exhaustion_stops(self):
        with self.assertRaisesRegex(connect.ConnectError, "BUILD_NUMBER_EXHAUSTED"):
            connect.choose_build_number(9999, 99, ["9999.99.99"])

    def test_malformed_existing_never_ignored(self):
        with self.assertRaises(connect.ConnectError):
            connect.choose_build_number(42, 1, ["1.2", "invalid"])

    def test_ci_counter_limits(self):
        for run, attempt in [(0, 1), (10000, 1), (1, 100), (1, 0), (True, 1), ("1.1", 1), (1, "2\n")]:
            with self.subTest(run=run, attempt=attempt), self.assertRaises(connect.ConnectError):
                connect.choose_build_number(run, attempt, [])


class SignatureTests(unittest.TestCase):
    def test_small_integers_are_left_padded(self):
        self.assertEqual(connect.der_signature_to_raw(der(1, 2)), (1).to_bytes(32, "big") + (2).to_bytes(32, "big"))

    def test_signed_der_padding_removed(self):
        r, s = 1 << 255, (1 << 255) + 3
        self.assertEqual(connect.der_signature_to_raw(der(r, s)), r.to_bytes(32, "big") + s.to_bytes(32, "big"))

    def test_signature_rejects_out_of_curve_range(self):
        for value in [0, connect.P256_ORDER, 1 << 256]:
            with self.subTest(value=value), self.assertRaises(connect.ConnectError):
                connect.der_signature_to_raw(der(value, 1))

    def test_signature_rejects_noncanonical_and_malformed_der(self):
        values = [
            b"", b"not a signature", der(1, 2) + b"\0",
            b"\x30\x06\x02\x01\x80\x02\x01\x01",  # negative
            b"\x30\x07\x02\x02\x00\x01\x02\x01\x01",  # redundant zero
            b"\x30\x06\x02\x00\x02\x02\x01\x01",  # empty integer
            b"\x30\x81\x06\x02\x01\x01\x02\x01\x01",  # long length
            b"\x30\x06\x03\x01\x01\x02\x01\x01",  # wrong tag
        ]
        for value in values:
            with self.subTest(value=value), self.assertRaisesRegex(connect.ConnectError, "JWT_SIGNATURE_INVALID"):
                connect.der_signature_to_raw(value)

    def test_jwt_claims_ten_minute_expiry_and_raw_signature(self):
        signed = Mock(returncode=0, stdout=der(1, 2), stderr=b"DO NOT PRINT")
        with patch.object(connect.time, "time", return_value=1000), patch.object(connect.subprocess, "run", return_value=signed) as run:
            token = client()._token()
        header, claims, signature = token.split(".")
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        self.assertEqual(json.loads(decode(header)), {"alg": "ES256", "kid": "DUMMYKEY", "typ": "JWT"})
        decoded = json.loads(decode(claims))
        self.assertEqual((decoded["iat"], decoded["exp"], decoded["aud"]), (1000, 1600, "appstoreconnect-v1"))
        self.assertEqual(len(decode(signature)), 64)
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.PIPE)
        self.assertEqual(run.call_args.kwargs["input"], (header + "." + claims).encode("ascii"))

    def test_signing_failures_have_fixed_errors(self):
        with patch.object(connect.subprocess, "run", side_effect=OSError("PRIVATE VALUE")):
            with self.assertRaisesRegex(connect.ConnectError, "^JWT_SIGNING_FAILED$"):
                client()._token()
        with patch.object(connect.subprocess, "run", return_value=Mock(returncode=1, stderr=b"PRIVATE VALUE")):
            with self.assertRaisesRegex(connect.ConnectError, "^JWT_SIGNING_FAILED$"):
                client()._token()


class APITests(unittest.TestCase):
    def test_invalid_account_identifiers_rejected_without_echo(self):
        for key, issuer in [("x\nPRIVATE", "bad"), ("OK", "PRIVATE")]:
            with self.assertRaises(connect.ConnectError) as caught:
                connect.ConnectClient(key, issuer, "unused")
            self.assertNotIn("PRIVATE", str(caught.exception))

    def test_pagination_url_restrictions(self):
        for url in [
            "http://api.appstoreconnect.apple.com/v1/apps",
            "https://evil.example/v1/apps",
            "https://api.appstoreconnect.apple.com.evil.example/v1/apps",
            "https://user@api.appstoreconnect.apple.com/v1/apps",
            "https://api.appstoreconnect.apple.com:443/v1/apps",
            "https://api.appstoreconnect.apple.com/v1/apps#secret",
            "https://api.appstoreconnect.apple.com/not-api",
            "https://api.appstoreconnect.apple.com/v1/apps\n",
            None,
        ]:
            with self.subTest(url=url), self.assertRaises(connect.ConnectError):
                connect._checked_url(url)

    def test_redirects_never_forward_authorization(self):
        with self.assertRaisesRegex(connect.ConnectError, "ASC_REDIRECT_REJECTED"):
            connect._RejectRedirects().redirect_request(None, None, 302, "", {}, "https://other.example")

    def test_pagination_all_pages_and_final_next_omission(self):
        api = client()
        following = connect.API_ROOT + "/v1/apps?cursor=two"
        with patch.object(api, "_get", side_effect=[page(APP, next_url=following), {"data": [APP], "links": {}}]) as get:
            self.assertEqual(len(api._collection("/v1/apps", {"limit": 200}, "apps")), 2)
        self.assertEqual(get.call_args_list[1].args[0], following)

    def test_pagination_cycle_rejected(self):
        api = client()
        url = connect.API_ROOT + "/v1/apps?limit=200"
        with patch.object(api, "_get", return_value=page(APP, next_url=url)):
            with self.assertRaisesRegex(connect.ConnectError, "ASC_PAGINATION_INVALID"):
                api._collection("/v1/apps", {"limit": 200}, "apps")

    def test_collection_malformed_response_fails(self):
        for value in [{}, {"data": {}, "links": {}}, {"data": [], "links": None}, {"data": [APP], "links": {"next": 1}}, page(resource("wrong", "1"))]:
            api = client()
            with self.subTest(value=value), patch.object(api, "_get", return_value=value), self.assertRaises(connect.ConnectError):
                api._collection("/v1/apps", {}, "apps")

    def test_existing_versions_include_processed_and_inflight(self):
        api = client()
        responses = [
            page(APP), page(RELEASE),
            page(resource("builds", "b1", version="9.1", processingState="FAILED")),
            page(resource("buildUploads", "u1", cfBundleVersion="11.1", cfBundleShortVersionString="1.0", platform="IOS", state="PROCESSING")),
        ]
        with patch.object(api, "_get", side_effect=responses) as get:
            self.assertEqual(api.existing_build_versions("com.example.FitPhotoSpike", "1.0"), ["9.1", "11.1"])
        urls = [call.args[0] for call in get.call_args_list]
        self.assertIn("filter%5Bplatform%5D=IOS", urls[1])
        self.assertIn("filter%5BpreReleaseVersion%5D=abc-123", urls[2])
        self.assertIn("/v1/apps/123/buildUploads?", urls[3])
        self.assertNotIn("filter%5BprocessingState%5D", "".join(urls))

    def test_no_previous_release_still_checks_pending_uploads(self):
        api = client()
        with patch.object(api, "_get", side_effect=[page(APP), page(), page()]) as get:
            self.assertEqual(api.existing_build_versions("com.example.FitPhotoSpike", "1.0"), [])
        self.assertIn("buildUploads", get.call_args.args[0])

    def test_unknown_or_nonunique_app_stops(self):
        for apps in [page(), page(APP, APP), page(resource("apps", "1", bundleId="wrong"))]:
            api = client()
            with self.subTest(apps=apps), patch.object(api, "_get", return_value=apps), self.assertRaisesRegex(connect.ConnectError, "ASC_APP_NOT_UNIQUE"):
                api.existing_build_versions("com.example.FitPhotoSpike", "1.0")

    def test_wrong_release_platform_or_marketing_stops(self):
        for release in [resource("preReleaseVersions", "r", version="2.0", platform="IOS"), resource("preReleaseVersions", "r", version="1.0", platform="MAC_OS")]:
            api = client()
            with patch.object(api, "_get", side_effect=[page(APP), page(release)]), self.assertRaisesRegex(connect.ConnectError, "ASC_RELEASE_MISMATCH"):
                api.existing_build_versions("com.example.FitPhotoSpike", "1.0")

    def test_unparseable_asc_version_stops(self):
        api = client()
        upload = resource("buildUploads", "1", cfBundleVersion="bad", cfBundleShortVersionString="1.0", platform="IOS")
        with patch.object(api, "_get", side_effect=[page(APP), page(), page(upload)]), self.assertRaises(connect.ConnectError):
            api.existing_build_versions("com.example.FitPhotoSpike", "1.0")

    def test_inflight_endpoint_failure_never_falls_back(self):
        api = client()
        with patch.object(api, "_get", side_effect=[page(APP), page(), connect.ConnectError("ASC_REQUEST_FAILED")]), self.assertRaises(connect.ConnectError):
            api.existing_build_versions("com.example.FitPhotoSpike", "1.0")

    def test_recheck_rejects_collision_or_newer_build(self):
        api = client()
        for highest in [(42, 1, 0), (43, 1, 0)]:
            with patch.object(api, "highest_build", return_value=highest), self.assertRaisesRegex(connect.ConnectError, "BUILD_NUMBER_NO_LONGER_AVAILABLE"):
                api.assert_build_still_available("com.example.FitPhotoSpike", "1.0", "42.1.0")

    def test_recheck_accepts_still_available_candidate(self):
        api = client()
        for highest in [None, (41, 99, 99)]:
            with patch.object(api, "highest_build", return_value=highest):
                api.assert_build_still_available("com.example.FitPhotoSpike", "1.0", "42.1.0")

    def test_network_error_message_redacted(self):
        api = client()
        api._opener = Mock()
        api._opener.open.side_effect = urllib.error.URLError("PRIVATE RESPONSE")
        with patch.object(api, "_token", return_value="PRIVATE TOKEN"), self.assertRaisesRegex(connect.ConnectError, "^ASC_REQUEST_FAILED$"):
            api._get(connect.API_ROOT + "/v1/apps")

    def test_http_get_auth_header_and_invalid_json(self):
        api = client()
        url = connect.API_ROOT + "/v1/apps"
        response = Mock(status=200)
        response.geturl.return_value = url
        response.read.return_value = b"PRIVATE NOT JSON"
        api._opener = Mock()
        api._opener.open.return_value.__enter__ = Mock(return_value=response)
        api._opener.open.return_value.__exit__ = Mock(return_value=False)
        with patch.object(api, "_token", return_value="PRIVATE TOKEN"), self.assertRaisesRegex(connect.ConnectError, "^ASC_RESPONSE_INVALID$"):
            api._get(url)
        request = api._opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.get_header("Authorization"), "Bearer PRIVATE TOKEN")

    def test_http_oversize_response_stops(self):
        api = client()
        url = connect.API_ROOT + "/v1/apps"
        response = Mock(status=200)
        response.geturl.return_value = url
        response.read.return_value = b"x" * (connect.MAX_RESPONSE_BYTES + 1)
        api._opener = Mock()
        api._opener.open.return_value.__enter__ = Mock(return_value=response)
        api._opener.open.return_value.__exit__ = Mock(return_value=False)
        with patch.object(api, "_token", return_value="token"), self.assertRaisesRegex(connect.ConnectError, "^ASC_RESPONSE_TOO_LARGE$"):
            api._get(url)


if __name__ == "__main__":
    unittest.main()
