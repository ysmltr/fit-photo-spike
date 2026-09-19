"""Pure-stdlib synthetic release-signing policy tests; no real certificates."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import plistlib
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "testflight_signing.py"
SPEC = importlib.util.spec_from_file_location("testflight_signing", MODULE_PATH)
signing = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = signing
SPEC.loader.exec_module(signing)

BUNDLE = "com.example.FitPhotoSpike"
TEAM = "FAKETEAM01"
PREFIX = "OLDPREFIX1"
PROFILE_UUID = "01234567-89AB-4CDE-8F01-23456789ABCD"
CERTIFICATE = b"synthetic-certificate-DER-not-a-real-certificate"
NOW = datetime(2026, 9, 17, 12, tzinfo=timezone.utc)


def profile():
    return {
        "TeamIdentifier": [TEAM],
        "ApplicationIdentifierPrefix": [PREFIX],
        "Platform": ["iOS"],
        "Entitlements": {
            "application-identifier": PREFIX + "." + BUNDLE,
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": False,
            "beta-reports-active": True,
            "keychain-access-groups": [PREFIX + ".*"],
        },
        "UUID": PROFILE_UUID,
        "CreationDate": NOW - timedelta(days=1),
        "ExpirationDate": NOW + timedelta(days=364),
        "DeveloperCertificates": [CERTIFICATE],
    }


def signed_entitlements():
    result = deepcopy(profile()["Entitlements"])
    result["keychain-access-groups"] = [PREFIX + "." + BUNDLE]
    return result


class ProfileValidationTests(unittest.TestCase):
    def validate(self, data=None, team=TEAM, cert=CERTIFICATE, now=NOW):
        return signing.validate_profile(
            profile() if data is None else data, BUNDLE, team, cert, now)

    def rejects(self, data, message=None):
        with self.assertRaises(signing.SigningValidationError) as raised:
            self.validate(data)
        if message:
            self.assertEqual(str(raised.exception), message)

    def test_valid_store_profile(self):
        result = self.validate()
        self.assertEqual(result.team_id, TEAM)
        self.assertEqual(result.uuid, PROFILE_UUID)
        self.assertEqual(result.application_identifier, PREFIX + "." + BUNDLE)
        self.assertNotIn(TEAM, repr(result))
        self.assertNotIn(PROFILE_UUID, repr(result))

    def test_team_can_be_safely_derived(self):
        for expected in (None, ""):
            with self.subTest(expected=expected):
                self.assertEqual(self.validate(team=expected).team_id, TEAM)

    def test_legacy_app_id_prefix_does_not_have_to_equal_team(self):
        self.assertNotEqual(PREFIX, TEAM)
        self.validate()

    def test_app_id_prefix_that_equals_team(self):
        data = profile()
        data["ApplicationIdentifierPrefix"] = [TEAM]
        data["Entitlements"]["application-identifier"] = TEAM + "." + BUNDLE
        self.validate(data)

    def test_missing_or_non_mapping_profile(self):
        for data in ({}, [], "private-profile", 1, True):
            with self.subTest(kind=type(data).__name__):
                self.rejects(data)

    def test_invalid_or_mixed_teams(self):
        for value in ([], [TEAM, "OTHERTEAM1"], [TEAM, TEAM], TEAM, [None],
                      ["short"], ["faketeam01"], ["FAKE*EAM01"]):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["TeamIdentifier"] = value
                self.rejects(data)

    def test_expected_team_mismatch_or_invalid_type(self):
        for team in ("OTHERTEAM1", 1, False, [], "invalid", " FAKETEAM01"):
            with self.subTest(kind=type(team).__name__):
                with self.assertRaises(signing.SigningValidationError):
                    self.validate(team=team)

    def test_entitlement_team_must_match_profile(self):
        data = profile()
        data["Entitlements"]["com.apple.developer.team-identifier"] = "OTHERTEAM1"
        self.rejects(data)

    def test_no_wildcard_or_other_app_id(self):
        for value in (PREFIX + ".*", PREFIX + ".com.example.Other",
                      TEAM + "." + BUNDLE, BUNDLE, None):
            with self.subTest(value_type=type(value).__name__):
                data = profile()
                data["Entitlements"]["application-identifier"] = value
                self.rejects(data)

    def test_invalid_or_ambiguous_prefix(self):
        for value in ([], [PREFIX, TEAM], PREFIX, ["*"], [None]):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["ApplicationIdentifierPrefix"] = value
                self.rejects(data)

    def test_rejects_invalid_bundle_identifiers(self):
        for bundle in ("", "no-dot", "com..example", "com.example.*", "com/example.app", None):
            with self.subTest(kind=type(bundle).__name__):
                with self.assertRaises(signing.SigningValidationError):
                    signing.validate_profile(profile(), bundle, TEAM, CERTIFICATE, NOW)

    def test_requires_ios_platform(self):
        for value in ([], ["OSX"], "iOS", None, ["iOS", 1]):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["Platform"] = value
                self.rejects(data)

    def test_development_or_ad_hoc_profile_rejected_even_if_empty_devices(self):
        for value in ([], ["fake-device"], None, False):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["ProvisionedDevices"] = value
                self.rejects(data)

    def test_enterprise_flag_must_be_absent_or_actual_false(self):
        valid = profile()
        valid["ProvisionsAllDevices"] = False
        self.validate(valid)
        for value in (True, 1, 0, "false", None):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["ProvisionsAllDevices"] = value
                self.rejects(data)

    def test_debugging_must_be_explicit_boolean_false(self):
        data = profile()
        del data["Entitlements"]["get-task-allow"]
        self.rejects(data)
        for value in (True, 1, 0, "false", None):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["Entitlements"]["get-task-allow"] = value
                self.rejects(data)

    def test_beta_reports_must_be_explicit_boolean_true(self):
        data = profile()
        del data["Entitlements"]["beta-reports-active"]
        self.rejects(data)
        for value in (False, 1, "true", None):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["Entitlements"]["beta-reports-active"] = value
                self.rejects(data)

    def test_certificate_exact_der_match_and_valid_list(self):
        for value in ([], [b"different-certificate"], [CERTIFICATE.decode()], CERTIFICATE,
                      [CERTIFICATE, b""], [CERTIFICATE, None]):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["DeveloperCertificates"] = value
                self.rejects(data)
        data = profile()
        data["DeveloperCertificates"] = [b"another-synthetic-certificate", CERTIFICATE]
        self.validate(data)

    def test_imported_certificate_input_must_be_nonempty_bytes(self):
        for value in (None, "certificate", b"", bytearray(CERTIFICATE)):
            with self.subTest(kind=type(value).__name__):
                with self.assertRaises(signing.SigningValidationError):
                    self.validate(cert=value)

    def test_expired_profile_is_rejected_including_exact_expiry(self):
        for expires in (NOW, NOW - timedelta(seconds=1)):
            data = profile()
            data["ExpirationDate"] = expires
            self.rejects(data)

    def test_not_yet_valid_and_reversed_dates_rejected(self):
        data = profile()
        data["CreationDate"] = NOW + timedelta(seconds=1)
        self.rejects(data)
        data["CreationDate"] = NOW - timedelta(days=1)
        data["ExpirationDate"] = NOW - timedelta(days=2)
        self.rejects(data)

    def test_naive_plist_dates_are_utc(self):
        data = profile()
        for key in ("CreationDate", "ExpirationDate"):
            data[key] = data[key].replace(tzinfo=None)
        self.validate(data, now=NOW.replace(tzinfo=None))
        encoded = plistlib.dumps(data)
        self.validate(plistlib.loads(encoded))

    def test_offset_aware_dates_compare_in_utc(self):
        data = profile()
        offset = timezone(timedelta(hours=3))
        for key in ("CreationDate", "ExpirationDate"):
            data[key] = data[key].astimezone(offset)
        self.validate(data, now=NOW.astimezone(timezone(timedelta(hours=-7))))

    def test_invalid_dates_are_safe_errors(self):
        for key in ("CreationDate", "ExpirationDate"):
            for value in (None, "secret-value", 0, True):
                with self.subTest(key=key, kind=type(value).__name__):
                    data = profile()
                    data[key] = value
                    self.rejects(data)

    def test_profile_uuid_must_be_canonical_nonzero(self):
        for value in ("secret-value", "00000000-0000-0000-0000-000000000000", None,
                      PROFILE_UUID.replace("-", ""), "{" + PROFILE_UUID + "}"):
            with self.subTest(kind=type(value).__name__):
                data = profile()
                data["UUID"] = value
                self.rejects(data)
        data = profile()
        data["UUID"] = PROFILE_UUID.lower()
        self.assertEqual(self.validate(data).uuid, PROFILE_UUID)

    def test_diagnostic_never_includes_untrusted_profile_values(self):
        marker = "NEVER-PRINT-THIS-PRIVATE-INPUT"
        mutations = [
            ("UUID", marker), ("TeamIdentifier", [marker]),
            ("ApplicationIdentifierPrefix", [marker]), ("DeveloperCertificates", [marker]),
            ("Entitlements", marker), ("ExpirationDate", marker),
        ]
        for key, value in mutations:
            with self.subTest(key=key):
                data = profile()
                data[key] = value
                with self.assertRaises(signing.SigningValidationError) as raised:
                    self.validate(data)
                self.assertNotIn(marker, str(raised.exception))


class SignedEntitlementTests(unittest.TestCase):
    def validate(self, entitlements=None, permitted=None):
        signing.validate_signed_entitlements(
            signed_entitlements() if entitlements is None else entitlements,
            profile() if permitted is None else permitted, BUNDLE, TEAM)

    def test_expected_store_entitlements(self):
        self.validate()

    def test_keychain_groups_may_be_absent(self):
        data = signed_entitlements()
        del data["keychain-access-groups"]
        self.validate(data)

    def test_identifier_team_and_store_flags_are_required(self):
        for key in ("application-identifier", "com.apple.developer.team-identifier",
                    "beta-reports-active"):
            for replacement in ("missing", None, "wrong"):
                with self.subTest(key=key, replacement=replacement):
                    data = signed_entitlements()
                    if replacement == "missing":
                        del data[key]
                    else:
                        data[key] = replacement
                    with self.assertRaises(signing.SigningValidationError):
                        self.validate(data)

    def test_absent_signed_debugging_flag_is_safe(self):
        data = signed_entitlements()
        del data["get-task-allow"]
        self.validate(data)
        for value in (True, None, "false", 0):
            data["get-task-allow"] = value
            with self.assertRaises(signing.SigningValidationError):
                self.validate(data)

    def test_entitlement_flags_do_not_accept_integer_booleans(self):
        for key, value in (("get-task-allow", 0), ("beta-reports-active", 1)):
            data = signed_entitlements()
            data[key] = value
            with self.assertRaises(signing.SigningValidationError):
                self.validate(data)

    def test_unexpected_capabilities_rejected_even_if_profile_permits(self):
        for key in ("aps-environment", "com.apple.security.application-groups", "unknown"):
            with self.subTest(key=key):
                data = signed_entitlements()
                permitted = profile()
                data[key] = "permitted-but-not-needed"
                permitted["Entitlements"][key] = data[key]
                with self.assertRaises(signing.SigningValidationError):
                    self.validate(data, permitted)

    def test_foreign_or_wildcard_signed_keychain_group_rejected(self):
        for value in ("OTHERTEAM1.secret", PREFIX + ".*", PREFIX + ".foo?",
                      PREFIX + ".[foo]", PREFIX + ".", "", None, 1):
            with self.subTest(kind=type(value).__name__):
                data = signed_entitlements()
                data["keychain-access-groups"] = [value]
                with self.assertRaises(signing.SigningValidationError):
                    self.validate(data)

    def test_all_signed_keychain_groups_must_be_permitted(self):
        data = signed_entitlements()
        data["keychain-access-groups"].append("OTHERTEAM1.group")
        with self.assertRaises(signing.SigningValidationError):
            self.validate(data)

    def test_exact_profile_keychain_group_permission(self):
        permitted = profile()
        permitted["Entitlements"]["keychain-access-groups"] = [PREFIX + "." + BUNDLE]
        self.validate(permitted=permitted)

    def test_keychain_permission_rejects_shell_globbing(self):
        for value in ("*", "*.*", PREFIX + ".?*", PREFIX + ".[a-z]*",
                      PREFIX + ".*suffix", 1, None):
            with self.subTest(kind=type(value).__name__):
                permitted = profile()
                permitted["Entitlements"]["keychain-access-groups"] = [value]
                with self.assertRaises(signing.SigningValidationError):
                    self.validate(permitted=permitted)

    def test_missing_or_invalid_keychain_permissions_rejected(self):
        for value in (None, [], PREFIX + ".*"):
            data = profile()
            data["Entitlements"]["keychain-access-groups"] = value
            with self.assertRaises(signing.SigningValidationError):
                self.validate(permitted=data)

    def test_non_dictionary_entitlements_rejected(self):
        for value in ([], 1, "secret"):
            with self.assertRaises(signing.SigningValidationError):
                self.validate(value)


class ExportOptionsTests(unittest.TestCase):
    def test_manual_export_matches_specific_profile_and_certificate(self):
        fingerprint = "abcdef0123456789" * 2 + "abcdef01"
        result = signing.export_options(BUNDLE, TEAM, PROFILE_UUID, fingerprint)
        self.assertEqual(result, {
            "method": "app-store-connect", "destination": "export",
            "signingStyle": "manual", "teamID": TEAM,
            "signingCertificate": fingerprint.upper(),
            "provisioningProfiles": {BUNDLE: PROFILE_UUID},
            "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
        })
        self.assertEqual(plistlib.loads(plistlib.dumps(result)), result)
        self.assertNotIn("uploadBitcode", result)
        self.assertNotIn("compileBitcode", result)

    def test_export_values_are_validated_before_plist_creation(self):
        good = [BUNDLE, TEAM, PROFILE_UUID, "A" * 40]
        for index, bad in ((0, "com.example.*"), (1, "invalid"), (2, "invalid"),
                           (3, "Z" * 40), (3, "A" * 39), (3, None)):
            with self.subTest(index=index):
                values = good.copy()
                values[index] = bad
                with self.assertRaises(signing.SigningValidationError):
                    signing.export_options(*values)


if __name__ == "__main__":
    unittest.main(verbosity=2)
