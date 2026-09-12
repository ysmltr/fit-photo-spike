#!/usr/bin/env python3
"""Fail-closed inspection of a built app; this does not install or run it.

Run on the macOS runner after the unsigned Release iphoneos build. The report
describes the bytes inspected, never physical-device or Shortcuts validation.
Only Python's standard library is required.
"""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys


ARM64 = 0x0100000C
LC_BUILD_VERSION = 0x32
IOS_PLATFORM = 2
INTENT_NAME = "FitPhotosIntent"
INTENT_TITLE = "Fit Photos to 4:5"


class VerificationError(ValueError):
    """The artifact cannot be verified as the expected device app."""


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def packed_version(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def inspect_thin_macho(data):
    require(len(data) >= 32, "Executable is shorter than a 64-bit Mach-O header.")
    endian = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}.get(bytes(data[:4]))
    require(endian is not None, "Executable slice is not a 64-bit Mach-O binary.")
    _, cpu, subtype, filetype, ncmds, sizecmds, _, _ = struct.unpack_from(endian + "8I", data)
    require(cpu == ARM64, f"Unexpected CPU type {cpu:#x}; arm64 is required.")
    require(filetype == 2, f"Expected MH_EXECUTE (2), got Mach-O file type {filetype}.")
    require(0 < ncmds <= sizecmds // 8, "Invalid Mach-O load-command count.")
    end = 32 + sizecmds
    require(end <= len(data), "Mach-O load commands extend beyond the executable.")
    offset = 32
    builds = []
    for _ in range(ncmds):
        require(offset + 8 <= end, "Truncated Mach-O load command.")
        command, length = struct.unpack_from(endian + "2I", data, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= end,
                "Invalid 64-bit Mach-O load-command size.")
        if command == LC_BUILD_VERSION:
            require(length >= 24, "Truncated LC_BUILD_VERSION.")
            platform, minimum, sdk, ntools = struct.unpack_from(endian + "4I", data, offset + 8)
            require(length == 24 + ntools * 8, "Invalid LC_BUILD_VERSION tool array.")
            require(platform == IOS_PLATFORM,
                    f"LC_BUILD_VERSION platform {platform} is not iOS device (2); "
                    "an arm64 Simulator binary is not a device binary.")
            builds.append({"platform": "iOS", "platform_id": platform,
                           "minimum_os": packed_version(minimum), "sdk": packed_version(sdk)})
        offset += length
    require(offset == end, "Mach-O load-command sizes do not match sizeofcmds.")
    require(len(builds) == 1, "Exactly one iOS LC_BUILD_VERSION command is required.")
    return {"architecture": "arm64", "cpu_type": cpu, "cpu_subtype": subtype,
            "file_type": "MH_EXECUTE", **builds[0]}


def inspect_macho(data):
    """Inspect thin or universal Mach-O slices, rejecting all non-device slices."""
    require(len(data) >= 4, "Executable is empty or truncated.")
    formats = {
        b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
    }
    fat = formats.get(bytes(data[:4]))
    if fat is None:
        return [inspect_thin_macho(data)]
    endian, wide = fat
    require(len(data) >= 8, "Truncated universal Mach-O header.")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    size = 32 if wide else 20
    table_end = 8 + count * size
    require(0 < count <= 32 and table_end <= len(data), "Invalid universal architecture table.")
    slices = []
    ranges = []
    for index in range(count):
        values = struct.unpack_from(endian + ("IIQQII" if wide else "5I"), data, 8 + index * size)
        cpu, subtype, offset, length, alignment = values[:5]
        require(cpu == ARM64, "Universal executable contains a non-arm64 slice.")
        require(alignment <= 31 and offset % (1 << alignment) == 0,
                "Invalid universal Mach-O slice alignment.")
        require(offset >= table_end and length >= 32 and offset + length <= len(data),
                "Universal Mach-O slice is outside the executable.")
        require(all(offset + length <= start or offset >= stop for start, stop in ranges),
                "Universal Mach-O slices overlap.")
        ranges.append((offset, offset + length))
        found = inspect_thin_macho(data[offset:offset + length])
        require(found["cpu_type"] == cpu and found["cpu_subtype"] == subtype,
                "Universal architecture table does not match its slice.")
        slices.append(found)
    return slices


def inspect_metadata(app):
    # This build output is compiler metadata, not the Swift source. Its current
    # schema is validated below; an unrecognized Xcode schema must fail visibly.
    metadata = app / "Metadata.appintents" / "extract.actionsdata"
    version_path = app / "Metadata.appintents" / "version.json"
    require(metadata.is_file() and metadata.stat().st_size > 0,
            "Missing or empty Metadata.appintents/extract.actionsdata; App Intents extraction is required.")
    require(metadata.resolve().is_relative_to(app.resolve()), "App Intents metadata escapes the app bundle.")
    require(version_path.is_file() and version_path.stat().st_size > 0,
            "Missing or empty Metadata.appintents/version.json.")
    require(version_path.resolve().is_relative_to(app.resolve()), "App Intents version metadata escapes the app bundle.")
    metadata_bytes = metadata.read_bytes()
    try:
        document = json.loads(metadata_bytes)
        version = json.loads(version_path.read_bytes())
    except (UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError("App Intents extract.actionsdata or version.json is not readable JSON; inspect the Xcode extraction "
                                "log and update the metadata validator for this compiler schema.") from error
    return {**inspect_action_document(document, metadata.relative_to(app).as_posix()),
            "sha256": hashlib.sha256(metadata_bytes).hexdigest(), "bytes": len(metadata_bytes),
            "version_metadata_path": version_path.relative_to(app).as_posix(), "version_metadata": version}


def inspect_action_document(document, relative_path):
    # `extract.actionsdata` is Xcode-generated build output, not a public API.
    # We inspect the named action record in its JSON action map, never grep for
    # words anywhere in the file. Keep unsupported schema changes visible.
    # The action-map / identifier / title.key structure is evidenced by an
    # independently captured Xcode extraction (2024), not an Apple schema spec:
    # https://mengtnt.com/2024/01/01/widgets.html
    require(isinstance(document, dict), "Unsupported App Intents metadata: JSON root is not an object.")
    actions = document.get("actions")
    require(isinstance(actions, (dict, list)) and actions,
            "Missing or unsupported App Intents actions collection; root keys: "
            + ", ".join(sorted(document)) + ". Inspect extract.actionsdata and the extraction log.")
    matches = []
    action_items = list(actions.items()) if isinstance(actions, dict) else list(enumerate(actions))
    for key, action in action_items:
        if not isinstance(action, dict):
            continue
        identifier = action.get("identifier")
        # Module-qualified identifiers are accepted without accepting substrings
        # such as OtherFitPhotosIntent or a name mentioned in description text.
        if isinstance(identifier, str) and identifier.split(".")[-1] == INTENT_NAME:
            matches.append((key, action))
    require(len(matches) == 1,
            f"Expected one action record with identifier {INTENT_NAME}; found {len(matches)}. "
            "Available action keys: " + ", ".join(str(key) for key, _ in action_items)
            + ". Inspect extract.actionsdata if Xcode changed its schema.")
    key, action = matches[0]
    title = action.get("title")
    title_value = title.get("key") if isinstance(title, dict) else title
    require(title_value == INTENT_TITLE,
            f"{INTENT_NAME} action title is missing, unsupported, or does not equal {INTENT_TITLE!r}.")
    require(action.get("isDiscoverable") is True,
            f"{INTENT_NAME} metadata must explicitly set isDiscoverable to true.")
    mangled_name = action.get("mangledTypeName")
    require(isinstance(mangled_name, str) and mangled_name,
            f"{INTENT_NAME} has no mangledTypeName; inspect the compiler metadata schema.")
    return {"metadata_path": relative_path, "action_key": key,
            "identifier": action["identifier"], "title": title_value,
            "is_discoverable": True, "mangled_type_name": mangled_name,
            "validation_scope": "Compiled action metadata record present; OS discovery remains untested."}


def verify_app(app):
    app = app.resolve()
    require(app.is_dir() and app.suffix == ".app", "--app must name a built .app directory.")
    info_path = app / "Info.plist"
    require(info_path.is_file(), "Built app has no Info.plist.")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    require(isinstance(info, dict), "Built Info.plist is not a dictionary.")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
            "CFBundleSupportedPlatforms must be exactly ['iPhoneOS'].")
    require(info.get("DTPlatformName") == "iphoneos", "DTPlatformName must be iphoneos.")
    require(info.get("CFBundlePackageType") == "APPL", "CFBundlePackageType must be APPL.")
    executable_name = info.get("CFBundleExecutable")
    require(isinstance(executable_name, str) and executable_name not in ("", ".", "..")
            and "/" not in executable_name and "\\" not in executable_name
            and "$" not in executable_name, "Invalid or unresolved CFBundleExecutable.")
    executable = (app / executable_name).resolve()
    require(executable.parent == app and executable.is_file(),
            "CFBundleExecutable must resolve to a file directly inside the app.")
    identifier = info.get("CFBundleIdentifier")
    require(isinstance(identifier, str) and identifier and "$" not in identifier,
            "Missing or unresolved CFBundleIdentifier.")
    require(not (app / "embedded.mobileprovision").exists(),
            "Unexpected provisioning profile in unsigned artifact.")
    require(not (app / "_CodeSignature").exists(),
            "Unexpected code-signature directory in unsigned artifact.")
    slices = inspect_macho(executable.read_bytes())
    intents = inspect_metadata(app)
    return {
        "verification": "passed", "app": str(app), "bundle_identifier": identifier,
        "executable": executable_name, "supported_platforms": ["iPhoneOS"],
        "macho_slices": slices, "app_intents": intents,
        "physical_device_testing": "not_run", "shortcuts_discovery": "not_run",
        "scope": "Static inspection of the built unsigned app; no installation or execution.",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        report = verify_app(args.app)
        status = 0
    except (VerificationError, OSError, plistlib.InvalidFileException, struct.error) as error:
        report = {"verification": "failed", "error": str(error), "app": str(args.app),
                  "physical_device_testing": "not_run", "shortcuts_discovery": "not_run"}
        status = 1
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return status


if __name__ == "__main__":
    sys.exit(main())
