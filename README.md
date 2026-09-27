# Fit Photos

The whole photo. A better fit.

Fit Photos is a native SwiftUI iPhone app. Select up to 20 still images, choose a ratio, and fit each complete photo onto a white canvas without cropping or stretching.

## Use the app

1. Tap **Select Photos** and select 1–20 images in the desired order.
2. Use **Edit selection** if needed, choose a ratio, then tap **Preview Photos** to convert the selection.
3. Review the **Your Photos** grid or open a preview. Use **Previous** and **Next** to move between photos, then **Done** to return. Opening each preview is optional.
4. From the result screen, tap **Save All** to add new copies to Photos, or **Share** to send the entire batch through the native iOS share sheet.

| Ratio | Canvas pixels |
| --- | --- |
| 4:5 (default) | 1080 × 1350 |
| 3:4 | 1080 × 1440 |
| 9:16 | 1080 × 1920 |
| 1:1 | 1080 × 1080 |

Every output is an opaque JPEG with correct orientation and white padding where needed. Transparent source regions render over white. Supported inputs are JPEG, HEIC, and PNG still images. Animated images and videos are unsupported. The app processes the representation supplied by the picker; it does not restore cropped pixels or preserve motion, depth, HDR, or every source metadata field.

## Privacy and permissions

- Processing takes place on the iPhone. There is no account, backend, analytics, advertising, or app photo upload.
- Apple's picker supplies only selected items. Fit Photos does not request full-library read access.
- **Save All** requests add-only authorization and creates new Photos items only after an explicit tap. Originals are never replaced, edited, or deleted. Nothing is saved automatically.
- **Share** passes the converted files to the user's chosen destination. Destination apps decide which formats and batch sizes they support and may use their own network services.
- An iCloud-only source may need to download through Apple's picker. Download test images first when checking offline operation.

## Processing and file lifetime

One sequential, file-backed processing path serves the app. The model keeps file URLs rather than an entire batch of full-resolution decoded images. Import starts after the picker closes and copies provider files while their callbacks still permit access. A replacement selection is staged separately, so cancellation or import failure keeps the previous selection. Failed conversion removes partial results and keeps inputs for retry.

Each batch owns `tmp/FitPhotosAppSessions/batch-<UUID>/`. Inputs and outputs remain available for preview, saving, and sharing. **Change Ratio** clears the converted results and keeps selected inputs for reconversion. On the result screen, **New Batch** followed by **Start New Batch** releases the model's previous batch and opens the picker. Active work and sharing retain files they still need. When the last owner releases `AppSessionFiles`, its `deinit` attempts to remove the session. Once per process launch, before a new batch exists, cleanup attempts to remove abandoned owned batch directories. File deletion is best effort; failure, process termination, or system consumers can affect observed timing. Temporary results are not restored after relaunch and may also be reclaimed by iOS. Save or share results you want to keep.

## Project and validation

The existing project and scheme names remain `FitPhotoSpike`. The native target is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), marketing version `0.1.0`. The stored project build is `10.1.0`; the existing TestFlight workflow calculates the actual release build from GitHub counters and Apple's build records at run time.

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
