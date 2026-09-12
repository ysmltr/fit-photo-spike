# Physical iPhone validation — NOT RUN

**Stage 2: PENDING. No physical iPhone test has passed.** A passing Simulator suite would not prove Shortcuts discovery, share-sheet transfer, downstream access to temporary files, actual cleanup, or acceptable memory use on an iPhone. This protocol tests the temporary-output MVP. It does not perform PhotoKit editing or asset-identity recovery.

Use disposable fixtures and keep separate originals. If an operation cannot be performed on the available OS, record that limitation instead of substituting a different path and marking it passed.

## Prerequisites

1. Run Stage 1 in GitHub Actions first. Record the run URL, exact commit SHA, Xcode/SDK/Simulator versions, passed/failed tests, and skips in `VALIDATION.md`. A skipped HEIC test is not HEIC validation.
2. Later obtain a Mac with Xcode and an authorized physical-device installation route. Open the same commit's `FitPhotoSpike.xcodeproj`, select the `FitPhotoSpike` scheme, configure a development team and unique bundle identifier, connect/trust the iPhone, enable Developer Mode if requested, and run on the phone. Record signing-only changes. The unsigned Simulator build from CI cannot be installed as an iPhone app.
3. Record tester/date, device model, exact iOS version/build, Xcode/SDK, and commit. Test iOS 18 separately if maintaining the minimum-OS support claim, plus a current supported OS when available. Results apply only to tested combinations.
4. Prepare local JPEG portrait and landscape, square PNG, very tall screenshot, transparent PNG, HEIC, and large 48 MP still-image fixtures. Include clear TOP/BOTTOM/LEFT/RIGHT labels and four distinctive corners. Prepare all eight EXIF orientation variants, including mirrored values. Retain copies in Files or on a computer; do not upload personal fixtures to CI.
5. Record source appearance/dimensions and Photos library/album counts before testing. Use a stable test library to reduce unrelated sync changes. Fit must have no Photos usage description or PhotoKit permission request.

## A. Select Photos → Fit → Share

1. Launch **Fit Photos**. Verify the screen says **Fit Photos**, “Use Fit Photos to 4:5 from the Shortcuts app.”, and **Open Shortcuts**. Tap Open Shortcuts and confirm it opens Shortcuts. Opening Fit must not produce a Photos permission prompt.
2. Create **Fit and Share** in Shortcuts. Add **Select Photos**, enable **Select Multiple**, then add **Fit Photos to 4:5**. Set **Photos** to the selected photos. Add **Share**, with its input set to the processed files returned by Fit.
3. Run it with one landscape JPEG. In Share choose **Save to Files** and a dedicated test folder. This explicit user-selected export is for inspection; do not choose Save Image or add Save to Photo Album.
4. Inspect the JPEG using Files/Quick Look or transfer it to a computer for pixel dimensions. Confirm exactly 4:5 (`width × 5 == height × 4`), white padding, all input corners/edges visible, correct orientation, and no stretch. The longest output side must not exceed 5120 pixels. Large inputs may be proportionally reduced within the documented 4096×5120 canvas cap.
5. Record the `.jpeg` filename and JPEG content type. With access to the returned value in Xcode, check the `IntentFile` type is `public.jpeg` and `removedOnCompletion` is true. An extension alone is not format evidence; the exported file must decode as JPEG.
6. Repeat with portrait, square, very tall screenshot, transparent PNG, HEIC, and already-4:5 fixtures. Already-4:5 input must still return a JPEG. Transparent areas must be white. Test the labeled EXIF variants; each must appear as expected, including the intended mirror orientation, with no double rotation.
7. Run with three distinguishable images in a known input order. Verify three separate outputs, no missing/repeated items, and the same order as inputs delivered to Fit. Selection UI ordering is system behavior; record the order actually supplied if it differs from tap order.
8. Inspect Photos after each run. Source appearance/dimensions must remain unchanged, with no new or removed library items caused by Fit. Record all prompts. Shortcuts may request its own input access; Fit must not request Photos write access.
9. Repeat while Fit is closed, then open. Share to another installed app as well as Files. Confirm the destination receives processed images. Any upload or intentional save by that chosen destination is outside Fit's rendering operation.

## B. Photos share sheet → Fit → Share

