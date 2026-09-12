# App Intents validation and SDK availability

**AppIntentsTesting: NOT RUN and unavailable in the selected Xcode 26.6 / iOS 26.5 CI configuration.** The app targets iOS 18+. No empty conditional test or uncompiled test target is counted as coverage.

Apple's `IntentDefinitions` documentation lists iOS 27.0 and later. AppIntentsTesting was introduced at WWDC26 alongside the newer toolchain. It requires a supporting SDK/runtime even if the app retains an older deployment target. The current workflow keeps its explicit Xcode 26.6 selection. [IntentDefinitions availability](https://developer.apple.com/documentation/appintentstesting/intentdefinitions), [WWDC26 introduction](https://developer.apple.com/videos/play/wwdc2026/295/), [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes).

## Current test layer

XCTest uses synthetic inputs to exercise the temporary-output pipeline and direct execution of **Fit Photos to 4:5**. It covers returned JPEG files, metadata, multiple inputs, limits, and temporary-file behavior alongside geometry and rendering. Tests are included in the shared scheme for macOS Simulator CI; actual execution remains pending. The earlier identity-report intent and its tests are removed.

Direct calls can verify implementation and file existence when `perform()` completes. They cannot prove Shortcuts discovery, acceptance of every Photos/share-sheet representation, retention for downstream actions, or removal after the actual workflow. Asserting `removedOnCompletion` is true is not observing real cleanup. [IntentFile](https://developer.apple.com/documentation/appintents/intentfile), [removedOnCompletion](https://developer.apple.com/documentation/appintents/intentfile/removedoncompletion).

## If adopting a supporting SDK later

1. Select a runner with the required Xcode and a supported iOS Simulator runtime. Preserve explicit version checks and logs/results.
2. Add a separate **UI Testing** target. Apple requires AppIntentsTesting outside the app process, rather than the current hosted unit-test target.
3. Launch the app with `XCUIApplication`, create `IntentDefinitions(bundleIdentifier:)`, resolve production `FitPhotosIntent`, supply supported file parameters, and execute through the documented test APIs.
4. Verify output count/order, file metadata, content, and lifecycle properties. Add input-limit and unsupported-content cases. Include the new target in the shared scheme/CI only after it compiles and runs on that configuration.

See Apple's [Testing your App Intents code](https://developer.apple.com/documentation/appintentstesting/testing-your-app-intents-code). No speculative newer-SDK target is included.

[PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md) remains necessary even after a future AppIntentsTesting pass. Live Shortcuts transfer, sharing, completion cleanup, and device memory require their own evidence. All device results are **NOT RUN**.
