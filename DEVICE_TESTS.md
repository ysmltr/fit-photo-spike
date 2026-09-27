# Supplemental iPhone resource checks

**Status: NOT RUN for this changed build.** First complete [V1_DEVICE_TEST.md](V1_DEVICE_TEST.md). These checks supplement the functional cases with memory and file-lifetime observations.

## Repeated batches

- [ ] Run one image, then 20 large local images, across all four ratios. Record duration, output count/dimensions, and peak resident memory.
- [ ] Repeat conversion → preview → Share → dismissal → New Batch several times. Inspect Xcode's memory graph and Instruments Allocations/Leaks for accumulating models, tasks, thumbnails, or share controllers.
- [ ] Cancel during import and conversion. Wait for cancellation to settle; retry a clean batch. Check that no incomplete output is presented and no abandoned worker continues indefinitely.
- [ ] Cancel a replacement selection and an import failure. The previous batch stays usable until replacement succeeds or New Batch is confirmed.
- [ ] Change Ratio after a result. Old converted files are discarded; selected inputs remain for reconversion.
- [ ] Confirm New Batch. Previous inputs/outputs are released once no worker or sharing presentation needs them. Cancelling the new picker leaves no previous result retained by model state.

## Temporary files and consumers

- [ ] With authorized Xcode container inspection available, compare `tmp/FitPhotosAppSessions/` before and after a completed batch, cancelled work, confirmed New Batch, and process relaunch. Record cleanup as unverified if the container is unavailable.
- [ ] Share retains all outputs through activity completion/dismissal. Cancelling sharing keeps displayed results available to share or save again.
- [ ] Background/foreground during sharing and Save All does not remove files while a system consumer needs them.
- [ ] A submitted Photos save transaction settles without files being removed underneath it. No overlapping transaction is started by repeated taps.
- [ ] Kill/relaunch leaves the app usable and removes only abandoned owned batch folders. Saved Photos/Files copies and source images remain unchanged.
- [ ] Unsupported input and storage failure discard partial outputs and report an actionable error. Repeated failed batches do not accumulate unexplained owned files.

## Record observations

Use locally created fixtures, including a large camera still and a 20-item batch on a smaller-memory device. Session cleanup is attempted in `AppSessionFiles.deinit` after the last owner releases it; abandoned owned batch cleanup is attempted once per process launch. Deletion is best effort, so record actual outcomes and retained consumers instead of assuming every removal succeeds. Do not assert a mathematical guarantee of zero leaks: record observed allocations, deallocation, memory pressure, file lifetime, and remaining uncertainty. Review compiler/static-analysis concurrency and retain-cycle diagnostics where Xcode exposes them; record unresolved warnings.

| Date / tester | Build / iPhone / iOS | Case | Pass / fail / unavailable | Sanitized observation |
| --- | --- | --- | --- | --- |
| PENDING | PENDING | All | NOT RUN | None |
