# V1 physical-iPhone acceptance test

**Status: NOT RUN for this changed source.** Do not mark a case passed based only on source inspection, Simulator tests, or behavior observed on an earlier build. Complete the prerequisites in [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md).

Use non-personal, locally downloaded test pictures with visible numbers and colored marks at all four edges: portrait, landscape, square, very tall, rotated/orientation-tagged JPEG, HEIC, and transparent PNG. Keep a 20-item numbered set. Include an unsupported still format if the picker exposes one. No personal photos or credentials need to be sent to the developer.

Record installed version/build, iPhone model, iOS version, and actual PASS/FAIL/NOT RUN for each check. Inspect exported pixel dimensions in a local image inspector or on a computer.

## Main acceptance path

1. Open **Fit Photos** directly. Verify the existing welcome screen and **Select Photos** action. Select three numbered pictures in a deliberately different order. There must be no full-library permission prompt or second selection dialog. Use **Edit selection** once and verify the current selection remains if the picker is cancelled.
2. Leave **4:5** selected and tap **Preview Photos** to convert. Inspect the **Your Photos** grid and open a full preview before saving. Use **Previous** and **Next**, then **Done** to return to the results; confirm Share and Save All are available there without opening every result. Verify order, edge marks, orientation, white padding, and no stretching/cropping. Selection, conversion, and preview must not add items to Photos.
3. Tap **Save All**. Authorize adding images when iOS asks. Verify exactly three new images at 1080 × 1350 and confirm all originals are unchanged. Repeat with fresh conversion for **3:4** (1080 × 1440), **9:16** (1080 × 1920), and **1:1** (1080 × 1080).
4. From a three-image result, tap **Share** once. Confirm one native share sheet receives the entire batch. Choose **Save to Files** and verify all three JPEGs are readable, correctly sized, and ordered. Cancel sharing once; previews must remain usable, with no automatic Photos copies.
5. Repeat with one image and with 20 numbered images. Verify complete counts and order with all four ratios. Try selecting a 21st image: the picker must enforce its limit. Automated processing tests separately cover rejection of empty/oversized batches.

## Failure and lifecycle checks

| Test | Expected result | Actual |
| --- | --- | --- |
| Cancel an initial empty selection | Return to a usable app without conversion, Photos permission request, or new Photos items. | NOT RUN |
| Replace a selection and cancel/fail during import | Keep the previous selection. Do not mix partial new items into it; retry succeeds. | NOT RUN |
| Cancel importing/converting a large batch | No partial success or Photos writes. Cancellation settles before files are removed; retry succeeds. | NOT RUN |
| Unsupported/unreadable item among valid images | Identify the failed batch position. Do not silently omit it or present a partial batch as complete. | NOT RUN |
| Deny Save All permission | Explain denial; preserve previews and Share. No full-library access request or false success. | NOT RUN |
| Grant add-only access later, then retry | Save the whole batch once from retained outputs; originals remain unchanged. | NOT RUN |
| Repeated Save All taps while busy / after success | No overlapping transactions or duplicate batch from immediate repeated taps. | NOT RUN |
| Cancel Share, then Share again or Save All | Files remain readable while results are displayed; no automatic copies. | NOT RUN |
| Background and return while Share is open | No premature file deletion or inconsistent UI. Record destination limitations separately. | NOT RUN |
| Change Ratio after conversion | Remove old outputs, retain inputs, select another ratio and reconvert to the new dimensions. Saved copies remain unchanged. | NOT RUN |
| New Batch | On the results screen, tap New Batch. Cancel keeps the current batch; Start New Batch clears its inputs/results and opens the picker. Cancelling that picker leaves an empty usable app. | NOT RUN |
| Kill/relaunch during import, conversion, or preview | App starts usable; unsaved results are not restored. Launch cleanup attempts to remove abandoned owned batch folders without affecting originals or exported copies. Inspect actual cleanup rather than assuming success. | NOT RUN |
| Offline with local originals | Select, convert, preview, save, and local Files export work without an app server. | NOT RUN |
| 20 large camera photos on a smaller-memory iPhone | No termination or prolonged frozen UI; cancellation remains usable. Measure memory instead of inferring it from sequential code. | NOT RUN |
| Transparent PNG and all eight EXIF orientations | White under transparency, selected dimensions, upright complete content including mirrored cases. | NOT RUN |
| Low storage or unavailable source in a controlled test environment | Clear error, no partial batch, and recovery on valid retry. Do not destabilize a personal phone to force failure. | NOT RUN |

## Accessibility and resources

On the smallest available iPhone and large Accessibility Dynamic Type, check that photo selection, four ratios, progress/cancel controls, preview navigation, Save All, Share, and About are reachable without overlapping or clipped actionable text. Use VoiceOver to check order/count, ratio state, progress, errors, and button labels. Verify Light/Dark appearance and comfortable tap targets.

Complete [DEVICE_TESTS.md](DEVICE_TESTS.md) for repeated-batch resource and Instruments checks. Test another destination that supports multi-image sharing; record its actual limits. No destination is guaranteed to appear or accept all batch sizes.

## Result record

- Installed version/build: NOT RECORDED
- iPhone / iOS: NOT RECORDED
- Standalone selection and order: NOT RUN
- Four ratios / orientation / pixel dimensions: NOT RUN
- Permission denial and retry: NOT RUN
- Full-batch Save All / Share: NOT RUN
- Cancellation and unsupported files: NOT RUN
- Originals unchanged: NOT RUN
- Temporary/session cleanup and New Batch: NOT RUN
- Memory and accessibility: NOT RUN
- Overall physical validation: **PENDING**
