#!/usr/bin/env python3
"""Metadata-only App Store Connect client and conservative build numbering.

No third-party modules, stored JWTs, retries that hide failures, or diagnostic
response bodies. Callers must also serialize their release workflow; ASC offers
no build-number reservation, so upload conflicts remain terminal failures.
"""

import base64
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


API_ROOT = "https://api.appstoreconnect.apple.com"
API_HOST = "api.appstoreconnect.apple.com"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_PAGES = 1000
P256_ORDER = int("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)


class ConnectError(RuntimeError):
    """Only fixed, non-sensitive error codes cross this module's boundary."""


def parse_build_number(value):
    """Parse Apple's release CFBundleVersion, ignoring leading zeros."""
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ConnectError("BUILD_NUMBER_INVALID")
    # Bound conversion work, then apply numeric (not lexical) component limits.
    if len(value) > 64:
        raise ConnectError("BUILD_NUMBER_INVALID")
    components = tuple(int(part) for part in value.split("."))
    components += (0,) * (3 - len(components))
    if not 1 <= components[0] <= 9999 or any(part > 99 for part in components[1:]):
        raise ConnectError("BUILD_NUMBER_OUT_OF_RANGE")
    return components


def _positive_ci_integer(value, maximum):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)) or len(str(value)) > 10:
        raise ConnectError("CI_BUILD_COUNTER_INVALID")
    result = int(value)
    if not 1 <= result <= maximum:
        raise ConnectError("CI_BUILD_COUNTER_OUT_OF_RANGE")
    return result


def choose_build_number(run_number, run_attempt, existing_versions):
    """Choose run.attempt.0 or the next higher existing build, failing closed."""
    candidate = (
        _positive_ci_integer(run_number, 9999),
        _positive_ci_integer(run_attempt, 99),
        0,
    )
    highest = max((parse_build_number(version) for version in existing_versions), default=None)
    if highest is not None and candidate <= highest:
        major, minor, patch = highest
        if patch < 99:
            patch += 1
        elif minor < 99:
            minor, patch = minor + 1, 0
        elif major < 9999:
            major, minor, patch = major + 1, 0, 0
        else:
            raise ConnectError("BUILD_NUMBER_EXHAUSTED")
        candidate = (major, minor, patch)
    return ".".join(str(part) for part in candidate)


def der_signature_to_raw(signature):
    """Convert canonical P-256 ECDSA ASN.1 DER to JWT's 64-byte R || S."""
    if not isinstance(signature, bytes) or not 8 <= len(signature) <= 72:
        raise ConnectError("JWT_SIGNATURE_INVALID")
    # P-256 signatures are short enough that DER long-form lengths are invalid.
    if signature[0] != 0x30 or signature[1] != len(signature) - 2:
        raise ConnectError("JWT_SIGNATURE_INVALID")
    offset = 2
    components = []
    for _ in range(2):
        if offset + 2 > len(signature) or signature[offset] != 0x02:
            raise ConnectError("JWT_SIGNATURE_INVALID")
        size = signature[offset + 1]
        offset += 2
        if not 1 <= size <= 33 or offset + size > len(signature):
            raise ConnectError("JWT_SIGNATURE_INVALID")
        component = signature[offset:offset + size]
        offset += size
        if component[0] & 0x80:
            raise ConnectError("JWT_SIGNATURE_INVALID")
        if len(component) > 1 and component[0] == 0:
            if not component[1] & 0x80:
                raise ConnectError("JWT_SIGNATURE_INVALID")
            component = component[1:]
        if len(component) > 32 or not 1 <= int.from_bytes(component, "big") < P256_ORDER:
            raise ConnectError("JWT_SIGNATURE_INVALID")
        components.append(component.rjust(32, b"\0"))
    if offset != len(signature):
        raise ConnectError("JWT_SIGNATURE_INVALID")
    return b"".join(components)


def _base64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _checked_url(url):
    try:
        parsed = urllib.parse.urlsplit(url)
        valid = (
            parsed.scheme == "https"
            and parsed.netloc == API_HOST
            and parsed.hostname == API_HOST
            and parsed.username is None
            and parsed.password is None
            and parsed.port is None
            and parsed.path.startswith("/v1/")
            and not parsed.fragment
            and not any(ord(character) < 33 for character in url)
        )
    except (TypeError, ValueError):
        valid = False
    if not valid:
        raise ConnectError("ASC_PAGINATION_URL_REJECTED")
    return url


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        raise ConnectError("ASC_REDIRECT_REJECTED")


