# Validation record — temporary-output MVP

Updated **2026-09-11**, in a Windows-only workspace. **Xcode compilation, Swift test execution, GitHub Actions execution, and physical iPhone validation remain NOT RUN.** No GitHub repository or macOS environment was available. Source preparation and local infrastructure checks are separate from native test results.

## Checks possible on Windows

| Check | Result |
|---|---|
| OpenStep Xcode project | Passed: 53 objects parsed, object references resolve |
| Source membership | Passed: all 6 production Swift files and 4 XCTest files included exactly once |
| Info.plist / privacy manifest / scheme / workspace XML | Parsed successfully; no Photos read/write or add-only usage description, no tracking or collection declared |
| Production architecture guard | Passed: no Photos import, PHAsset/PHPhotoLibrary calls, save-to-library API, old identity probe, network client, or signing entitlements |
| Simulator selector | 15 synthetic Python cases passed; no real Simulator invoked |
| Bash runner | 5 checks passed: syntax, simulated success, command failure propagation through tee, log-writer failure, and explicit Windows refusal |
| Workflow | YAML 1.2 and static configuration assertions passed |
| Windows setup | All 8 PowerShell command blocks parsed; GitHub commands were not executed |

`Scripts/verify_project.py` performs the static project and permission checks and is also invoked by the macOS runner. It does **not** compile Swift. Run it from Windows with:

```powershell
python Scripts/verify_project.py
```

The 15 selector and 5 Bash checks are infrastructure checks, not 20 passing iOS tests. Source review of cancellation and file ownership is not a runtime result. The native build cannot be marked passed until Xcode succeeds.

## Native tests included — not executed

There are **30 XCTest methods** in the shared scheme:

| Suite | Methods | Intended coverage |
|---|---:|---|
| CanvasGeometryTests | 9 | Portrait, landscape, square, tall screenshot, full aspect fit, centered canvas, no enlargement, output cap, invalid dimensions |
| ImageRendererTests | 8 | All 8 EXIF orientations, transparency on white, shape rendering, visible edges, actual JPEG/sRGB/orientation metadata, source unchanged, HEIC, rejected formats/animation |
| TemporaryImageProcessorTests | 10 | Ordered multiple outputs, exactly 20, zero/21 rejected before writes, filenames/types/completion flag, retained successful files, source unchanged, failure/cancel cleanup, serial scratch staging, separate invocation ownership |
| FitPhotosIntentTests | 3 | Direct perform() returns readable JPEGs and rejects empty/oversized input |

Failure and cancellation tests inject controlled render behavior; successful output tests use real ImageIO fixtures. A HEIC fixture test may skip if the destination has no HEIC encoder. A skip does not prove HEIC support. Pixel checks tolerate JPEG encoding differences.

AppIntentsTesting is unavailable in the selected Xcode 26.6 / iOS 26.5 configuration; Apple's framework requires the newer 27 SDK/runtime and a separate UI Testing target. No empty conditional target is counted as coverage. Direct XCTest calls do not test live Shortcuts discovery, transport, or system cleanup. See [APP_INTENTS_TESTING.md](APP_INTENTS_TESTING.md).

## Stage 1 — macOS CI record

`.github/workflows/ios-ci.yml` runs on push, pull request, and manual dispatch. It selects GitHub-hosted `macos-26` and Xcode **26.6**, verifies that toolchain, runs the static guard, builds the app, selects/creates and boots a compatible iPhone Simulator, waits for readiness, and executes the entire shared scheme with `xcodebuild test`. There are no test-name filters. The current [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) includes the iOS 26.5 SDK/runtime.

Both build and test use `CODE_SIGNING_ALLOWED=NO`. This stage needs no Apple Developer Program credentials, certificates, App Store Connect account, or paid Apple secrets. Driver/build/test/boot logs, toolchain/destination metadata, available `.xcresult` bundles, and failure diagnostics are uploaded on success/failure for 14 days. DerivedData is excluded. Failures before Xcode starts cannot produce an Xcode result bundle.

Use [WINDOWS_SETUP.md](WINDOWS_SETUP.md) to create the repository, push, dispatch, watch, and download artifacts. Fill these fields only from an actual run:

| Evidence | Result |
|---|---|
| Repository / Actions URL / tested commit SHA | PENDING — repository not created |
| Runner image / actual Xcode build / SDK | PENDING |
| Selected Simulator model / runtime / UDID | PENDING |
| xcodebuild build exit / build.xcresult | NOT RUN |
| xcodebuild test exit / test.xcresult | NOT RUN |
| Actual tests passed / failed / skipped, including HEIC | UNKNOWN |
| Downloaded artifacts | PENDING |
| Stage 1 accepted | **NO — awaiting successful native run and reviewed results** |

## Stage 2 — physical iPhone

**NOT RUN.** Follow [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md) and [DEVICE_TESTS.md](DEVICE_TESTS.md). Required evidence is now Select Photos and share-sheet input → Fit → Share, correct image appearance, untouched originals and no automatic library additions, delayed downstream file access, completion/cancel/error cleanup, and 20-image/48 MP memory behavior.

Every output sets `removedOnCompletion = true`, available since iOS 16 according to [Apple's API documentation](https://developer.apple.com/documentation/appintents/intentfile/removedoncompletion). It asks Shortcuts to remove the temporary file at workflow completion. Setting the property or passing direct tests does not prove actual system cleanup or downstream file lifetime. Process termination may leave temporary files for the system to reclaim; the app does not run an age-based sweep that could delete an active workflow's files.

The 1–20 temporary-file pipeline is now implemented. The former PhotoKit editor, prepared-edit/adjustment/error/identity models, edit view model, identity intent, and identity tests were deleted. In-place editing and PHAsset recovery are no longer product gates or production behavior. A green Simulator run alone does not establish physical MVP acceptance.
