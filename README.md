# Fit Photos

Native Swift / SwiftUI for iOS 18+. **Fit Photos to 4:5** takes 1–20 image files from Shortcuts, renders each into a white 4:5 canvas on the device, and returns temporary JPEG files to the next action. The full supplied image stays visible with its proportions and orientation preserved. The app never saves to or modifies the Photos library.

**Validation status: native compilation, Swift test execution, GitHub Actions execution, and physical iPhone tests are NOT RUN in this Windows workspace.** The project and automated macOS workflow are prepared for validation; preparation is not a passing build. See [VALIDATION.md](VALIDATION.md).

The internal Xcode project, scheme, and directory remain named `FitPhotoSpike` so existing CI and Windows setup commands keep working. The product screen is **Fit Photos**. Start with [WINDOWS_SETUP.md](WINDOWS_SETUP.md) to create the GitHub repository and run CI from Windows.

## Production architecture

1. The **Fit Photos to 4:5** AppIntent accepts an image-constrained array of `IntentFile` values. It rejects an empty request or more than 20 files before processing.
2. `TemporaryImageProcessor` processes one image at a time. ImageIO reads and decodes each supplied representation; the renderer applies its EXIF orientation, computes an aspect-fit rectangle, and composites onto white. There is no crop, stretch, or photo-library lookup.
3. Each rendered image is written as an opaque SDR sRGB JPEG in the app-controlled `tmp/FitPhotosOutputs/` directory. Results use filenames such as `fit-4x5-01-<UUID>.jpeg`, the JPEG UTType (`public.jpeg`), and file-backed `IntentFile` values. A distinct random component prevents collisions between runs; it is not an asset identifier.
4. The action returns the output array in input order. Each returned file has `removedOnCompletion = true` so Shortcuts can remove it after the workflow completes. The app does not delete successful files as soon as `perform()` returns. It removes the current invocation's partial outputs when processing fails or is cancelled before handoff; it does not sweep outputs from another invocation based on age.
5. The next Shortcuts action decides what happens to those files. **Share** can pass them to another app. The app has no automatic save step.

Successful temporary outputs must remain readable through downstream actions. Actual Shortcuts cleanup timing, cancellations after handoff, and behavior under low storage require the device protocol in [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md). The operating system also controls the availability of temporary storage; the app does not promise indefinite retention or a persistent export archive. See Apple's [IntentFile](https://developer.apple.com/documentation/appintents/intentfile) and [removedOnCompletion](https://developer.apple.com/documentation/appintents/intentfile/removedoncompletion) contracts.

The earlier `PhotoLibraryEditor`, `PreparedEdit`, PhotoKit adjustment model, edit view model, and **Test Photo Asset Identity** probe are removed from the production project. There is no `PHAsset` recovery, filename/date/hash matching, Photos database access, or PhotoKit write path. [FEASIBILITY.md](FEASIBILITY.md) records the product decision.

## Build a Shortcut

For selection inside Shortcuts:

1. Launch **Fit Photos** once after installation.
2. Open Shortcuts and create a shortcut named **Fit and Share**.
3. Add **Select Photos** and turn **Select Multiple** on.
4. Add **Fit Photos to 4:5**. Set its **Photos** input to the output of Select Photos.
5. Add **Share** and set its input to the processed files returned by Fit Photos to 4:5.
6. Run the shortcut and choose 1–20 images. Choose the destination in the share sheet.

For the Photos share sheet:

1. Create a second shortcut named **Fit Shared Photos**.
2. In its details, enable **Show in Share Sheet** and accept **Images**.
3. Add **Fit Photos to 4:5**, with **Photos** set to **Shortcut Input**.
4. Add **Share**, using the action's returned processed files.
5. In Photos select 1–20 images, tap Share, and choose **Fit Shared Photos**. Use More if necessary to find the shortcut.

Do not add **Save to Photo Album** if you want to avoid adding library copies. Fit itself never saves to Photos, but a destination you explicitly choose in Share can save or upload a copy. Shortcuts or another app may request its own permissions or use the network to fetch or share the input. Fit's rendering has no network dependency.

