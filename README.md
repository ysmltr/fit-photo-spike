# Fit Photos

The whole photo. A better fit.

Fit Photos is a native SwiftUI iPhone app. Select up to 20 still images, pick a size, then place each photo on its canvas: resize, move, Fit or Fill, and choose a background color, a color picked from the photo, or a blurred copy of the photo. Nothing is cropped unless the user zooms in.

## Use the app

1. Tap **Choose photos** and select 1–20 images in the desired order.
2. **Pick a size.** Each card shows the first photo in that shape. Instagram's sizes come first; more sizes follow.
3. **Edit.** Pinch to resize and drag to move (the photo snaps to the center, Fit and Fill). **Position** has Fit, Fill, a size slider and reset. **Background** has *From photo* (touch and drag a loupe, lift to pick), *Blur*, *Custom* (the system color picker) and twelve preset colors. With **Apply to all** on, Fit, Fill and background changes go to every photo; pinch, drag and the slider always adjust only the current photo. Swipe beside the canvas or tap the strip to move between photos.
4. **Save.** Every photo is rendered at full size, then **Save all** adds new copies to Photos or **Share** sends the batch through the iOS share sheet.

| Size | Group | Canvas pixels |
| --- | --- | --- |
| Portrait 4:5 (default) | Instagram | 1080 × 1350 |
| Square 1:1 | Instagram | 1080 × 1080 |
| Landscape 1.91:1 | Instagram | 1080 × 566 |
| Story · Reels 9:16 | Instagram | 1080 × 1920 |
| Classic 3:4 | More sizes | 1080 × 1440 |
| Pinterest 2:3 | More sizes | 1080 × 1620 |
| Widescreen 16:9 | More sizes | 1920 × 1080 |

Every output is an opaque sRGB JPEG with correct orientation. The editor and the export share one placement model (`PhotoEdit`, `PlacementGeometry`), so the canvas shows exactly what is saved. Transparent source regions show the chosen background. Supported inputs are still images that iOS can decode, including JPEG, HEIC/HEIF, PNG, WebP, AVIF, TIFF, BMP, and RAW/DNG. Animated images (including GIF) and videos are unsupported. During import, a photo that can't be loaded or decoded is skipped instead of failing the whole selection; an alert names the skipped picker positions and the remaining photos continue. The photo limit is `AppBatchProcessor.maximumImageCount` (20, Instagram's carousel maximum). The app processes the representation supplied by the picker; it does not preserve motion, depth, HDR, or every source metadata field.

## Design

The look is called *Light Table*: a cool, quiet surface (`Theme.table`) so the photos stay the most colorful thing on screen, SF Pro Expanded for titles, SF Mono for counts and sizes, and one red grease-pencil ring (`MarkerRing`) that draws itself around the current choice. All colors adapt to light and dark mode. The app is portrait-only on iPhone.

## Privacy and permissions

- Processing takes place on the iPhone. There is no account, backend, analytics, advertising, or app photo upload.
- Apple's picker supplies only selected items. Fit Photos does not request full-library read access.
- **Save all** requests add-only authorization and creates new Photos items only after an explicit tap. Originals are never replaced, edited, or deleted. Nothing is saved automatically.
- **Share** passes the converted files to the user's chosen destination. Destination apps decide which formats and batch sizes they support and may use their own network services.
- An iCloud-only source may need to download through Apple's picker. Download test images first when checking offline operation.
- The only things stored between launches are the last size and background choice and a count of saved batches (`EditorPreferences`, in `UserDefaults`), declared in `PrivacyInfo.xcprivacy`.
- **Feedback** (start screen) opens the user's own email app with a draft to the support address, including the app version, iOS version and device model; nothing is sent automatically. Rating and sharing links appear once `FeedbackLinks.appStoreID` is set. After the 3rd and 10th saved batch the app asks iOS for the standard App Store rating prompt, which iOS may or may not show.

## Processing and file lifetime

One sequential, file-backed processing path serves the app. The model keeps file URLs rather than an entire batch of full-resolution decoded images. Import starts after the picker closes and copies provider files while their callbacks still permit access. A replacement selection is staged separately, so cancellation or import failure keeps the previous selection. Failed conversion removes partial results and keeps inputs for retry.

Each batch owns `tmp/FitPhotosAppSessions/batch-<UUID>/`. Inputs and outputs remain available for preview, saving, and sharing. Opening the save screen renders the current edits; results are reused until a size or edit changes, then rendered again. On the save screen, **New batch** followed by **Choose new photos** releases the model's previous batch and opens the picker. Active work and sharing retain files they still need. When the last owner releases `AppSessionFiles`, its `deinit` attempts to remove the session. Once per process launch, before a new batch exists, cleanup attempts to remove abandoned owned batch directories. File deletion is best effort; failure, process termination, or system consumers can affect observed timing. Temporary results are not restored after relaunch and may also be reclaimed by iOS. Save or share results you want to keep.

## Project and validation

The existing project and scheme names remain `FitPhotoSpike`. The native target is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), marketing version `2.0`. The stored project build is `10.1.0`; the existing TestFlight workflow calculates the actual release build from GitHub counters and Apple's build records at run time.

From the extracted source root on Windows:

```powershell
python -B Scripts/verify_project.py
python -B -m unittest discover -s Scripts/Tests -p 'test_*.py'
```

These are static checks and synthetic Python tests, not a Swift compilation or an iPhone test. On a Mac with the project's pinned Xcode:

```sh
bash Scripts/validate-on-mac.sh
```

The existing `.github/workflows/ios-ci.yml` builds and tests the shared scheme. See [VALIDATION.md](VALIDATION.md), [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md), and [V1_DEVICE_TEST.md](V1_DEVICE_TEST.md) for the evidence boundary and manual acceptance checks. The source ZIP contains no Git history or credentials; it does not establish a remote commit match or publish a build.
