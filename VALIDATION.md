# V1 validation evidence

The source baseline is the user-provided `FitPhotos-Astra-Source.zip`, without `.git`. No GitHub commit comparison was possible or claimed. This work modifies an extracted review copy only; no commit, push, workflow dispatch, TestFlight upload, or App Store submission is part of this handoff.

## Current status

| Check | Status / boundary |
| --- | --- |
| Synthetic V1 source-policy regressions | PASS: 13 Python tests on Windows. No Photos data, Apple calls, network, or credentials. |
| Full project references, plists, and source policy | PASS: 91 project objects; all 17 app Swift files and 10 test Swift files included exactly once. XML and property lists parsed. This is static validation, not compilation. |
| Native app build / Swift compiler | NOT RUN: Windows has no Xcode or iOS SDK. |
| Swift XCTest execution | NOT RUN for this V1 handoff. 70 XCTest methods are present; none are counted as executed or passed. Tests require macOS and Xcode. |
| Existing Simulator workflow | Preserved from source ZIP; no run triggered for V1. Earlier passing CI does not establish that these changes build. |
| New standalone picker → ratio → preview → Save All / Share | PENDING real-iPhone test. |
| Existing installed Shortcut | User reports successful conversion and saving of 20 ordinary photos before V1. That observation does not verify the new build. |
| Share-sheet Shortcut input | Earlier empty-input failure remains a separate transport/configuration question; V1 does not assume that issue is resolved. |
| Signing / release workflow | Source-ZIP comparison passed for all 14 protected files, including workflows and the AppIntent adapter. Every inherited Xcode build-configuration block is unchanged. No credentials or signed IPA included. |

## What the source-policy tests establish

The verifier distinguishes the native `PhotosUI` picker from full PhotoKit access. It permits `Photos` only in `Platform/PhotoLibrarySaver.swift`, requires an add-only usage description and add-only authorization, and confines the new-image path to `PHAssetCreationRequest.forAsset()` followed by adding a `.photo` file resource in one batch transaction. Synthetic regressions reject full-library permissions, original-asset access/mutations, other PhotoKit types and resource paths, extra save transactions, networking APIs, saver access from the AppIntent, and drift in the installed Shortcuts contract.

The only added Info.plist permission description is `NSPhotoLibraryAddUsageDescription`. The bundle identifier, AppIntent interface, legacy Shortcuts output sizing, signing settings, and release workflows are preserved. The shared renderer also accepts the standalone app's fixed output canvas sizes.

These are static guardrails, not proof of runtime privacy or authorization behavior. The manual tests must still establish that Save All is initiated only by a user tap, the full batch is passed to Share, and originals remain unchanged.

## Reproduce checks

Windows, from the extracted project root:

```powershell
python -B Scripts/verify_project.py
python -B -m unittest discover -s Scripts/Tests -p test_v1_project_policy.py -v
```

macOS, using the toolchain already pinned by the source project:

```sh
bash Scripts/validate-on-mac.sh
```

That existing driver builds for iOS Simulator and runs all tests in the shared `FitPhotoSpike` scheme. Inspect `.xcresult` for executed/skipped tests. Do not treat a static policy pass as an Xcode pass, a skipped native test as a pass, or simulator results as evidence of real-device permission, sharing, memory, or Shortcuts delivery.

The inherited workflow summary still describes the previous no-Photos-access utility. Workflows remain untouched as requested; V1 adds only explicit add-only saving, described in `README.md` and `V1_DEVICE_TEST.md`.

## Before accepting or releasing V1

Run native compilation and all scheme tests, then perform `V1_DEVICE_TEST.md` on the reviewed build. Record the exact installed version/build, iPhone model, iOS version, and each outcome. Keep unsupported-image, low-memory/interruption, denial/retry, full-batch saving/sharing, original preservation, and existing-Shortcut compatibility checks pending until observed.
