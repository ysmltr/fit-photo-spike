#!/usr/bin/env python3
"""Private, fail-closed macOS signing driver for the manual release workflow.

Never print subprocess output, exceptions, credentials, signing identities or
account identifiers. Raw tool output exists only in the private runner directory
and is deleted by cleanup. No third-party Python packages are required.
"""

import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import zipfile

from testflight_connect import (
    BUILD_CONFLICT_CATEGORIES, ConnectClient, ConnectError, choose_build_number,
)
from testflight_signing import (
    SigningValidationError, export_options, validate_profile,
    validate_signed_entitlements,
)
from verify_device_app import inspect_macho


PROJECT = Path(__file__).resolve().parent.parent
SCHEME = "FitPhotoSpike"
SECRET_NAMES = (
    "APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_PRIVATE_KEY", "IOS_DISTRIBUTION_P12_BASE64",
    "IOS_DISTRIBUTION_P12_PASSWORD", "IOS_PROVISIONING_PROFILE_BASE64",
)
WORK_PREFIX = "fitphotos-testflight-"
STATE_NAME = "cleanup-state.json"


class ReleaseError(RuntimeError):
    """Only constant, safe failure codes are allowed."""


def require(condition, code):
    if not condition:
        raise ReleaseError(code)


def private_write(path, data):
    # Exclusive creation prevents accidental replacement of an existing file.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def write_state(work, state):
    pending = work / "cleanup-state.pending"
    with pending.open("wb") as stream:
        os.chmod(pending, 0o600)
        stream.write(json.dumps(state).encode("utf-8"))
    pending.replace(work / STATE_NAME)


def checked_work_dir(value, allow_missing=False):
    runner = os.environ.get("RUNNER_TEMP", "")
    require(bool(runner) and bool(value), "PRIVATE_WORKSPACE_MISSING")
    root = Path(runner).resolve(strict=True)
    path = Path(value)
    require(path.is_absolute() and not path.is_symlink(), "PRIVATE_WORKSPACE_REJECTED")
    resolved = path.resolve()
    require(resolved.parent == root and resolved.name.startswith(WORK_PREFIX)
            and resolved.name != WORK_PREFIX, "PRIVATE_WORKSPACE_REJECTED")
    if not resolved.exists() and allow_missing:
        return resolved
    require(resolved.is_dir(), "PRIVATE_WORKSPACE_MISSING")
    require(resolved.stat().st_uid == os.getuid()
            and stat.S_IMODE(resolved.stat().st_mode) == 0o700,
            "PRIVATE_WORKSPACE_PERMISSIONS_INVALID")
    return resolved


def prepare():
    require(sys.platform == "darwin", "MACOS_REQUIRED")
    require(os.environ.get("RUNNER_DEBUG") != "1", "DISABLE_ACTIONS_DEBUG_FOR_RELEASE")
    require(bool(re.fullmatch(r"[0-9]+", os.environ.get("GITHUB_RUN_ID", "")))
            and bool(re.fullmatch(r"[0-9]+", os.environ.get("GITHUB_RUN_ATTEMPT", ""))),
            "GITHUB_RUN_CONTEXT_REQUIRED")
    runner = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix=WORK_PREFIX, dir=runner))
    os.chmod(work, 0o700)
    try:
        write_state(work, {"version": 1, "keychains": None, "profile": None})
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("work_dir=" + str(work) + "\n")
    except BaseException:
        shutil.rmtree(work)
        raise
    print("Private release workspace prepared.", flush=True)


