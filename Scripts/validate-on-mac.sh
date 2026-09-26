#!/bin/bash
# Bash 3.2 compatible; all tests in the shared scheme run without filters.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash Scripts/validate-on-mac.sh [SIMULATOR-UDID]

Build the app, choose/create an installed iOS 18+ Simulator, boot it, and run
every test in the FitPhotoSpike shared scheme. An optional UUID must identify
an available compatible iPhone Simulator; it never selects a physical device.

Default toolchain: /Applications/Xcode_26.6.app/Contents/Developer.
To intentionally change it, set both DEVELOPER_DIR and
FITPHOTO_EXPECTED_XCODE_VERSION. The version must match exactly.

Requires macOS, full Xcode, python3, and an installed compatible iOS runtime.
No Apple signing account or signing secrets are needed for Simulator tests.
Evidence: ValidationRuns/<UTC timestamp>-<PID>/ (logs, metadata, xcresult).
DerivedData stays in that directory locally but is excluded from CI artifacts.
This command does not validate physical-iPhone selection, saving or sharing.
USAGE
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi
if [ "$#" -eq 1 ] && { [ "$1" = '--help' ] || [ "$1" = '-h' ]; }; then
    usage
    exit 0
fi
[ "$(uname -s)" = Darwin ] || fail 'Native iOS validation requires macOS/Xcode. Use the GitHub Actions workflow from Windows.'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/.." && pwd -P)"
project_path="$project_dir/FitPhotoSpike.xcodeproj"
[ -d "$project_path" ] || fail "Project not found: $project_path"
mkdir -p -- "$project_dir/ValidationRuns"
run_dir="$project_dir/ValidationRuns/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -- "$run_dir"
printf 'Evidence directory: %s\n' "$run_dir"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.6.app/Contents/Developer}"
expected_version="${FITPHOTO_EXPECTED_XCODE_VERSION:-26.6}"
simulator_udid=''
started_simulator=NO
finish() {
    final_status=$?
    trap - EXIT
    set +e
    if [ -n "$simulator_udid" ]; then
        xcrun simctl list devices --json > "$run_dir/devices-after.json" 2> "$run_dir/devices-after-error.log"
        if [ "$final_status" -ne 0 ]; then
            # Only Simulator logs from this run; no personal Photos library.
            xcrun simctl spawn "$simulator_udid" log show --last 5m --style compact \
                --predicate 'process == "FitPhotoSpike" OR process CONTAINS "xctest"' \
                > "$run_dir/simulator-test.log" 2>&1
        fi
        if [ "$started_simulator" = YES ]; then
            xcrun simctl shutdown "$simulator_udid" >> "$run_dir/simulator-shutdown.log" 2>&1
        fi
    fi
    printf 'Finished UTC: %s\nScript exit status: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$final_status" >> "$run_dir/run-info.txt"
    printf 'Validation exit status: %s. Evidence: %s\n' "$final_status" "$run_dir"
    exit "$final_status"
}
trap finish EXIT

{
    printf 'Started UTC: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Developer directory: %s\nExpected Xcode: %s\n' "$DEVELOPER_DIR" "$expected_version"
    printf 'Project: %s\nScheme: FitPhotoSpike\nScope: Simulator build and ALL scheme tests; no physical-device validation.\n' "$project_path"
    sw_vers
    uname -m
} > "$run_dir/run-info.txt"
[ -d "$DEVELOPER_DIR" ] || fail "Pinned Xcode is unavailable at $DEVELOPER_DIR. Update the workflow/toolchain deliberately; do not silently fall back."
command -v python3 >/dev/null || fail 'python3 is required for Simulator discovery.'
command -v xcodebuild >/dev/null || fail 'xcodebuild is unavailable.'

run_logged() {
    local label="$1"
    shift
    set +e
    "$@" 2>&1 | tee "$run_dir/$label.log"
    local pipeline_status=("${PIPESTATUS[@]}")
    set -e
    printf '%s command exit: %s; log writer exit: %s\n' "$label" "${pipeline_status[0]}" "${pipeline_status[1]}" >> "$run_dir/run-info.txt"
    if [ "${pipeline_status[0]}" -ne 0 ]; then return "${pipeline_status[0]}"; fi
    [ "${pipeline_status[1]}" -eq 0 ] || return "${pipeline_status[1]}"
}

run_logged xcode-version xcodebuild -version
actual_version="$(awk 'NR == 1 { print $2 }' "$run_dir/xcode-version.log")"
[ "$actual_version" = "$expected_version" ] || fail "Expected Xcode $expected_version; selected $actual_version."
run_logged sdks xcodebuild -showsdks
run_logged swift-version xcrun swift --version
run_logged project-structure python3 "$script_dir/verify_project.py"
xcrun simctl list --json > "$run_dir/simulators-before.json" 2> "$run_dir/simulator-discovery-error.log"
xcrun --sdk iphonesimulator --show-sdk-version > "$run_dir/simulator-sdk-version.txt"
sdk_version="$(cat "$run_dir/simulator-sdk-version.txt")"
derived_data_path="$run_dir/DerivedData"

run_logged build xcodebuild build \
    -project "$project_path" -scheme FitPhotoSpike -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data_path" \
    -resultBundlePath "$run_dir/build.xcresult" \
    CODE_SIGNING_ALLOWED=NO

# JSON data is passed as arguments/files, never evaluated as shell source.
selection_args=(--inventory "$run_dir/simulators-before.json" --minimum-ios 18.0 \
    --maximum-ios "$sdk_version" --output "$run_dir/selected-simulator.json")
if [ "$#" -eq 1 ]; then selection_args+=(--udid "$1"); fi
simulator_udid="$(python3 "$script_dir/select_simulator.py" "${selection_args[@]}" 2> "$run_dir/simulator-selection.log")"
printf 'Simulator UUID: %s\n' "$simulator_udid" >> "$run_dir/run-info.txt"
simulator_state="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$run_dir/selected-simulator.json")"
if [ "$simulator_state" != Booted ]; then
    run_logged simulator-boot xcrun simctl boot "$simulator_udid"
    started_simulator=YES
fi
run_logged simulator-bootstatus xcrun simctl bootstatus "$simulator_udid" -b
run_logged destinations xcodebuild -project "$project_path" -scheme FitPhotoSpike -showdestinations

run_logged test xcodebuild test \
    -project "$project_path" -scheme FitPhotoSpike -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_udid" \
    -destination-timeout 120 -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 300 \
    -derivedDataPath "$derived_data_path" \
    -resultBundlePath "$run_dir/test.xcresult" \
    CODE_SIGNING_ALLOWED=NO

printf 'App build and test command succeeded. Review test.xcresult for executed/skipped tests.\n'
printf 'Real iPhone selection, saving, sharing, file lifetime, and memory validation remain pending in PHYSICAL_DEVICE_TEST.md.\n'
