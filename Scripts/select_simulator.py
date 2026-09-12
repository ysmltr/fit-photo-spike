#!/usr/bin/env python3
"""Select an available iPhone from simctl JSON; create one only if necessary.

Uses only Python's standard library. The pure choose_simulator function can be
tested on Windows with synthetic inventory. Real Simulator operations require
macOS. stdout contains exactly one validated UUID for the Bash caller.
"""

import argparse
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path


def version_tuple(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", str(value)):
        raise ValueError(f"Invalid OS version: {value!r}")
    parts = tuple(int(part) for part in str(value).split("."))
    return parts + (0,) * (3 - len(parts))


def validate_udid(value):
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value):
        raise ValueError("Expected an actual Simulator UUID, not a name or destination expression.")
    return str(uuid.UUID(value)).upper()


def choose_simulator(inventory, minimum_ios="18.0", maximum_ios="26.5", requested_udid=None):
    minimum, maximum = version_tuple(minimum_ios), version_tuple(maximum_ios)
    if minimum > maximum:
        raise ValueError("The selected SDK is older than the app's minimum iOS version.")
    requested = validate_udid(requested_udid) if requested_udid else None
    iphone_type_ids = {kind["identifier"] for kind in inventory.get("devicetypes", [])
                       if kind.get("productFamily") == "iPhone" or kind.get("name", "").startswith("iPhone")}
    runtimes = []
    for runtime in inventory.get("runtimes", []):
        if not runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        if runtime.get("isAvailable") is not True:
            continue
        version = version_tuple(runtime["version"])
        if minimum <= version <= maximum:
            runtimes.append(runtime)
    runtimes.sort(key=lambda item: version_tuple(item["version"]), reverse=True)
    if not runtimes:
        raise ValueError(f"No available iOS runtime between {minimum_ios} and SDK {maximum_ios}. Install a compatible runtime in Xcode.")

    # Prefer the newest compatible runtime, then an already booted iPhone.
    for runtime in runtimes:
        devices = inventory.get("devices", {}).get(runtime["identifier"], [])
        candidates = [device for device in devices if device.get("isAvailable") is True
                      and (device.get("deviceTypeIdentifier") in iphone_type_ids
                           or device.get("name", "").startswith("iPhone"))]
        candidates.sort(key=lambda item: (item.get("state") != "Booted", item["name"], item["udid"]))
        for device in candidates:
            udid = validate_udid(device["udid"])
            if requested and udid != requested:
                continue
            return {"action": "existing", "udid": udid, "name": device["name"],
                    "state": device.get("state", "Shutdown"),
                    "runtime_identifier": runtime["identifier"], "ios_version": runtime["version"]}
    if requested:
        raise ValueError("Requested UUID is not an available compatible iPhone Simulator in the inventory.")

    # Create from a runtime's explicit supported-device list. Do not guess a
    # device/runtime pairing when simctl hasn't reported its compatibility.
    for runtime in runtimes:
        types = [kind for kind in runtime.get("supportedDeviceTypes", [])
                 if kind.get("productFamily") == "iPhone" or kind.get("name", "").startswith("iPhone")]
        types.sort(key=lambda item: item["identifier"])
        if types:
            return {"action": "create", "name": "iPhone FitPhotoSpike CI", "state": "Shutdown",
                    "device_type_identifier": types[0]["identifier"],
                    "runtime_identifier": runtime["identifier"], "ios_version": runtime["version"]}
    raise ValueError("No compatible iPhone Simulator or reported supported iPhone device type. Create an iPhone Simulator in Xcode and retry.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--minimum-ios", default="18.0")
    parser.add_argument("--maximum-ios", required=True)
    parser.add_argument("--udid")
    args = parser.parse_args()
    try:
        selection = choose_simulator(json.loads(args.inventory.read_text()), args.minimum_ios,
                                     args.maximum_ios, args.udid)
        if selection["action"] == "create":
            completed = subprocess.run(
                ["xcrun", "simctl", "create", selection["name"],
                 selection["device_type_identifier"], selection["runtime_identifier"]],
                check=True, text=True, capture_output=True, timeout=120)
            selection["udid"] = validate_udid(completed.stdout.strip())
        args.output.write_text(json.dumps(selection, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(selection), file=sys.stderr)
        print(selection["udid"])
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f"Simulator selection failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
