# Proposed store listing and review notes

Draft text for the owner to review and enter in App Store Connect. Nothing has been submitted. Confirm descriptions, screenshots, privacy answers, and reviewer instructions against the tested build before submitting.

## Description

Fit Photos — The whole photo. A better fit.

Fit complete photos into a new shape without cropping or stretching. Choose up to 20 photos, select 4:5, 3:4, 9:16, or 1:1, and preview your images on clean white canvases.

Save the whole batch as new copies in Photos, or share it using the iPhone's native share sheet. Your originals stay unchanged, and nothing is saved automatically.

Processing happens on your iPhone. No account is needed, and Fit Photos does not upload your photos or include analytics. Photo selection uses Apple's private picker; permission to add photos is requested only when you tap Save All.

## App Review Notes

Fit Photos is an iPhone app. No account or reviewer login is required.

To test: open the app, tap Select Photos, select 1–20 still images, choose a ratio, and tap Preview Photos to convert the selection. Inspect the Your Photos grid or open an individual preview; Previous and Next navigate the photos, and Done returns to the results. From the result screen, Share sends the complete batch to the native iOS share sheet. Save All requests add-only Photos authorization, then creates new copies. The original photos are not modified and no images are saved automatically.

The supported output ratios are 4:5, 3:4, 9:16, and 1:1. Processing is on-device and works offline with images already available locally. An iCloud-only image may require Apple's picker to download it first. Temporary, unsaved results are not restored after relaunch.

## Submission checklist

- Use current standalone app screenshots and instructions matching the tested build.
- Describe only photo selection, conversion, preview, explicit Save All, and native Share.
- Keep privacy answers consistent with no app data collection and selected/add-only photo access; do not claim that third-party sharing destinations never use a network.
- Keep marketing version `0.1.0`. Use the actual uploaded build chosen by the existing release workflow; the source default is not an upload reservation.