def archive_failure_summary(log_path, start, outcome, returncode=None):
    """Return only constants and a bounded process status; never log-derived text.

    Inspect at most 256 KiB from this archive invocation, excluding prior signing
    output. Signals are diagnostic hints, not a determination of the root cause.
    Unknown, unreadable and truncated output must never fall back to raw logging.
    """
    tasks = {
        b"CodeSign": "CODE_SIGN", b"SwiftCompile": "SWIFT_COMPILE",
        b"SwiftEmitModule": "SWIFT_MODULE", b"SwiftDriver": "SWIFT_DRIVER",
        b"CompileC": "COMPILE_C", b"Ld": "LINK",
        b"CompileAssetCatalog": "ASSET_CATALOG",
        b"CompileAssetCatalogVariant": "ASSET_CATALOG",
        b"ProcessInfoPlistFile": "INFO_PLIST", b"PhaseScriptExecution": "BUILD_SCRIPT",
    }
    failed_tasks, hints = set(), set()
    scope = "UNAVAILABLE"
    try:
        if type(start) is not int or start < 0:
            raise ValueError()
        with log_path.open("rb") as stream:
            end = stream.seek(0, os.SEEK_END)
            if end < start:
                raise ValueError()
            offset = max(start, end - 256 * 1024)
            stream.seek(offset)
            data = stream.read(end - offset)
        scope = "FULL_INVOCATION" if offset == start else "TAIL_ONLY"
        if offset > start:
            data = data.partition(b"\n")[2]  # Do not classify a partial first line.
        in_failures = False
        for line in data.splitlines():
            stripped = line.strip()
            if stripped == b"The following build commands failed:":
                in_failures = True
                continue
            if in_failures and line[:1] not in (b" ", b"\t"):
                in_failures = False
            for task, label in tasks.items():
                if stripped == b"Command " + task + b" failed with a nonzero exit code":
                    failed_tasks.add(label)
                if in_failures and stripped.split(None, 1)[:1] == [task]:
                    failed_tasks.add(label)
            lower = stripped.lower()
            if b"error:" in lower:
                if any(phrase in lower for phrase in (
                    b"requires a provisioning profile", b"no profiles for",
                    b"no provisioning profiles", b"couldn't find any provisioning profiles",
                )):
                    hints.add("PROFILE_LOOKUP")
                if b"provisioning profile" in lower and any(phrase in lower for phrase in (
                    b"doesn't include", b"doesn't match", b"doesn't support", b"has app id",
                )):
                    hints.add("PROFILE_COMPATIBILITY")
                if b"no signing certificate" in lower:
                    hints.add("SIGNING_IDENTITY_LOOKUP")
                if b"unable to find a destination" in lower or (
                    b"sdk" in lower and b"cannot be located" in lower
                ):
                    hints.add("SDK_OR_DESTINATION")
            if b"errsecinternalcomponent" in lower:
                hints.add("SECURITY_TOOL_ERROR")
            if b"user interaction is not allowed" in lower:
                hints.add("KEYCHAIN_INTERACTION")
            if b"no space left on device" in lower:
                hints.add("DISK_SPACE")
    except Exception:
        failed_tasks.clear()
        hints.clear()
        scope = "UNAVAILABLE"
    return {
        "outcome": outcome if outcome in {"NONZERO_EXIT", "TIMEOUT", "START_OR_LOG_IO_ERROR", "SUBPROCESS_ERROR"} else "UNKNOWN",
        "exit_code": returncode if type(returncode) is int and -255 <= returncode <= 255 else None,
        "failed_tasks": sorted(failed_tasks),
        "hints": sorted(hints) or ["NO_RECOGNIZED_HINT"],
        "log_scope": scope,
    }


