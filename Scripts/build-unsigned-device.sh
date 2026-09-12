#!/bin/bash
# Independent Bash 3.2-compatible device build. Never invokes the Simulator CI.
set -euo pipefail

if [ "${1:-}" = '--help' ] && [ "$#" -eq 1 ]; then
    printf '%s\n' 'Usage: bash Scripts/build-unsigned-device.sh' \
        'Requires macOS and Xcode 26.6. Builds an unsigned arm64 iPhoneOS app,' \
        'checks generated App Intents metadata, and packages Payload/FitPhotoSpike.app.' \
        'Outputs: DeviceBuildRuns/<timestamp>-<PID>/Artifacts/. No device test is run.'
    exit 0
fi
[ "$#" -eq 0 ] || { printf 'No arguments are accepted; use --help.\n' >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || {
    printf 'Device builds require macOS/Xcode. Run ios-device-build.yml from Windows.\n' >&2
    exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/.." && pwd -P)"
mkdir -p "$project_dir/DeviceBuildRuns"
run_dir="$project_dir/DeviceBuildRuns/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir "$run_dir"
artifact_dir="$run_dir/Artifacts"
mkdir "$artifact_dir"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.6.app/Contents/Developer}"
expected_version="${FITPHOTO_EXPECTED_XCODE_VERSION:-26.6}"
finish() {
    status=$?
    trap - EXIT
    printf 'Exit status: %s\nPhysical iPhone tests: NOT RUN\n' "$status" >> "$run_dir/run-info.txt"
    exit "$status"
}
trap finish EXIT

run_logged() {
    local label="$1"
    shift
    set +e
    "$@" 2>&1 | tee "$run_dir/$label.log"
    local results=("${PIPESTATUS[@]}")
    set -e
    printf '%s command exit: %s; log writer exit: %s\n' "$label" "${results[0]}" "${results[1]}" >> "$run_dir/run-info.txt"
    if [ "${results[0]}" -ne 0 ]; then return "${results[0]}"; fi
    [ "${results[1]}" -eq 0 ] || return "${results[1]}"
}

{
    printf 'Purpose: unsigned physical-device IPA preparation, not device testing\n'
    printf 'Developer directory: %s\nExpected Xcode: %s\n' "$DEVELOPER_DIR" "$expected_version"
    printf 'Commit: %s\n' "${GITHUB_SHA:-local-unrecorded}"
    sw_vers
    uname -m
} > "$run_dir/run-info.txt"
[ -d "$DEVELOPER_DIR" ] || { printf 'Pinned Xcode directory is unavailable.\n' >&2; exit 1; }
run_logged xcode-version xcodebuild -version
actual_version="$(awk 'NR == 1 { print $2 }' "$run_dir/xcode-version.log")"
[ "$actual_version" = "$expected_version" ] || { printf 'Unexpected Xcode version: %s\n' "$actual_version" >&2; exit 1; }
run_logged sdks xcodebuild -showsdks

# No project settings are modified. CODE_SIGNING_ALLOWED=NO disables signing;
# redundant identity/profile overrides and exportArchive are unnecessary here.
build_arguments=(-project "$project_dir/FitPhotoSpike.xcodeproj" -scheme FitPhotoSpike \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$run_dir/DerivedData" CODE_SIGNING_ALLOWED=NO ARCHS=arm64)
run_logged build-settings xcodebuild "${build_arguments[@]}" -showBuildSettings
run_logged build xcodebuild build "${build_arguments[@]}" -resultBundlePath "$run_dir/build.xcresult"

app_path="$run_dir/DerivedData/Build/Products/Release-iphoneos/FitPhotoSpike.app"
[ -d "$app_path" ] || { printf 'Device .app not found at expected iphoneos path.\n' >&2; exit 1; }
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Info.plist")"
case "$executable_name" in ''|*/*|..|.) printf 'Invalid executable name.\n' >&2; exit 1;; esac
executable="$app_path/$executable_name"
run_logged executable-file /usr/bin/file "$executable"
run_logged executable-architectures xcrun lipo -archs "$executable"
run_logged executable-platform xcrun vtool -show-build "$executable"

# Diagnostic uploads exclude DerivedData, so preserve generated metadata even
# if an SDK format change makes the next verification step fail.
if [ -d "$app_path/Metadata.appintents" ]; then
    run_logged metadata-diagnostics /usr/bin/ditto "$app_path/Metadata.appintents" "$run_dir/AppIntentsMetadata"
fi

# arm64 alone is insufficient: arm64 Simulator binaries must be rejected.
run_logged device-verification python3 "$script_dir/verify_device_app.py" \
    --app "$app_path" --report "$run_dir/device-app-verification.json"

# A signing stage has no role in this workflow. Reject unexpected signed or
# provisioned output rather than silently shipping it under an unsigned name.
[ ! -e "$app_path/embedded.mobileprovision" ] || { printf 'Unexpected provisioning profile.\n' >&2; exit 1; }
[ ! -e "$app_path/_CodeSignature" ] || { printf 'Unexpected bundle signature.\n' >&2; exit 1; }
if /usr/bin/codesign --display --verbose=2 "$app_path" > "$run_dir/signature-check.log" 2>&1; then
    printf 'Unexpected code signature; unsigned packaging stopped.\n' >&2
    exit 1
fi
# Confirm the failure is specifically an unsigned code object, not another error.
grep -q 'code object is not signed at all' "$run_dir/signature-check.log" || {
    cat "$run_dir/signature-check.log" >&2
    printf 'Could not establish that the app is unsigned.\n' >&2
    exit 1
}

mkdir -p "$run_dir/Packaging/Payload"
run_logged copy-app /usr/bin/ditto "$app_path" "$run_dir/Packaging/Payload/FitPhotoSpike.app"
ipa_path="$artifact_dir/FitPhotoSpike-unsigned.ipa"
(
    cd "$run_dir/Packaging"
    /usr/bin/zip -qry "$ipa_path" Payload
)
run_logged zip-integrity /usr/bin/unzip -t "$ipa_path"
run_logged ipa-verification python3 "$script_dir/verify_device_ipa.py" \
    --app "$app_path" --ipa "$ipa_path" --app-report "$run_dir/device-app-verification.json" \
    --report "$artifact_dir/device-build-verification.json"
(
    cd "$artifact_dir"
    /usr/bin/shasum -a 256 FitPhotoSpike-unsigned.ipa > FitPhotoSpike-unsigned.ipa.sha256
)
printf 'Confirmed arm64 iPhoneOS executable and packaged App Intents metadata.\n'
printf 'Unsigned IPA: %s\nRe-signing/install/physical tests: NOT RUN\n' "$ipa_path"
