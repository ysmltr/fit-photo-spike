# Validation

This review copy preserves the standalone app's four ratios, ordered 1–20 selection, preview, explicit Save All, and native Share. The iPhone target and marketing version `0.1.0` remain. The project build stays `10.1.0`; the release driver still calculates a new upload build at run time. No commit, push, workflow run, upload, or submission is part of this handoff.

## Evidence boundary

| Check | Status for this review copy |
| --- | --- |
| Project references, source membership, XML/plists, and source policy | PASS on Windows: 82 project objects; 15 app Swift files and 8 test Swift files included exactly once. |
| Synthetic Python helper and policy regressions | PASS: 204 tests, 0 failures, 0 errors, 0 skips. No real credentials, photos, or Apple API calls were used. |
| Shell syntax | PASS for `Scripts/validate-on-mac.sh` and `Scripts/build-unsigned-device.sh`. |
| Native app build and Swift XCTest execution | NOT RUN in this Windows workspace; Xcode and the iOS SDK are unavailable. 48 XCTest methods are present, including 6 new lifetime checks; none were executed here. |
| Existing Simulator workflow | Retained; no run triggered for this change. A prior passing run does not establish that this copy builds. |
| Signed archive / exported IPA / Apple validation | NOT RUN for this change. Existing signing checks and dynamic build numbering remain. |
| Compiled app/archive resource inspection | NOT RUN on Windows; no native application artifact was generated. |
| Current standalone iPhone behavior | PENDING on the changed build, even where earlier builds were tested. |
| Runtime memory, cancellation, and file lifetime | Source audit and applicable synthetic tests are partial evidence. Device/Instruments checks remain PENDING. |

The portable results above were recorded for this review on 2026-09-26. An executed Python test, an inspected native test method, and a passed native XCTest are different evidence. Do not count methods present in source as executed tests or mark skipped cases passed.

## Reproduce portable checks

From the project root on Windows:

```powershell
python -B Scripts/verify_project.py
python -B -m unittest discover -s Scripts/Tests -p 'test_*.py'
```

The verifier checks project integrity and restricted photo-access policy. PhotoKit access is confined to `Platform/PhotoLibrarySaver.swift`: add-only authorization and creation of new photo resources. The picker supplies selected files; original-asset lookup and editing are not part of the app. Static guardrails do not replace observing permission prompts or checking unchanged originals.

With Bash available, check shell syntax:

```sh
bash -n Scripts/validate-on-mac.sh
bash -n Scripts/build-unsigned-device.sh
```

## Native validation

On a Mac with the toolchain pinned by the project:

```sh
bash Scripts/validate-on-mac.sh
```

The driver builds for an iPhone Simulator and runs the complete shared-scheme test suite. Inspect `.xcresult` for actual execution, failures, and skips. Record the source revision, toolchain, runtime, and test counts. Review compiler concurrency/ownership warnings instead of suppressing them.

Before release, verify the generated app's `UIDeviceFamily` contains only `1`, check the archive's resources, and perform [V1_DEVICE_TEST.md](V1_DEVICE_TEST.md). Test supported minimum and current iOS versions where available. iPhone-only native targeting does not promise that iOS prevents every iPad compatibility-mode installation.

Use Xcode Instruments Allocations/Leaks and a memory graph on repeated 20-image batches, cancellation, Save All, share dismissal, and New Batch. Check that a previous batch's files and decoded thumbnails are released when their last user ends. File deletion is best effort and iOS controls process termination; source inspection does not guarantee zero leaks or prove physical cleanup.

## Record real results

| Source revision / installed build | Toolchain / device | Check | Result | Date / evidence |
| --- | --- | --- | --- | --- |
| NOT RECORDED | NOT RECORDED | Native build and tests | NOT RUN | PENDING |
| NOT RECORDED | NOT RECORDED | Physical acceptance and memory | NOT RUN | PENDING |

Keep personal photos, credentials, private paths, and raw signing logs out of reports. The signed release workflow retains its no-artifact-upload policy; unsigned Simulator/device diagnostics are separate workflows.