class PrivateTools:
    def __init__(self, work):
        self.work = work
        self.env = dict(os.environ)
        for name in SECRET_NAMES:
            self.env.pop(name, None)
        self.env["LC_ALL"] = "C"
        self.env["TMPDIR"] = str(work / "tmp") + "/"
        (work / "tmp").mkdir(mode=0o700, exist_ok=True)

    def run(self, code, args, *, capture=False, env=None, timeout=180, diagnose_archive=False):
        # Command lines are never echoed: some Apple tools accept passwords only
        # as arguments. All children run on a fresh, single-job hosted runner.
        start = None

        def diagnose(outcome, returncode=None):
            if diagnose_archive:
                try:
                    summary = archive_failure_summary(self.work / "private-tool.log", start, outcome, returncode)
                    print("Archive diagnostics: " + json.dumps(summary, sort_keys=True), flush=True)
                except Exception:
                    pass  # Diagnostics must never mask the original archive failure.

        try:
            with (self.work / "private-tool.log").open("ab") as log:
                if diagnose_archive:
                    start = log.tell()
                process = subprocess.Popen(
                    [str(arg) for arg in args], cwd=PROJECT,
                    env=self.env if env is None else env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE if capture else log,
                    stderr=log, start_new_session=True,
                )
                try:
                    stdout, _ = process.communicate(timeout=timeout)
                except BaseException:
                    # Stop the complete tool process group before removing its
                    # keys/files; descendants must not outlive cancellation.
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.communicate()
                    raise
        except subprocess.TimeoutExpired:
            diagnose("TIMEOUT")
            raise ReleaseError(code) from None
        except OSError:
            diagnose("START_OR_LOG_IO_ERROR")
            raise ReleaseError(code) from None
        except subprocess.SubprocessError:
            diagnose("SUBPROCESS_ERROR")
            raise ReleaseError(code) from None
        if process.returncode != 0:
            diagnose("NONZERO_EXIT", process.returncode)
        require(process.returncode == 0, code)
        return stdout if capture else b""


def profile_directory():
    # Xcode 16 and later use this directory (Xcode 16 release notes).
    return Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"


def cleanup(work):
    if not work.exists():
        return
    failures = []
    try:
        state = json.loads((work / STATE_NAME).read_text(encoding="utf-8"))
        require(type(state) is dict and state.get("version") == 1, "CLEANUP_STATE_INVALID")
    except Exception:
        # A damaged journal must never prevent purging keys and raw logs. It
        # does prevent claiming that external search-list restoration succeeded.
        state = {}
        failures.append("state")

    def quiet(args):
        try:
            result = subprocess.run(args, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=30, check=False)
            return result.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    original = state.get("keychains")
    if original is not None:
        if not (type(original) is list and all(type(item) is str for item in original)):
            failures.append("state")
        elif not quiet(["security", "list-keychains", "-d", "user", "-s", *original]):
            failures.append("search-list")
    installed = state.get("profile")
    if installed:
        try:
            require(type(installed) is str, "CLEANUP_PROFILE_PATH_REJECTED")
            target = Path(installed)
            require(target.parent == profile_directory()
                    and re.fullmatch(r"[A-Fa-f0-9-]{36}\.mobileprovision", target.name)
                    and not target.is_symlink(), "CLEANUP_PROFILE_PATH_REJECTED")
            target.unlink(missing_ok=True)
        except (OSError, ReleaseError):
            failures.append("profile")
    keychain = work / "signing.keychain-db"
    if keychain.exists():
        if not quiet(["security", "delete-keychain", str(keychain)]):
            failures.append("keychain")

    # Always remove .p8/.p12, decoded profiles, IPA, archive and raw output even
    # if a keychain/profile operation failed. Keep only state for the always step.
    for child in work.iterdir():
        if child.name in {STATE_NAME, "signing.keychain-db"}:
            continue
        try:
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
        except OSError:
            failures.append("private-files")
    require(not failures, "CLEANUP_INCOMPLETE_RETRY_REQUIRED")
    shutil.rmtree(work)


def decode_secret_file(value, destination):
    require(isinstance(value, str) and len(value) <= 16 * 1024 * 1024,
            "SIGNING_SECRET_INVALID")
    try:
        data = base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, UnicodeError):
        raise ReleaseError("SIGNING_SECRET_BASE64_INVALID") from None
    require(0 < len(data) <= 12 * 1024 * 1024, "SIGNING_SECRET_INVALID")
    private_write(destination, data)


def read_profile(tool, path):
    decoded = tool.run("PROFILE_CMS_VALIDATION_FAILED", [
        "security", "cms", "-D", "-i", path,
    ], capture=True)
    try:
        return plistlib.loads(decoded)
    except Exception:
        raise ReleaseError("PROFILE_PLIST_INVALID") from None


