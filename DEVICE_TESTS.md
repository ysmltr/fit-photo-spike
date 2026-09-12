# Supplemental iPhone acceptance matrix

**Every case is NOT RUN.** Start with [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md) for installation, exact Shortcuts, temporary-file observations, and evidence recording. This matrix covers temporary outputs only; no PhotoKit editor, identity lookup, or in-place edit/revert test belongs to the MVP.

## Images and output

- [ ] Portrait, landscape, square, panorama, and tall screenshot: complete image visible, centered, proportional, white padding, exactly 4:5.
- [ ] All eight EXIF orientations, including mirrored values: labeled edges/corners appear correctly without double rotation.
- [ ] Transparent PNG: transparent regions and canvas are white in the opaque JPEG.
- [ ] JPEG, HEIC, PNG, very small and already-4:5 inputs: each produces a valid JPEG with appropriate filename and `public.jpeg` type.
- [ ] Large images: proportional downscale within 4096×5120; small images are not enlarged.
- [ ] Previously edited/cropped representation: preserve supplied appearance, without claiming restoration of absent pixels.
- [ ] Animated, corrupt, unsupported, falsely named input: clear error with no partial batch.
- [ ] Live Photo input: record the still representation actually supplied; no motion output claim.

## Shortcuts and privacy

- [ ] Select Photos with Select Multiple → Fit Photos to 4:5 → Share.
- [ ] Photos share sheet accepting Images → Fit Photos to 4:5 → Share.
- [ ] Files input works without a Photos asset or library permission.
- [ ] App closed/open, first/repeated run, Share to Files and another installed app.
- [ ] Fit requests no PhotoKit permission; record separate Shortcuts/destination prompts.
- [ ] Originals unchanged; no automatic Photos additions or deletions.
- [ ] No network needed once files are supplied; distinguish iCloud retrieval/destination uploads from Fit.

## Batch and temporary files

- [ ] Multiple outputs preserve input order and have distinct valid JPEG filenames.
- [ ] Exactly 20 succeed; 21 and empty input are rejected appropriately.
- [ ] Wait before Share and app relaunch do not invalidate successful outputs.
- [ ] Successful files survive downstream reading; completion cleanup is observed rather than assumed.
- [ ] Cancel during processing, stop after handoff, and cancel Share: record cleanup for each lifecycle.
- [ ] Failure after an earlier render removes this invocation's partial output and returns no partial batch.
- [ ] Overlapping workflows, if supported: no collisions or deletion of another workflow's files.
- [ ] Repeated successful/failed runs: record accumulating scratch inputs or unexplained retained outputs as issues.
- [ ] Low storage/unavailable input: actionable error and recovery on a valid retry.

## Performance and UI

- [ ] 48 MP supported still and 20-image batch: record peak resident memory, time, sizes, and termination with Xcode/Instruments.
- [ ] Background/foreground and interrupted shortcut: no false success; record system execution limits.
- [ ] Title, instruction, and Open Shortcuts readable with large Dynamic Type and VoiceOver.
- [ ] Open Shortcuts works on each tested OS; report any opening failure.

| Tester / date | Device / iOS build | Commit / CI run | Case | Pass / fail / unavailable | Evidence |
|---|---|---|---|---|---|
| PENDING | PENDING | PENDING | All | NOT RUN | None |
