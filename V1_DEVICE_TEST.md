# V1 physical-iPhone acceptance test

**Status: NOT RUN for the new standalone implementation.** Do not mark this document passed based on source inspection, simulator results, or the previously tested Shortcuts build.

Use non-personal, locally downloaded test pictures with visible numbers and colored marks at all four edges: portrait, landscape, square, very tall, rotated/orientation-tagged JPEG, HEIC, and transparent PNG. Keep a 20-item numbered set. Include an unsupported still format if your picker exposes one. No photos or credentials need to be sent to the developer.

Record the installed app version/build, iPhone model, iOS version, and actual PASS/FAIL/NOT RUN beside each check. Inspect output pixel dimensions locally (for example with a user-created image-details Shortcut after saving); the app itself must not need a Shortcut to operate.

## Short acceptance path

1. Start without any Fit Photos user-created Shortcut installed. Open the app directly. Tap **Select Photos**, choose three numbered pictures in a deliberately different order, and finish selection. There must be no full-library permission prompt and no second selection dialog.
2. Leave **4:5** selected, convert, and inspect the result grid and full previews before saving. Move between images in the preview; confirm Share and Save All remain available without opening each result. Verify selection order, all four edge marks, correct orientation, white padding, and no stretching/cropping. Nothing should have appeared in Photos merely because you selected, converted, or previewed.
3. Tap **Save All**. Authorize adding images when iOS asks. Verify exactly three new images and inspect their 1080 × 1350 dimensions. Confirm the original three are unchanged. Repeat with fresh conversion for 3:4 (1080 × 1440), 9:16 (1080 × 1920), and 1:1 (1080 × 1080).
4. From a three-image result, tap **Share** once. Confirm one native share sheet receives the entire batch. Choose **Save to Files** and verify all three JPEGs are readable. Users must not have to tap each preview to share it. Cancel the share sheet once and verify previews remain usable and no Photos copies were automatically made.
5. Repeat the standalone flow with one image and with 20 numbered images. Verify order, complete counts, and no crash. Try selecting a 21st image: the picker must enforce the 20-item limit; injected 21-item processing is covered by automated tests and must fail without partial results.
6. Retest the existing **Fit Photos to 4:5** Shortcut on this build with 20 ordinary pictures and a final **Share** action. Confirm 20 readable JPEG results, original source-dependent 4:5 sizing, and no automatic library writes. A deliberate separate Shortcut save action may create copies; it is not AppIntent behavior.

## Required negative and lifecycle checks

| Test | Expected result | Actual |
| --- | --- | --- |
| Cancel the picker with no selection | Return to a usable app; no conversion, permission request, or new Photos items. If replacing a selection, preserve the previous selection. | NOT RUN |
| Cancel importing/converting a large batch | Clear cancellation state; no partial success presented and no Photos writes. Start again successfully. | NOT RUN |
| Unsupported or unreadable item mixed with valid images | Explain which batch item failed. Do not silently omit it or present a partial batch as complete. | NOT RUN |
| Deny Save All permission | Explain denial; preserve previews and Share. Do not claim success or prompt for full-library read access. | NOT RUN |
| Grant add-only access later in Settings, then retry | Save All succeeds from retained results; verify exact output count and originals unchanged. | NOT RUN |
| Tap Save All repeatedly while busy / after success | No overlapping save transactions or accidental duplicate batch from an immediate repeated tap. Record the actual success state. | NOT RUN |
| Cancel Share, then Share again / Save All | All files remain readable while results are displayed. No automatic Photos copies. | NOT RUN |
| Share open while backgrounding / returning | No premature deletion of files being consumed; returning UI remains coherent. Destination behavior may vary. | NOT RUN |
| Replace a selection and cancel/fail while loading | Keep the previous selection intact. Do not mix partially imported new items into it. Retry successfully. | NOT RUN |
| Change Ratio after conversion | Remove converted results, retain the selected inputs, and return to ratio selection. Reconvert to obtain the newly selected pixel dimensions. Previously saved copies remain unchanged. | NOT RUN |
| New Batch | Cancel the confirmation to keep current results. Confirm it to clear the app's old inputs/results and open a new picker. Cancelling that new picker leaves an empty, usable app. Saved/shared copies remain. | NOT RUN |
| Kill/relaunch during a temporary session | Unsaved results are not restored; app starts usable. Cleanup targets abandoned app batch directories only and does not delete Shortcut outputs or saved Photos copies. Originals remain unchanged. | NOT RUN |
| Offline with local originals | Select, convert, preview, save, and local Files sharing work without an app server. iCloud-only originals are excluded from this check. | NOT RUN |
| 20 large camera photos on a smaller-memory iPhone | No memory termination or prolonged frozen UI; cancellation remains usable. Record model and behavior rather than declaring memory safety from code alone. | NOT RUN |
| Transparent PNG and all orientation cases | White under transparency; all output pixels at selected size; image upright and complete. | NOT RUN |
| Photos share-sheet Shortcut, if used | Test Receive Images → Get Images from Input → Fit Photos → Share with explicit variables. Record actual counts; do not infer this transport path from the standalone picker. | NOT RUN |

## Accessibility and small-screen checks

Use the smallest available iPhone layout and a large Accessibility Dynamic Type setting. All ratio options, progress/cancel controls, preview navigation, Save All, and Share must remain reachable without clipped actionable text. With VoiceOver, verify image order/count, selected ratio, progress, error and save state, and distinct button names. Verify adequate contrast in Light and Dark appearance and that primary actions have comfortable tap targets.

Sharing to another app is a separate destination compatibility check. Test a destination that accepts a multi-image batch; record limitations without assuming Instagram must appear or accept every count. No direct-posting workaround is part of V1.

## Result record

- Installed version/build: NOT RECORDED
- iPhone / iOS: NOT RECORDED
- Standalone flow: NOT RUN
- Four ratios and pixel dimensions: NOT RUN
- Permission denial and retry: NOT RUN
- Full-batch Save All / Share: NOT RUN
- Existing Shortcut compatibility: NOT RUN on the V1 build
- Cancellation, unsupported files, originals unchanged: NOT RUN
- Memory and accessibility: NOT RUN
- Overall V1 physical validation: **PENDING**