def build_settings(tool):
    version = tool.run("XCODE_UNAVAILABLE", ["xcodebuild", "-version"], capture=True)
    expected = os.environ.get("FITPHOTO_EXPECTED_XCODE_VERSION", "26.6")
    require(version.decode("utf-8").splitlines()[0] == "Xcode " + expected,
            "XCODE_VERSION_MISMATCH")
    raw = tool.run("RELEASE_SETTINGS_UNAVAILABLE", [
        "xcodebuild", "-showBuildSettings", "-json", "-project",
        PROJECT / "FitPhotoSpike.xcodeproj", "-scheme", SCHEME,
        "-configuration", "Release", "-destination", "generic/platform=iOS",
    ], capture=True)
    try:
        targets = json.loads(raw)
        settings = [target["buildSettings"] for target in targets
                    if target.get("target") == SCHEME]
        require(len(settings) == 1, "RELEASE_TARGET_AMBIGUOUS")
        result = settings[0]
        require(result.get("PRODUCT_NAME") == SCHEME
                and result.get("WRAPPER_NAME") == SCHEME + ".app"
                and result.get("CONFIGURATION") == "Release",
                "RELEASE_TARGET_MISMATCH")
        require(bool(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+",
                                  result["PRODUCT_BUNDLE_IDENTIFIER"])),
                "BUNDLE_IDENTIFIER_INVALID")
        require(bool(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", result["MARKETING_VERSION"]))
                and len(result["MARKETING_VERSION"]) <= 32, "MARKETING_VERSION_INVALID")
        return result
    except ReleaseError:
        raise
    except Exception:
        raise ReleaseError("RELEASE_SETTINGS_INVALID") from None


def import_identity(tool, state, password):
    work = tool.work
    original = shlex.split(tool.run("KEYCHAIN_SEARCH_LIST_UNAVAILABLE", [
        "security", "list-keychains", "-d", "user",
    ], capture=True).decode("utf-8"))
    state["keychains"] = original
    write_state(work, state)
    keychain = work / "signing.keychain-db"
    random_password = secrets.token_urlsafe(48)
    tool.run("KEYCHAIN_CREATE_FAILED", [
        "security", "create-keychain", "-p", random_password, keychain,
    ])
    tool.run("KEYCHAIN_SETTINGS_FAILED", [
        "security", "set-keychain-settings", "-lut", "3600", keychain,
    ])
    tool.run("KEYCHAIN_UNLOCK_FAILED", [
        "security", "unlock-keychain", "-p", random_password, keychain,
    ])
    # No -A (allow all applications); -x makes the imported private key
    # nonextractable. Apple's codesign tooling receives the required partitions.
    tool.run("DISTRIBUTION_P12_IMPORT_FAILED", [
        "security", "import", work / "distribution.p12", "-k", keychain,
        "-P", password, "-f", "pkcs12", "-T", "/usr/bin/codesign", "-x",
    ])
    tool.run("CODESIGN_KEY_ACCESS_FAILED", [
        "security", "set-key-partition-list", "-S", "apple-tool:,apple:",
        "-s", "-k", random_password, keychain,
    ])
    tool.run("KEYCHAIN_SEARCH_LIST_FAILED", [
        "security", "list-keychains", "-d", "user", "-s", keychain,
        "/Library/Keychains/System.keychain",
    ])
    identities = tool.run("DISTRIBUTION_IDENTITY_UNAVAILABLE", [
        "security", "find-identity", "-v", "-p", "codesigning", keychain,
    ], capture=True).decode("utf-8")
    matches = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "([^"\r\n]+)"\s*$', identities, re.M)
    require(len(matches) == 1 and matches[0][1].startswith("Apple Distribution: "),
            "EXACTLY_ONE_APPLE_DISTRIBUTION_IDENTITY_REQUIRED")
    fingerprint = matches[0][0].upper()
    pem = tool.run("DISTRIBUTION_CERTIFICATE_UNAVAILABLE", [
        "security", "find-certificate", "-a", "-p", keychain,
    ], capture=True)
    candidates = []
    for block in re.findall(b"-----BEGIN CERTIFICATE-----\\s*(.*?)\\s*-----END CERTIFICATE-----", pem, re.S):
        der = base64.b64decode(b"".join(block.split()), validate=True)
        if hashlib.sha1(der).hexdigest().upper() == fingerprint:
            candidates.append(der)
    require(len(candidates) == 1, "DISTRIBUTION_CERTIFICATE_AMBIGUOUS")
    certificate = candidates[0]
    cert_path = work / "distribution.der"
    private_write(cert_path, certificate)
    subject = tool.run("DISTRIBUTION_CERTIFICATE_INVALID", [
        "openssl", "x509", "-inform", "DER", "-in", cert_path,
        "-noout", "-subject", "-nameopt", "sep_multiline",
    ], capture=True).decode("utf-8")
    teams = re.findall(r"^\s*OU\s*=\s*([A-Z0-9]{10})\s*$", subject, re.M)
    require(len(teams) == 1, "CERTIFICATE_TEAM_ID_UNAVAILABLE")
    details = tool.run("DISTRIBUTION_CERTIFICATE_INVALID", [
        "openssl", "x509", "-inform", "DER", "-in", cert_path,
        "-noout", "-text", "-startdate",
    ], capture=True).decode("utf-8")
    require("1.2.840.113635.100.6.1.4" in details,
            "CERTIFICATE_NOT_APPLE_DISTRIBUTION")
    start = re.search(r"^notBefore=(.+)$", details, re.M)
    require(start is not None, "CERTIFICATE_VALIDITY_UNAVAILABLE")
    try:
        starts = datetime.strptime(start.group(1), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    except ValueError:
        raise ReleaseError("CERTIFICATE_VALIDITY_INVALID") from None
    require(starts <= datetime.now(timezone.utc), "CERTIFICATE_NOT_YET_VALID")
    tool.run("DISTRIBUTION_CERTIFICATE_EXPIRED", [
        "openssl", "x509", "-inform", "DER", "-in", cert_path, "-noout", "-checkend", "0",
    ])
    return keychain, fingerprint, certificate, teams[0]


def install_profile(work, state, identity):
    folder = profile_directory()
    folder.mkdir(parents=True, mode=0o700, exist_ok=True)
    installed = folder / (identity.uuid + ".mobileprovision")
    require(not installed.exists() and not installed.is_symlink(), "PROFILE_ALREADY_INSTALLED")
    # Record ownership before writing; on this fresh dedicated hosted runner no
    # other release process is allowed to create/replace this exact profile.
    state["profile"] = str(installed)
    write_state(work, state)
    private_write(installed, (work / "profile.mobileprovision").read_bytes())


def verify_signed_app(tool, app, settings, build, identity, certificate, label):
    require(app.is_dir() and not app.is_symlink(), "SIGNED_APP_MISSING")
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == settings["PRODUCT_BUNDLE_IDENTIFIER"],
                "SIGNED_BUNDLE_MISMATCH")
        require(info.get("CFBundleShortVersionString") == settings["MARKETING_VERSION"]
                and info.get("CFBundleVersion") == build, "SIGNED_VERSION_MISMATCH")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"]
                and info.get("DTPlatformName") == "iphoneos", "SIGNED_PLATFORM_INVALID")
        executable = info["CFBundleExecutable"]
        require(executable == SCHEME, "SIGNED_EXECUTABLE_INVALID")
        inspect_macho((app / executable).read_bytes())
    except ReleaseError:
        raise
    except Exception:
        raise ReleaseError("DEVICE_BINARY_INVALID") from None
    tool.run("CODE_SIGNATURE_INVALID", ["codesign", "--verify", "--deep", "--strict", app])
    cert_prefix = tool.work / (label + "-certificate-")
    tool.run("SIGNED_CERTIFICATE_UNAVAILABLE", [
        "codesign", "--display", "--extract-certificates=" + str(cert_prefix), app,
    ])
    require(Path(str(cert_prefix) + "0").read_bytes() == certificate,
            "SIGNED_CERTIFICATE_MISMATCH")
    embedded = app / "embedded.mobileprovision"
    require(embedded.is_file(), "EMBEDDED_PROFILE_MISSING")
    profile = read_profile(tool, embedded)
    checked = validate_profile(profile, settings["PRODUCT_BUNDLE_IDENTIFIER"],
                               identity.team_id, certificate)
    require(checked.uuid == identity.uuid, "EMBEDDED_PROFILE_MISMATCH")
    raw = tool.run("SIGNED_ENTITLEMENTS_UNAVAILABLE", [
        "codesign", "--display", "--entitlements", ":-", app,
    ], capture=True)
    try:
        entitlements = plistlib.loads(raw)
    except Exception:
        raise ReleaseError("SIGNED_ENTITLEMENTS_INVALID") from None
    validate_signed_entitlements(entitlements, profile,
                                 settings["PRODUCT_BUNDLE_IDENTIFIER"], identity.team_id)
    print(label + ": bundle, versions, Apple Distribution signature, profile and arm64 iPhoneOS verified.", flush=True)


