# Feasibility decision — temporary image outputs

**Product decision: use file input → on-device rendering → temporary file output.** The MVP will not identify or modify the originating Photos assets. This decision replaces the earlier in-place PhotoKit editing and identity-probe plans; no future asset-identity experiment is a prerequisite for this product.

The implemented AppIntent is **Fit Photos to 4:5**. It accepts 1–20 image `IntentFile` values and returns processed JPEG `IntentFile` values to the next Shortcuts action. It fits each complete supplied image into a white 4:5 canvas, preserving proportions and orientation. Outputs are temporary; the user chooses their destination through a downstream action such as Share.

## Why this architecture

A generic `IntentFile` is a file representation with public file properties. Its documented file URL is not a contractual reference to an originating `PHAsset`. The previous spike found no reliable documented source-asset identifier in this file-input contract. The product therefore does not attempt identity recovery, search by filename/date/hash, or use private APIs. This is a conclusion about the chosen file contract, not a claim about every present or future App Intents type. [Apple IntentFile documentation](https://developer.apple.com/documentation/appintents/intentfile), [fileURL](https://developer.apple.com/documentation/appintents/intentfile/fileurl).

The user has explicitly chosen temporary outputs even if a separate asset-based architecture could be built. The repository no longer pursues that route. Old production PhotoKit authorization, content-editing, adjustment, picker/editor UI, and identity-report code are removed. The app contains no Photos usage descriptions or automatic library-save behavior.

## File lifecycle

Each invocation owns its temporary output files. Files are rendered sequentially and returned in the same order as the inputs. File-backed `IntentFile` values describe JPEG content with matching filenames and UTTypes. `removedOnCompletion` is set to true so the Shortcuts completion lifecycle can remove returned files.

Successful files must outlive the intent method so downstream actions can read them. The app does not immediately delete them, does not delete another invocation's output, and does not run an age-based purge that could race a paused shortcut. A processing failure or cancellation before successful handoff removes that invocation's partial outputs and returns an error, rather than handing back an incomplete batch.

These mechanisms use public APIs, but source review cannot establish Shortcuts' exact retention and cleanup behavior on an iPhone. Completion, cancelled sharing, paused workflows, and interrupted runs are explicit device tests. Temporary output is not a promise of durable storage. See [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md).

## Product boundary

- Fit performs no Photos reads through PhotoKit and no library writes. Shortcuts supplies the readable file representation.
- Fit never adds photos automatically. A later user-selected Share destination or Save action may intentionally create a copy.
- Rendering is on device. Selecting an iCloud image or sharing through another app can involve system or destination networking outside Fit.
- Output is an opaque SDR sRGB JPEG with white padding. There is no crop or stretch, but conversion is lossy and does not preserve all source metadata, HDR/depth information, or motion.
- A supported still representation supplied from a Live Photo or already-edited photo is processed as supplied. The app neither accesses other resources nor restores prior edits.

## Validation status

The Windows workspace can inspect sources and run portable validation scripts. It cannot compile UIKit, Core Image, ImageIO, or App Intents for iOS. The GitHub Actions macOS Simulator workflow is retained; actual build and Swift-test results remain pending until that workflow runs. AppIntentsTesting requires a newer SDK/runtime than the selected stable CI configuration; direct intent XCTest coverage is a separate layer.

Physical iPhone validation is **NOT RUN**. The required evidence now concerns Shortcut input/output transfer, geometry and orientation, temporary-file lifetime, unchanged originals, and 20-image memory behavior. There is no PhotoKit edit/revert gate because the MVP no longer edits Photos assets. [VALIDATION.md](VALIDATION.md) records actual checks; [README.md](README.md) describes the production architecture and Shortcut setup.
