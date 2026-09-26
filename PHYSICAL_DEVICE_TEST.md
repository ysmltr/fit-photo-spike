# Physical iPhone validation

**Status: PENDING for this changed build.** A passing Simulator suite does not establish real-device permission behavior, full-batch sharing/saving, memory use, or temporary-file cleanup. Earlier installation or processing observations apply only to the earlier tested build.

## Prepare

1. Validate this source with the existing Simulator workflow or `bash Scripts/validate-on-mac.sh`. Record source revision, Xcode/SDK/runtime, executed tests, failures, and skips in [VALIDATION.md](VALIDATION.md).
2. Install the reviewed build on your own iPhone through the existing authorized TestFlight or Xcode development route. Keep the registered bundle identifier and signing setup. The Simulator app cannot be installed as an iPhone app. The optional unsigned-device workflow only prepares an artifact for separate authorized re-signing; it is not a physical test.
3. Record installed marketing/build versions, tester/date, model, and exact iOS version. Test the supported minimum iOS version separately where available. Confirm the generated app declares `UIDeviceFamily = [1]`; native iPhone targeting can still allow iPad compatibility behavior.
4. Prepare disposable local fixtures with visible numbering and distinctive edges/corners. Include JPEG, HEIC, PNG, transparent PNG, portrait, landscape, square, tall screenshots, all EXIF orientations, and a 20-item set. Record original appearance and dimensions without uploading the images.
5. Selection must use the system picker without requesting full-library access. Only explicit **Save All** may request add-only Photos authorization. Record all permission prompts and the before/after Photos counts.

## Execute

Follow [V1_DEVICE_TEST.md](V1_DEVICE_TEST.md) for the exact selection → ratio → conversion → preview → Save All / Share sequence, failures, cancellation, and accessibility. Complete [DEVICE_TESTS.md](DEVICE_TESTS.md) for resource/memory observations.

Record outcomes instead of assuming success when a test cannot be performed. Keep originals unchanged and saved/shared copies separate from temporary app files. iCloud-only sources and destination-app network behavior are separate from the app's offline rendering.

## Evidence

| Evidence | Status |
| --- | --- |
| Reviewed source revision and native CI result | PENDING |
| Installed version/build, device, iOS, tester/date | PENDING |
| All four ratios, orientation, order, 1 and 20 images | NOT RUN |
| Preview, full-batch Share, explicit Save All | NOT RUN |
| Add-only permissions, denial/retry, originals unchanged | NOT RUN |
| Cancellation, New Batch, temporary cleanup | NOT RUN |
| Memory, repeated batches, accessibility | NOT RUN |
| Physical acceptance | **PENDING** |

Keep personal images, credentials, private paths, and raw signing logs out of the evidence report. Passing source checks alone never marks these cases passed.