def extract_ipa(tool, ipa):
    with zipfile.ZipFile(ipa) as archive:
        members = archive.infolist()
        require(bool(members) and len(members) < 100000, "IPA_STRUCTURE_INVALID")
        names = set()
        for member in members:
            path = PurePosixPath(member.filename)
            require(not path.is_absolute() and ".." not in path.parts
                    and "\\" not in member.filename and path.parts
                    and member.filename not in names, "IPA_PATH_INVALID")
            names.add(member.filename)
            # Exported IPA content must not escape its extraction directory.
            if stat.S_ISLNK(member.external_attr >> 16):
                target = PurePosixPath(archive.read(member).decode("utf-8"))
                require(not target.is_absolute() and ".." not in target.parts
                        and "\\" not in str(target), "IPA_SYMLINK_REJECTED")
        require(sum(member.file_size for member in members) < 4 * 1024**3,
                "IPA_TOO_LARGE")
    destination = tool.work / "ipa-inspection"
    tool.run("IPA_EXTRACTION_FAILED", ["ditto", "-x", "-k", ipa, destination])
    apps = list((destination / "Payload").glob("*.app"))
    require(len(apps) == 1 and apps[0].name == SCHEME + ".app", "IPA_PAYLOAD_INVALID")
    return apps[0]


