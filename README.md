# Fit Photos

A native SwiftUI iPhone app for fitting complete photos onto white canvases. V1 adds an independent app flow while preserving the existing **Fit Photos to 4:5** Shortcuts action.

This review package was made from the user-supplied `FitPhotos-Astra-Source.zip`. It contains no Git history. Its commit has **not** been verified against GitHub. Signing, release scripts, and GitHub Actions workflows are preserved from that ZIP; this handoff does not publish a build.

## Standalone app

1. Open Fit Photos and tap **Select Photos**.
2. Select 1–20 still images in Apple's native picker, in the desired order.
3. Choose a ratio, then tap **Convert Photos** (the button includes the batch count).
4. Review the result grid or open a preview and move between images. **Save All** and **Share** remain below the scrolling results; reviewing each image is optional.

| Ratio | Canvas pixels | Description |
| --- | --- | --- |
| 4:5 (default) | 1080 × 1350 | Portrait |
| 3:4 | 1080 × 1440 | Classic portrait |
| 9:16 | 1080 × 1920 | Tall portrait |
| 1:1 | 1080 × 1080 | Square |

Every output is a JPEG containing the entire image, with white padding where needed, correct orientation, and no stretching or cropping. Ratios describe the output canvas; they are not a promise of suitability for every social network surface.

**Save All** creates new Photos items only after an explicit tap and add-only system authorization. Selection does not request full-library access. Originals are never replaced or edited. **Share** gives the entire converted batch to the native iOS share sheet; the chosen destination decides which item types and batch sizes it supports. Instagram is not guaranteed to appear. Nothing is saved automatically.

## Processing and file lifetime

The app and AppIntent share the ImageIO/Core Image renderer and geometry logic. The standalone app requests the four fixed pixel sizes above. The existing AppIntent keeps its original source-dependent 4:5 sizing and input/output contract; it does not silently switch to 1080 × 1350.

Processing is sequential and operates on local files. It does not hold twenty full-resolution decoded images at once. Supported source encodings are JPEG, HEIC, and PNG still images. A picker/provider item can still be unsupported; unsupported or failed conversion is reported with its batch position rather than silently omitted. Transparent regions render over white. Animated images and videos are not supported as V1 inputs.

The app begins importing after the picker sheet has dismissed and copies each provider file into an owned temporary session before that file-provider callback returns. A replacement selection is staged separately: cancellation or an import failure keeps the previous selection available. A successful import replaces the old batch; conversion errors discard partial outputs and keep the selected inputs for retry.

App sessions live in `tmp/FitPhotosAppSessions/batch-<UUID>/`, separate from Shortcuts output directories. Save All and Share retain results for another action. **Change Ratio** discards the current converted files and returns to the retained inputs; conversion is required again. Confirming **New Batch** removes the previous app session before opening the picker. Abandoned app batch directories are cleaned once per app-process launch before a new UI session exists, and an active model cleans up its session when released. Cleanup does not run merely because the app backgrounds or a share sheet closes. The operating system may also reclaim temporary storage. Save or share results you want to keep; unsaved sessions are not restored after relaunch. See `V1_DEVICE_TEST.md` for lifetime and interruption checks.

The AppIntent continues returning image `IntentFile` values with JPEG filenames/types and `removedOnCompletion = true`, so the next action can consume them and Shortcuts can clean them up when the workflow finishes. No cleanup operation is allowed to sweep another in-progress Shortcut's files.

## Shortcuts remains independent

An existing working Shortcut can continue using:

```text
Select Photos (select multiple)
→ Fit Photos to 4:5 (Photos = Select Photos output)
→ Share (entire Fit Photos output)
```

A Photos share-sheet Shortcut may use:

```text
Receive Images from Share Sheet
→ Get Images from Input (Shortcut Input)
→ Fit Photos to 4:5 (Photos = Images from the preceding action)
→ Share (entire Fit Photos output)
```

The explicit image-extraction step is a configuration to test where direct `Shortcut Input` produced an empty array. It is not a proven fix for every Share Sheet transport issue. The AppIntent returns files; the separate Shortcut **Share** action presents sharing. The standalone app does not require installation of either Shortcut.

## Privacy and permissions

- Processing stays on the iPhone; no account, backend, analytics, advertisements, or photo upload is added.
- The system photo picker supplies only the items the user selects. Fit Photos does not request full-library read permission.
- `NSPhotoLibraryAddUsageDescription` supports explicit **Save All**. PhotoKit authorization is `.addOnly` and limited to the saver component.
- No source `PHAsset` lookup, matching, editing, deleting, or identifier recovery is used.
- Sharing is user-directed through iOS; a chosen destination app may send items according to that app's behavior.
- An iCloud-only source may require Apple's picker to download it. Offline processing does not mean the app can read an original that is not on the device. Download test fixtures before testing offline.

## Validation and review

From the extracted project root on Windows:

```powershell
python -B Scripts/verify_project.py
python -B -m unittest discover -s Scripts/Tests -p test_v1_project_policy.py -v
```

These check source/project structure and synthetic policy cases; they do **not** compile Swift or validate iOS behavior. With full Xcode on a Mac, use the existing command:

```sh
bash Scripts/validate-on-mac.sh
```

The existing `.github/workflows/ios-ci.yml` runs that simulator build and full shared-scheme test suite. Its inherited summary text still describes the earlier no-Photos-access app; V1's explicit add-only Save All is described here. No workflow was edited to change that informational text.

Read `VALIDATION.md` for the evidence boundary and `V1_DEVICE_TEST.md` for acceptance tests. Native compilation and the new standalone iPhone flow remain pending unless separately recorded as passed. Review and copy these source changes into the original checkout; do not infer a Git commit or release from this ZIP.
