# V1 changed files

Baseline: the supplied `FitPhotos-Astra-Source.zip`, not a verified Git commit. Changes are confined to this extracted review copy. No source files were deleted. Generated Python caches from the input ZIP are omitted.

Implemented: independent ordered photo selection, four fixed canvas sizes through the shared renderer, batch conversion, preview, explicit add-only Save All, and whole-batch native Share. Failed or cancelled conversions discard their partial outputs.

## Modified (6)

- `FitPhotoSpike.xcodeproj/project.pbxproj` — Adds source/test membership only; every original build setting is unchanged.
- `FitPhotoSpike/App/Info.plist` — Adds only the Save All add-only permission description.
- `FitPhotoSpike/ImageProcessing/CanvasGeometry.swift` — Adds fixed canvas geometry; retains legacy Shortcut sizing.
- `FitPhotoSpike/ImageProcessing/ImageRenderer.swift` — Shares one rendering implementation between legacy and fixed-size policies.
- `FitPhotoSpike/Views/ContentView.swift` — Replaces the launcher with the standalone app flow.
- `Scripts/verify_project.py` — Updates static privacy guards for explicit add-only saving and verifies all sources.

## Added (22)

- `CHANGED_FILES.md`
- `FitPhotoSpike/AppFlow/AppSessionFiles.swift`
- `FitPhotoSpike/AppFlow/FitPhotosModel.swift`
- `FitPhotoSpike/ImageProcessing/AppBatchProcessor.swift`
- `FitPhotoSpike/ImageProcessing/OutputRatio.swift`
- `FitPhotoSpike/Platform/BatchShareSheet.swift`
- `FitPhotoSpike/Platform/PhotoLibrarySaver.swift`
- `FitPhotoSpike/Platform/PhotoSelectionPicker.swift`
- `FitPhotoSpike/Platform/PickerFileLoader.swift`
- `FitPhotoSpike/Views/FileThumbnail.swift`
- `FitPhotoSpike/Views/PhotoPreview.swift`
- `FitPhotoSpike/Views/RatioChooser.swift`
- `FitPhotoSpikeTests/AppBatchProcessorTests.swift`
- `FitPhotoSpikeTests/AppSessionFilesTests.swift`
- `FitPhotoSpikeTests/FixedOutputRendererTests.swift`
- `FitPhotoSpikeTests/OutputRatioTests.swift`
- `FitPhotoSpikeTests/PhotoLibrarySaverTests.swift`
- `FitPhotoSpikeTests/PickerFileLoaderTests.swift`
- `README.md`
- `Scripts/Tests/test_v1_project_policy.py`
- `V1_DEVICE_TEST.md`
- `VALIDATION.md`

## Preserved and validation

- AppIntent and TemporaryImageProcessor are byte-for-byte unchanged from the source ZIP.
- Signing/release scripts, all GitHub Actions workflows, bundle identifiers, versions, build settings, existing tests, and privacy manifest are unchanged.
- PASS on Windows: project/XML/plist/source-policy validation and 13 synthetic policy regressions.
- 40 new XCTest methods were added (70 total). They have not been executed here; Xcode/iOS SDK are unavailable on Windows.
- Native build, native tests, standalone iPhone behavior, and Shortcut regression testing on this implementation remain pending. See `VALIDATION.md` and `V1_DEVICE_TEST.md`.

## Apply for review

Extract the ZIP into a separate folder and compare these listed files with your current checkout. Review and copy the listed modifications/additions into that checkout, preserving its `.git` directory and any unrelated local changes. Do not replace credentials or release configuration. No files have been copied into your original checkout by this task.

After review, run the unchanged Simulator workflow or `bash Scripts/validate-on-mac.sh` on a Mac, then perform the device checks. No TestFlight upload, submission, or release was triggered.
