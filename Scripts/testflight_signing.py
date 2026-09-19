#!/usr/bin/env python3
"""Strict, quiet validation helpers for the separate TestFlight release job.

This module does not invoke signing tools, log input, or write credentials. The
caller must authenticate/decode profiles with ``security cms``, authenticate the
certificate with Apple's signing tools, and keep all inputs in private temporary
storage. Synthetic tests use placeholder DER bytes, never real signing material.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
import re
from uuid import UUID


class SigningValidationError(ValueError):
    """A fixed safe message; no input values are interpolated into errors."""


@dataclass(frozen=True, repr=False)
class ProfileIdentity:
    """Private return values for signing commands, not a printable report."""

    team_id: str
    uuid: str
    application_identifier: str


TEAM_PATTERN = re.compile(r"[A-Z0-9]{10}\Z")
BUNDLE_PATTERN = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\Z")
SIGNED_ENTITLEMENTS = frozenset({
    "application-identifier",
    "com.apple.developer.team-identifier",
    "get-task-allow",
    "beta-reports-active",
    "keychain-access-groups",
})


def _require(condition, message):
    if not condition:
        raise SigningValidationError(message)


def _valid_team(value):
    return isinstance(value, str) and TEAM_PATTERN.fullmatch(value) is not None


def _valid_bundle(value):
    return isinstance(value, str) and BUNDLE_PATTERN.fullmatch(value) is not None


def _utc(value):
    _require(isinstance(value, datetime), "Profile validity dates are invalid.")
    try:
        return (value.replace(tzinfo=timezone.utc) if value.tzinfo is None
                else value.astimezone(timezone.utc))
    except (ValueError, OverflowError):
        raise SigningValidationError("Profile validity dates are invalid.") from None


def _canonical_uuid(value):
    _require(isinstance(value, str), "Profile UUID is invalid.")
    try:
        parsed = UUID(value)
    except (ValueError, AttributeError):
        raise SigningValidationError("Profile UUID is invalid.") from None
    _require(str(parsed) == value.lower() and parsed.int != 0,
             "Profile UUID is invalid.")
    return str(parsed).upper()


def _identifiers(profile, bundle_id, expected_team):
    _require(type(profile) is dict, "Provisioning profile is invalid.")
    _require(_valid_bundle(bundle_id), "App bundle identifier is invalid.")
    teams = profile.get("TeamIdentifier")
    _require(type(teams) is list and len(teams) == 1 and _valid_team(teams[0]),
             "Profile must identify exactly one valid team.")
    team = teams[0]
    _require(expected_team is None or isinstance(expected_team, str),
             "Configured team identifier is invalid.")
    if expected_team:
        _require(_valid_team(expected_team), "Configured team identifier is invalid.")
        _require(team == expected_team, "Profile team does not match the configured team.")

    prefixes = profile.get("ApplicationIdentifierPrefix")
    _require(type(prefixes) is list and len(prefixes) == 1 and _valid_team(prefixes[0]),
             "Profile must identify exactly one valid App ID prefix.")
    application_identifier = prefixes[0] + "." + bundle_id
    entitlements = profile.get("Entitlements")
    _require(type(entitlements) is dict, "Profile entitlements are invalid.")
    _require(entitlements.get("application-identifier") == application_identifier,
             "Profile must contain this exact explicit App ID.")
    _require(entitlements.get("com.apple.developer.team-identifier") == team,
             "Profile team entitlement does not match its team.")
    return team, application_identifier, entitlements


def validate_profile(profile_dict, bundle_id, expected_team, imported_cert_der, now=None):
    """Accept only a current, explicit iOS App Store distribution profile.

    A blank/None expected_team is derived from the single TeamIdentifier. The
    caller MUST additionally verify the imported Apple Distribution certificate's
    subject OU against the returned team_id, and validate its identity/validity.
    App ID prefix is deliberately not assumed to equal Team ID (legacy accounts).
    """
    team, application_identifier, entitlements = _identifiers(
        profile_dict, bundle_id, expected_team)
    platforms = profile_dict.get("Platform")
    _require(type(platforms) is list and "iOS" in platforms
             and all(isinstance(item, str) for item in platforms),
             "Profile is not valid for iOS.")
    _require("ProvisionedDevices" not in profile_dict,
             "Development and Ad Hoc profiles are not accepted.")
    _require("ProvisionsAllDevices" not in profile_dict
             or profile_dict["ProvisionsAllDevices"] is False,
             "Enterprise profiles are not accepted.")
    _require(entitlements.get("get-task-allow") is False,
             "Profile does not explicitly disable development debugging.")
    _require(entitlements.get("beta-reports-active") is True,
             "Profile is not an App Store distribution profile.")

    created = _utc(profile_dict.get("CreationDate"))
    expires = _utc(profile_dict.get("ExpirationDate"))
    current = _utc(now if now is not None else datetime.now(timezone.utc))
    _require(created <= current < expires and created < expires,
             "Profile is expired or outside its validity period.")
    profile_uuid = _canonical_uuid(profile_dict.get("UUID"))
    certificates = profile_dict.get("DeveloperCertificates")
    _require(type(imported_cert_der) is bytes and bool(imported_cert_der),
             "Imported distribution certificate is invalid.")
    _require(type(certificates) is list and bool(certificates)
             and all(type(item) is bytes and bool(item) for item in certificates),
             "Profile distribution certificate list is invalid.")
    _require(imported_cert_der in certificates,
             "Profile does not include the imported distribution certificate.")
    return ProfileIdentity(team, profile_uuid, application_identifier)


def _allowed_group(group, permitted_groups):
    # Provisioning profile wildcards authorize a suffix, never shell patterns.
    # Restrict matching to a literal prefix plus one trailing '*' so '?', '[' and
    # multiple/interior stars cannot accidentally broaden an entitlement.
    if not isinstance(group, str) or not group or any(c in group for c in "*?[]"):
        return False
    for permitted in permitted_groups:
        if not isinstance(permitted, str) or not permitted:
            continue
        if any(c in permitted for c in "?[]"):
            continue
        if "*" not in permitted:
            if group == permitted:
                return True
        elif permitted.endswith("*") and permitted.count("*") == 1:
            prefix = permitted[:-1]
            if prefix and group.startswith(prefix) and len(group) > len(prefix):
                return True
    return False


def validate_signed_entitlements(entitlements, profile, bundle_id, team):
    """Verify the existing minimal app's signed entitlements against its profile.

    Any newly requested capability fails closed and requires a deliberate review.
    Profile permission wildcards are supported only for keychain access groups;
    the app's own application identifier must always be an exact explicit match.
    """
    actual_team, app_id, profile_entitlements = _identifiers(profile, bundle_id, team)
    _require(type(entitlements) is dict, "Signed app entitlements are invalid.")
    _require(all(isinstance(key, str) and key in SIGNED_ENTITLEMENTS
                 for key in entitlements),
             "Signed app contains an unexpected capability entitlement.")
    _require(entitlements.get("application-identifier") == app_id,
             "Signed app identifier does not match the profile.")
    _require(entitlements.get("com.apple.developer.team-identifier") == actual_team,
             "Signed app team does not match the profile.")
    # Absence of the signed debugging entitlement grants no debugging access.
    # The provisioning profile must still explicitly be a distribution profile.
    _require(("get-task-allow" not in entitlements or entitlements["get-task-allow"] is False)
             and profile_entitlements.get("get-task-allow") is False,
             "Signed app must not permit development debugging.")
    _require(entitlements.get("beta-reports-active") is True
             and profile_entitlements.get("beta-reports-active") is True,
             "Signed app must use App Store distribution entitlements.")

    if "keychain-access-groups" in entitlements:
        groups = entitlements["keychain-access-groups"]
        permitted = profile_entitlements.get("keychain-access-groups")
        _require(type(groups) is list and bool(groups)
                 and type(permitted) is list and bool(permitted),
                 "Signed app keychain access groups are invalid.")
        _require(all(_allowed_group(group, permitted) for group in groups),
                 "Signed app keychain access groups are not permitted by its profile.")


def export_options(bundle_id, team, profile_uuid, certificate_sha1):
    """Current manual App Store Connect export options (not an upload request)."""
    _require(_valid_bundle(bundle_id), "App bundle identifier is invalid.")
    _require(_valid_team(team), "Configured team identifier is invalid.")
    profile_uuid = _canonical_uuid(profile_uuid)
    _require(isinstance(certificate_sha1, str)
             and re.fullmatch(r"[A-Fa-f0-9]{40}", certificate_sha1) is not None,
             "Distribution certificate fingerprint is invalid.")
    return {
        "method": "app-store-connect",
        "destination": "export",
        "signingStyle": "manual",
        "teamID": team,
        "signingCertificate": certificate_sha1.upper(),
        "provisioningProfiles": {bundle_id: profile_uuid},
        "manageAppVersionAndBuildNumber": False,
        "stripSwiftSymbols": True,
    }
