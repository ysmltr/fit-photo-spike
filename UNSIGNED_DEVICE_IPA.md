# Unsigned physical-iPhone IPA — preparation only

The existing Simulator workflow is retained. Earlier passing builds do not establish validation of this changed source. This independent device build creates an **unsigned iPhoneOS IPA**, intended to be re-signed locally and installed on the user's own iPhone. It does not run tests on an iPhone, enroll in the Apple Developer Program, or install anything.

## Run and download

1. Review and apply the source changes and listed deletions to the existing repository. Its root must directly contain `.github` and `FitPhotoSpike.xcodeproj`. The existing device workflow and helper scripts are already included. Commit/push and workflow dispatch are separate owner actions; this handoff performs none of them.
2. In GitHub open the repository → **Actions** → **Unsigned iPhone IPA** → **Run workflow**. Choose the branch containing these files and click **Run workflow**. There are no inputs or secrets. A newly added manually dispatched workflow generally needs to be on the default branch before the button appears.
3. Wait for **Build and verify unsigned iPhoneOS IPA** to succeed. Open that run's summary and download the artifact named **FitPhotoSpike-unsigned-ipa**.
4. Extract GitHub's downloaded artifact ZIP on Windows. Locate **FitPhotoSpike-unsigned.ipa**, `FitPhotoSpike-unsigned.ipa.sha256`, and `device-build-verification.json` inside it; GitHub may preserve an `Artifacts` subfolder. The outer artifact ZIP is not the IPA. The IPA itself contains `Payload/FitPhotoSpike.app`.
5. Inspect the JSON report and the `executable-file`, `executable-architectures`, `executable-platform`, `device-verification`, and `ipa-verification` logs. The report must show passed verification, `arm64`, and the iOS device platform. Only then use the IPA with a local re-signing/install tool.

After separately reviewing and publishing the source, use GitHub CLI from the existing repository folder:

```powershell
gh workflow run ios-device-build.yml --ref main
gh run list --workflow ios-device-build.yml --limit 5
$runId = Read-Host 'Enter the unsigned device workflow run ID'
gh run watch $runId --exit-status
gh run download $runId --name FitPhotoSpike-unsigned-ipa --dir device-download
Get-ChildItem -LiteralPath device-download -Recurse -Filter FitPhotoSpike-unsigned.ipa
```

Substitute the actual default branch for `main` when different. Install/authenticate GitHub CLI using [WINDOWS_SETUP.md](WINDOWS_SETUP.md) if needed; do not initialize or create another repository when one already exists. After a failed build, inspect its separate **ios-device-build-diagnostics-RUNID-ATTEMPT** artifact. No IPA is uploaded if a verification step fails.

## What is verified by a successful run

The device workflow uses the same `macos-26` / Xcode 26.6 toolchain selection as the existing Simulator workflow, with its own dispatch and concurrency group. It invokes the existing project and shared scheme with:

```sh
xcodebuild build \
  -project FitPhotoSpike.xcodeproj -scheme FitPhotoSpike \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath <run-directory>/DerivedData \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

`CODE_SIGNING_ALLOWED=NO` disables the signing stage; the workflow does not add redundant signing identity/profile settings, export an archive, or change project build settings. No certificates, provisioning profiles, credentials, secrets, TestFlight, or App Store Connect are involved. It expects `Release-iphoneos/FitPhotoSpike.app`, never a Simulator build directory.

The script logs `file`, `lipo -archs`, and `vtool -show-build`. A Python checker validates the bundle's iPhoneOS platform and parses its Mach-O load commands: **arm64 plus the iOS device platform is required**. ARM64 Simulator binaries are explicitly rejected. The script also requires an unsigned code object and no embedded provisioning profile or bundle signature.

The app is copied intact into `Payload/FitPhotoSpike.app`, zipped as `FitPhotoSpike-unsigned.ipa`, and checked for correct layout, executable permissions, ZIP integrity, and byte-for-byte correspondence with every verified application file. The download contains a SHA-256 and JSON verification report. Artifacts are retained for 14 days; GitHub account Actions usage limits still apply.

## Re-signing and installation

An unsigned IPA cannot launch directly on a normal iPhone. A separate authorized re-signing/install process must produce a valid signature and matching provisioning profile for the account and device. This workflow does not install, configure, or authenticate a re-signing tool. Account limitations and profile expiry still apply; consult [Apple account information](https://developer.apple.com/help/account/basics/about-your-developer-account) and the selected tool's current documentation.

Preserve the bundle identifier where possible and keep the final profile, application identifier, and signature consistent. Do not replace the executable, inject changes, or strip normal resources. Complete the installation/trust steps and enable Developer Mode if iOS requests it. An expired profile or an app that cannot open is an installation issue, not successful app testing. Record the installation method, OS, launch outcome, and any identity changes without sharing credentials or signing logs. See [Apple TN2415](https://developer.apple.com/library/archive/technotes/tn2415/_index.html) for signing consistency.

## Evidence status

| Item | Status |
|---|---|
| Simulator validation of this changed source | NOT RUN in this Windows workspace |
| Unsigned device workflow execution | NOT RUN for this change |
| Real binary arm64 / iPhoneOS verification | PENDING workflow execution; mandatory before IPA artifact upload |
| IPA layout and packaged byte preservation | PENDING workflow execution |
| Local re-signing / installation | NOT RUN |
| Physical output, saving/sharing, cleanup, memory | NOT RUN |

After installation, follow [PHYSICAL_DEVICE_TEST.md](PHYSICAL_DEVICE_TEST.md). Creating the IPA is preparation for those tests, not a passing physical-device result.