class ConnectClient:
    def __init__(self, key_id, issuer_id, key_path):
        if not isinstance(key_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", key_id):
            raise ConnectError("ASC_KEY_ID_INVALID")
        if not isinstance(issuer_id, str) or not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", issuer_id):
            raise ConnectError("ASC_ISSUER_ID_INVALID")
        self._key_id = key_id
        self._issuer_id = issuer_id
        self._key_path = Path(key_path)
        # Ignore environment proxy variables and never forward a bearer token
        # through a redirect. Python's HTTPSHandler validates server certificates.
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), _RejectRedirects()
        )

    def _token(self):
        now = int(time.time())
        header = {"alg": "ES256", "kid": self._key_id, "typ": "JWT"}
        claims = {"iss": self._issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
        signing_input = ".".join(
            _base64url(json.dumps(value, separators=(",", ":")).encode("utf-8"))
            for value in (header, claims)
        )
        try:
            result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", str(self._key_path), "-passin", "pass:", "-binary"],
                input=signing_input.encode("ascii"), stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, timeout=15, check=False,
            )
        except (OSError, subprocess.SubprocessError):
            raise ConnectError("JWT_SIGNING_FAILED") from None
        if result.returncode != 0:
            raise ConnectError("JWT_SIGNING_FAILED")
        return signing_input + "." + _base64url(der_signature_to_raw(result.stdout))

    def _get(self, url):
        url = _checked_url(url)
        request = urllib.request.Request(url, headers={
            "Authorization": "Bearer " + self._token(),
            "Accept": "application/json",
            "User-Agent": "FitPhotoSpike-Release-Validation",
        })
        try:
            with self._opener.open(request, timeout=30) as response:
                if response.status != 200 or response.geturl() != url:
                    raise ConnectError("ASC_RESPONSE_REJECTED")
                content = response.read(MAX_RESPONSE_BYTES + 1)
        except ConnectError:
            raise
        except Exception:
            # Do not include exception text: it may contain a URL, request IDs,
            # server response details, or account identifiers.
            raise ConnectError("ASC_REQUEST_FAILED") from None
        if len(content) > MAX_RESPONSE_BYTES:
            raise ConnectError("ASC_RESPONSE_TOO_LARGE")
        try:
            payload = json.loads(content)
        except (ValueError, UnicodeError):
            raise ConnectError("ASC_RESPONSE_INVALID") from None
        if not isinstance(payload, dict):
            raise ConnectError("ASC_RESPONSE_INVALID")
        return payload

    def _collection(self, path, parameters, resource_type):
        url = API_ROOT + path + "?" + urllib.parse.urlencode(parameters)
        seen = set()
        resources = []
        while url is not None:
            if url in seen or len(seen) >= MAX_PAGES:
                raise ConnectError("ASC_PAGINATION_INVALID")
            seen.add(url)
            payload = self._get(url)
            data, links = payload.get("data"), payload.get("links")
            if not isinstance(data, list) or not isinstance(links, dict):
                raise ConnectError("ASC_RESPONSE_INVALID")
            for resource in data:
                if (not isinstance(resource, dict) or resource.get("type") != resource_type
                        or not isinstance(resource.get("id"), str)
                        or not re.fullmatch(r"[A-Za-z0-9-]{1,128}", resource["id"])
                        or not isinstance(resource.get("attributes"), dict)):
                    raise ConnectError("ASC_RESOURCE_INVALID")
                resources.append(resource)
            url = links.get("next")
            if url is not None:
                if not isinstance(url, str):
                    raise ConnectError("ASC_PAGINATION_INVALID")
                _checked_url(url)
        return resources

    def existing_build_versions(self, bundle_identifier, marketing_version):
        if (not isinstance(bundle_identifier, str)
                or not re.fullmatch(r"[A-Za-z0-9.-]{1,255}", bundle_identifier)
                or not isinstance(marketing_version, str)
                or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", marketing_version)
                or len(marketing_version) > 32):
            raise ConnectError("ASC_APP_QUERY_INVALID")
        apps = self._collection("/v1/apps", {
            "filter[bundleId]": bundle_identifier, "limit": "200",
        }, "apps")
        if len(apps) != 1 or apps[0]["attributes"].get("bundleId") != bundle_identifier:
            raise ConnectError("ASC_APP_NOT_UNIQUE")
        app_id = apps[0]["id"]
        releases = self._collection("/v1/preReleaseVersions", {
            "filter[app]": app_id, "filter[version]": marketing_version,
            "filter[platform]": "IOS", "limit": "200",
        }, "preReleaseVersions")
        versions = []
        for release in releases:
            attributes = release["attributes"]
            if attributes.get("version") != marketing_version or attributes.get("platform") != "IOS":
                raise ConnectError("ASC_RELEASE_MISMATCH")
            builds = self._collection("/v1/builds", {
                "filter[app]": app_id, "filter[preReleaseVersion]": release["id"],
                "limit": "200", "sort": "-uploadedDate",
            }, "builds")
            versions.extend(build["attributes"].get("version") for build in builds)
        # Include uploads not yet represented by a processed Build resource.
        # Apple permits reusing a FAILED upload's build number. Keep all other
        # states conservative. Endpoint failure stops the release, never falls back.
        uploads = self._collection("/v1/apps/" + app_id + "/buildUploads", {
            "filter[cfBundleShortVersionString]": marketing_version,
            "filter[platform]": "IOS", "limit": "200",
        }, "buildUploads")
        for upload in uploads:
            attributes = upload["attributes"]
            if (attributes.get("cfBundleShortVersionString") != marketing_version
                    or attributes.get("platform") != "IOS"):
                raise ConnectError("ASC_UPLOAD_MISMATCH")
            state = attributes.get("state")
            if isinstance(state, dict) and state.get("state") == "FAILED":
                parse_build_number(attributes.get("cfBundleVersion"))
                continue
            versions.append(attributes.get("cfBundleVersion"))
        for version in versions:
            parse_build_number(version)
        return versions

    def highest_build(self, bundle_identifier, marketing_version):
        return max((parse_build_number(value) for value in
                    self.existing_build_versions(bundle_identifier, marketing_version)), default=None)

    def assert_build_still_available(self, bundle_identifier, marketing_version, build_number):
        candidate = parse_build_number(build_number)
        highest = self.highest_build(bundle_identifier, marketing_version)
        if highest is not None and candidate <= highest:
            raise ConnectError("BUILD_NUMBER_NO_LONGER_AVAILABLE")
