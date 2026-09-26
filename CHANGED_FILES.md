# Source review handoff

This package contains the standalone Fit Photos iPhone app. Its flow is ordered selection of 1–20 still images, one of four ratios, conversion, preview, explicit Save All, and native Share. The complete file-by-file change and deletion inventory accompanies the ZIP separately.

The source keeps marketing version `0.1.0`, stored project build `10.1.0`, and iPhone device family `1`. The existing release workflow selects its upload build dynamically. Bundle identity, photo permissions, signing checks, secret isolation, cleanup, and release behavior are preserved.

Read [README.md](README.md) for the architecture, [VALIDATION.md](VALIDATION.md) for reproducible checks, and [V1_DEVICE_TEST.md](V1_DEVICE_TEST.md) for pending physical acceptance. Windows validation cannot establish a successful native build, device behavior, or absence of runtime memory leaks.

Extract into a separate folder and compare with your original checkout. Apply the reviewed changes and listed deletions together; copying only additions cannot remove obsolete source files. Preserve the original `.git` directory and unrelated local changes. No credentials or generated signed artifacts are included. No commit, push, workflow dispatch, TestFlight upload, or App Store submission has been performed for this handoff.