1. Create **Fit Shared Photos**. Enable **Show in Share Sheet** in shortcut details and accept **Images**.
2. Add **Fit Photos to 4:5**, with **Photos = Shortcut Input**, followed by **Share** using the processed output.
3. In Photos select one JPEG, Share → Fit Shared Photos, then inspect the export as in A. Repeat with several images and HEIC/PNG. Record whether Photos converts the source representation; Fit processes only the file it receives.
4. Repeat from Files with supported images. This path must work without a Photos asset or library permission.
5. If the shortcut/action is missing, cannot accept images, or loses files before Share, record the error and OS behavior as a failure. Do not substitute direct intent unit tests as a pass.

## C. Temporary-file lifetime and cleanup

1. Duplicate Fit and Share as **Fit Lifetime Test**. Insert **Wait 60 seconds** between Fit and Share. Set Share explicitly to Fit's processed output variable rather than the Wait action's output.
2. Run with three images. During the wait, leave Shortcuts, open Fit, and return. Verify Share can still read all three results afterward. Repeat with a longer pause appropriate to the device. Successful files must not be deleted when the intent returns or Fit opens again.
3. In Xcode's Devices and Simulators window, select the connected phone and installed app and use **Download Container** when available. Inspect `tmp/FitPhotosOutputs/` in a snapshot taken during the wait, and a fresh snapshot after downstream sharing and shortcut completion. Record filenames, existence, and times. If the OS/tool cannot expose the container, record cleanup as unverified.
4. Confirm successful output values are marked `removedOnCompletion = true`; observe whether Shortcuts removes their backing files after completion. Record actual cleanup timing. Persistent output is an issue to investigate, not a pass inferred from the property. Copies deliberately exported to Files should remain readable as separate user exports.
5. Cancel Share and separately stop the shortcut during Wait. Record whether the workflow completes/cancels, when temporary files disappear, and whether another invocation's outputs stay usable. Do not manually delete active files during observation.
6. Run a valid image followed by corrupt/unsupported input. Confirm an error, no partial successful batch returned to Share, and removal of this invocation's new output/scratch files. Repeat cancellation during rendering when possible. The next clean run must work.
7. Attempt overlapping invocations through supported Shortcuts entry points. If iOS serializes them, record concurrency as unverified. Otherwise pause one after rendering and run/cancel the other: filenames must not collide, and the first run's files must remain readable. Cleanup must not remove another invocation's output.

## D. Limit, memory, and interruption

1. Supply exactly 20 supported images, including large still images. Confirm 20 outputs and retained order, then inspect each result. Measure peak memory with Xcode/Instruments Allocations or VM Tracker, duration, and disk use. Record the device and input dimensions. Sequential source code does not prove freedom from memory-pressure termination.
2. Run a 48 MP supported still and a 20-image batch containing large inputs. Observe background/foreground transitions and whether Shortcuts/the app is terminated. Record memory warnings, errors, and cleanup.
3. Supply 21 images. Expect a maximum-20 error before rendering, no returned images, and no new outputs for that rejected invocation. Empty input must produce an input-required error; if Shortcuts prevents invocation, record its behavior separately from the automated empty-input test.
4. Use corrupt JPEG bytes, animated input, and a non-image renamed `.jpeg`. Expect rejection with no partial batch or Photos changes. A supported still representation delivered from a Live Photo is acceptable; motion is not an output.
5. Test unavailable input and insufficient storage in an appropriate test environment; do not destabilize a personal phone to force failure. Expect an actionable error, no false success, and recovery on a valid retry. For an iCloud-only input, record whether Shortcuts downloads it before invoking Fit; Fit has no PhotoKit/iCloud download path.
6. Complete [DEVICE_TESTS.md](DEVICE_TESTS.md), including repeated runs and UI accessibility.

## Evidence record

| Evidence | Status / observation |
|---|---|
| Stage 1 CI URL / SHA / versions / results / skips | PENDING |
| Tester / date / iPhone / exact iOS build / Xcode | PENDING |
| UI and Open Shortcuts | NOT RUN |
| A: Select Photos → Fit → Share, single/multiple | NOT RUN |
| B: Photos share sheet and Files input | NOT RUN |
| Shapes / transparency / EXIF / filenames / types / order | NOT RUN |
| No Fit Photos prompt or library mutation | NOT RUN |
| C: downstream access and completion cleanup | NOT RUN |
| C: cancellation, errors, concurrency | NOT RUN |
| D: 20 success / 21 rejection / empty input | NOT RUN |
| D: 48 MP / 20-image peak memory / time / disk | NOT RUN |
| D: unsupported input, storage, lifecycle | NOT RUN |
| Physical MVP acceptance | **NO — pending evidence** |

Keep personal images and temporary paths private. Add sanitized observations/run references to `VALIDATION.md`. Never mark native or physical checks passed from source inspection alone.