def apple_command(tool, code, args, env, timeout):
    raw = tool.run(code, args, capture=True, env=env, timeout=timeout)
    try:
        response = json.loads(raw)
    except (ValueError, UnicodeError):
        raise ReleaseError(code) from None

    def has_errors(value):
        if isinstance(value, dict):
            return any((key.lower() in {"error", "errors", "product-errors"} and bool(item))
                       or has_errors(item) for key, item in value.items())
        if isinstance(value, list):
            return any(has_errors(item) for item in value)
        return False

    # altool's documented exit status is authoritative; additionally reject
    # structured errors, empty output and malformed JSON even with exit zero.
    require(type(response) is dict and bool(response) and not has_errors(response), code)


def report_build_conflict(categories):
    # Recheck the finite allowlist at the output boundary; never serialize API data.
    safe = sorted({value for value in categories
                   if type(value) is str and value in BUILD_CONFLICT_CATEGORIES})
    print("BUILD_AVAILABILITY_DIAGNOSTIC " + json.dumps({
        "phase": "PRE_APPLE_VALIDATION", "outcome": "CONFLICT",
        "categories": safe or ["UNCLASSIFIED_CONFLICT"],
    }, separators=(",", ":")), flush=True)


def release(work, credentials):
    require(sys.platform == "darwin", "MACOS_REQUIRED")
    require(os.environ.get("RUNNER_DEBUG") != "1", "DISABLE_ACTIONS_DEBUG_FOR_RELEASE")
    require(all(isinstance(credentials.get(name), str) and credentials[name]
                for name in SECRET_NAMES), "REQUIRED_SECRET_MISSING")
    tool = PrivateTools(work)
    settings = build_settings(tool)
    state = json.loads((work / STATE_NAME).read_text(encoding="utf-8"))
    require(state == {"version": 1, "keychains": None, "profile": None},
            "PRIVATE_WORKSPACE_ALREADY_USED")
    decode_secret_file(credentials["IOS_DISTRIBUTION_P12_BASE64"], work / "distribution.p12")
    decode_secret_file(credentials["IOS_PROVISIONING_PROFILE_BASE64"], work / "profile.mobileprovision")
    keychain, fingerprint, certificate, certificate_team = import_identity(
        tool, state, credentials["IOS_DISTRIBUTION_P12_PASSWORD"])
    configured_team = settings.get("DEVELOPMENT_TEAM", "")
    require(not configured_team or configured_team == certificate_team,
            "PROJECT_CERTIFICATE_TEAM_MISMATCH")
    identity = validate_profile(read_profile(tool, work / "profile.mobileprovision"),
                                settings["PRODUCT_BUNDLE_IDENTIFIER"],
                                configured_team or certificate_team, certificate)
    install_profile(work, state, identity)
    print("App Store profile, team, validity and distribution certificate verified.", flush=True)

    key_id, issuer = credentials["APP_STORE_CONNECT_KEY_ID"], credentials["APP_STORE_CONNECT_ISSUER_ID"]
    key_folder = work / "private_keys"
    key_folder.mkdir(mode=0o700)
    require(bool(re.fullmatch(r"[A-Za-z0-9_-]{1,100}", key_id)), "API_KEY_ID_INVALID")
    key_path = key_folder / ("AuthKey_" + key_id + ".p8")
    key_text = credentials["APP_STORE_CONNECT_PRIVATE_KEY"]
    require(len(key_text) < 16384 and "-----BEGIN PRIVATE KEY-----" in key_text,
            "API_PRIVATE_KEY_INVALID")
    private_write(key_path, key_text.encode("utf-8"))
    tool.run("API_PRIVATE_KEY_INVALID", [
        "openssl", "pkey", "-in", key_path, "-passin", "pass:", "-check", "-noout",
    ])
    client = ConnectClient(key_id, issuer, key_path)
    credentials.clear()
    bundle, marketing = settings["PRODUCT_BUNDLE_IDENTIFIER"], settings["MARKETING_VERSION"]
    existing = client.existing_build_versions(bundle, marketing)
    build = choose_build_number(os.environ.get("GITHUB_RUN_NUMBER"),
                                os.environ.get("GITHUB_RUN_ATTEMPT"), existing)
    print("Marketing version: " + marketing, flush=True)
    print("Build number: " + build, flush=True)
    archive = work / (SCHEME + ".xcarchive")
    print("Creating signed Release archive for generic iOS device.", flush=True)
    tool.run("SIGNED_ARCHIVE_FAILED", [
        "xcodebuild", "archive", "-project", PROJECT / "FitPhotoSpike.xcodeproj",
        "-scheme", SCHEME, "-configuration", "Release", "-sdk", "iphoneos",
        "-destination", "generic/platform=iOS", "-archivePath", archive,
        "-derivedDataPath", work / "DerivedData", "CODE_SIGN_STYLE=Manual",
        "CODE_SIGNING_ALLOWED=YES", "DEVELOPMENT_TEAM=" + identity.team_id,
        "CODE_SIGN_IDENTITY=" + fingerprint, "PROVISIONING_PROFILE_SPECIFIER=" + identity.uuid,
        "CURRENT_PROJECT_VERSION=" + build,
        "OTHER_CODE_SIGN_FLAGS=--keychain " + shlex.quote(str(keychain)),
    ], timeout=1800, diagnose_archive=True)
    verify_signed_app(tool, archive / "Products/Applications" / (SCHEME + ".app"),
                      settings, build, identity, certificate, "Archive")
    options = work / "ExportOptions.plist"
    private_write(options, plistlib.dumps(export_options(bundle, identity.team_id,
                                                         identity.uuid, fingerprint)))
    exported = work / "export"
    tool.run("APP_STORE_EXPORT_FAILED", [
        "xcodebuild", "-exportArchive", "-archivePath", archive,
        "-exportOptionsPlist", options, "-exportPath", exported,
    ], timeout=900)
    ipas = list(exported.glob("*.ipa"))
    require(len(ipas) == 1, "EXPORTED_IPA_AMBIGUOUS")
    ipa = ipas[0]
    verify_signed_app(tool, extract_ipa(tool, ipa), settings, build, identity, certificate, "IPA")
    upload_env = dict(tool.env)
    upload_env["API_PRIVATE_KEYS_DIR"] = str(key_folder)
    common = ["-t", "ios", "-f", ipa, "--apiKey", key_id,
              "--apiIssuer", issuer, "--output-format", "json"]
    # Preflight before contacting Apple's validator; this query reserves nothing.
    # Apple validation/upload remain authoritative for conflicts arising later.
    client.assert_build_still_available(bundle, marketing, build,
                                        report_conflict=report_build_conflict)
    print("Validating signed IPA with Apple upload tooling.", flush=True)
    apple_command(tool, "APPLE_IPA_VALIDATION_FAILED", ["xcrun", "altool", "--validate-app", *common],
                  env=upload_env, timeout=600)
    print("Uploading validated IPA to App Store Connect.", flush=True)
    apple_command(tool, "APPLE_UPLOAD_FAILED_CHECK_CONNECT_BEFORE_RETRY", [
        "xcrun", "altool", "--upload-app", *common,
    ], env=upload_env, timeout=1200)
    print("Upload accepted. Apple processing and physical-iPhone testing remain pending.", flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write("Signed upload accepted by Apple. Processing remains pending.\n\n"
                         + "Marketing version: " + marketing + "\n\nBuild number: " + build
                         + "\n\nArchive and exported IPA passed identity, profile, signature, "
                         "arm64 iPhoneOS checks.\n\n"
                         "No release, App Review submission, external tester enrollment or "
                         "physical-device validation was performed. No GitHub artifacts retained.\n")


def interrupted(_number, _frame):
    raise ReleaseError("RELEASE_INTERRUPTED")


def main(argv=None):
    os.umask(0o077)
    # Remove the raw secrets before spawning any process, including cleanup.
    credentials = {name: os.environ.pop(name, "") for name in SECRET_NAMES}
    command = (sys.argv[1:] if argv is None else argv)
    work = None
    status = 0
    try:
        require(command in (["--prepare"], ["--release"], ["--cleanup"]), "COMMAND_INVALID")
        if command == ["--prepare"]:
            prepare()
            return 0
        work = checked_work_dir(os.environ.get("TESTFLIGHT_WORK_DIR"),
                                allow_missing=command == ["--cleanup"])
        if command == ["--release"]:
            signal.signal(signal.SIGTERM, interrupted)
            signal.signal(signal.SIGINT, interrupted)
            release(work, credentials)
    except (ReleaseError, ConnectError, SigningValidationError) as error:
        # These classes contain fixed messages only; never print general exceptions.
        print("Release stopped: " + str(error), file=sys.stderr, flush=True)
        status = 1
    except BaseException:
        print("Release stopped: UNEXPECTED_PRIVATE_OPERATION_FAILED", file=sys.stderr, flush=True)
        status = 1
    finally:
        credentials.clear()
        if work is not None:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            try:
                cleanup(work)
                print("Private signing files removed; keychain search list restored.", flush=True)
            except BaseException:
                print("Release stopped: CLEANUP_INCOMPLETE_RETRY_REQUIRED", file=sys.stderr, flush=True)
                status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