The app screen contains **Fit Photos**, “Use Fit Photos to 4:5 from the Shortcuts app.”, and **Open Shortcuts**. No in-app photo picker, account, subscription, backend, analytics, or Instagram API is included.

## Image behavior and limits

Version 1 accepts supported JPEG, HEIC, and PNG still-image representations. The file's actual decoded format is checked; an extension alone is insufficient. Unsupported or damaged input fails the operation instead of returning a silent partial batch. Live Photo motion, video, RAW processing, and animated images are outside the MVP. If Shortcuts supplies a supported still representation of another source, Fit processes only that supplied still image.

For an upright input of `w × h`, the minimum integer 4:5 canvas uses `n = max(ceil(w/4), ceil(h/5))` and dimensions `4n × 5n`. The maximum canvas is **4096 × 5120**. Larger images scale down proportionally; smaller images are not enlarged. Every successful input produces a returned JPEG, including an input that is already 4:5.

| Upright input | Output canvas | Result |
|---|---|---|
| 4032 × 3024 landscape | 4032 × 5040 | White padding above and below |
| 3024 × 4032 portrait | 3228 × 4035 | White padding chiefly at the sides |
| 4000 × 4000 square | 4000 × 5000 | White padding above and below |
| 8064 × 6048 landscape | 4096 × 5120 | Proportional downscale to fit |

Transparent pixels are flattened onto white. Output is a lossy JPEG, not a byte-preserving or lossless copy. HDR, wide-gamut fidelity, depth, original metadata, and the original compression format are not preserved in the output. Existing edits and crops already baked into the file supplied by Shortcuts remain part of that input; Fit cannot restore pixels absent from it. The source file and original library asset remain untouched.

Sequential processing and bounded decode dimensions limit simultaneous image work; they do not prove a particular peak-memory figure. One maximum-size RGBA canvas alone is about 80 MiB, before decoder, render, and encoder buffers. The 20-image and 48 MP cases require physical memory profiling.

## Permissions and privacy

There are no Photos read/write or add-only usage descriptions, no PhotoKit authorization requests, and no Photos library writes in the production app. It reads only image representations supplied to the intent and writes its own temporary outputs. A Photos access request from **Select Photos** belongs to Shortcuts, not Fit.

All rendering occurs on the device. There are no third-party dependencies, network calls, accounts, analytics, subscriptions, or tracking. Temporary files can contain personal images until workflow cleanup; they are not persistent app-managed albums.

## macOS CI and later iPhone validation

`.github/workflows/ios-ci.yml` builds the unsigned Simulator app on GitHub's `macos-26` runner with Xcode **26.6**, boots a compatible iPhone Simulator, and runs the entire shared-scheme test suite. Logs and available `.xcresult` bundles are preserved even on failure. CI needs no Apple Developer Program credentials, certificates, App Store Connect account, or paid Apple secrets. See the [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

Tests cover geometry, raster output, EXIF orientation, transparency, multiple inputs and the limit, output metadata, and temporary-file behavior. Direct XCTest intent execution does not establish live Shortcuts discovery or transfer. AppIntentsTesting is unavailable in the selected Xcode 26.6 / iOS 26.5 configuration; see [APP_INTENTS_TESTING.md](APP_INTENTS_TESTING.md).

To reproduce CI later on a Mac with the selected Xcode and Simulator runtime:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
export FITPHOTO_EXPECTED_XCODE_VERSION=26.6
bash Scripts/validate-on-mac.sh
```

The project is `FitPhotoSpike.xcodeproj` and the shared scheme is `FitPhotoSpike`. For a physical iPhone, configure local device signing and install the same tested commit through Xcode or another authorized installation route. The unsigned Simulator product is not an installable iPhone IPA.

All physical results remain **NOT RUN**. Follow [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md) for the exact two Shortcut workflows, output-lifetime observations, originals/no-duplicate checks, and memory tests; use [DEVICE_TESTS.md](DEVICE_TESTS.md) as the supplemental acceptance matrix.
