# Manual signed TestFlight upload

Status: prepared and checked with synthetic tests on Windows. A real Xcode
archive, signed export, Apple upload, Apple processing and physical-iPhone test
have **not** been performed by this implementation session.

The separate workflow is `.github/workflows/testflight-upload.yml`, displayed as
**Signed TestFlight upload** in GitHub Actions. It runs only with
`workflow_dispatch` on the repository's default branch. The existing Simulator
workflow and unsigned device-build workflow are unchanged.

## Files and project settings

New release files:

- `.github/workflows/testflight-upload.yml`
- `Scripts/testflight_release.py` — private workspace, keychain, archive, export,
  verification, upload and cleanup.
- `Scripts/testflight_signing.py` — profile/certificate/entitlement policy.
- `Scripts/testflight_connect.py` — read-only Apple API queries and build numbering.
- `Scripts/Tests/test_testflight_*.py` — synthetic tests without credentials.
- `TESTFLIGHT_UPLOAD.md`
- `FitPhotoSpike/Assets.xcassets/` — opaque 1024×1024 app icon; Xcode generates the
  required device sizes. App Store distribution requires an app icon.

The only existing project changes add the icon catalog to the app's resources
and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for Debug and Release.
`Scripts/verify_project.py` now recognizes asset catalog directory references.
No Swift implementation, test cases, entitlements, permissions or capabilities
were changed. The app remains a temporary-output AppIntent with no Photos writes.

The existing shared scheme is `FitPhotoSpike`. Before these changes the app
target used automatic signing, an empty team, marketing version `0.1.0`, and
build number `1`. These settings and its existing bundle identifier remain in
`FitPhotoSpike.xcodeproj/project.pbxproj` unchanged.

On the runner, the driver reads the resolved **Release** settings using
`xcodebuild -showBuildSettings -json`. If a project team is configured, it must
match the certificate and profile. Otherwise, the expected team is derived from
the valid Apple Distribution certificate's subject OU and checked against the
profile's single TeamIdentifier. A missing/ambiguous team stops the release.
The non-secret value needed to resolve that failure is your **Apple Developer
Team ID**; it is not an API key ID or an App Store Connect issuer ID.

`DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE=Manual`, the distribution certificate
fingerprint, profile UUID, and `CURRENT_PROJECT_VERSION` are passed as command-line
build settings **only in `Scripts/testflight_release.py`**. They are not written
back to the project. Marketing version is preserved. An incorrect bundle/App
Store Connect app/profile combination fails validation; it is never auto-renamed.

## Required GitHub Secrets

Use the existing secrets with these exact names. Do not paste their values into
workflow YAML, documentation, issues, commit messages or logs.

```text
APP_STORE_CONNECT_KEY_ID
APP_STORE_CONNECT_ISSUER_ID
APP_STORE_CONNECT_PRIVATE_KEY
IOS_DISTRIBUTION_P12_BASE64
IOS_DISTRIBUTION_P12_PASSWORD
IOS_PROVISIONING_PROFILE_BASE64
```

The API key must be a team key with access to this app, build metadata (including
pending uploads), validation and upload. It is used through the API key/issuer
authentication flow, never an Apple Account password. Use only the account role
and app access needed for these operations. An authorization failure stops the
workflow; there is no fallback to unchecked build numbering.

The P12 must include the private key and a currently valid **Apple Distribution**
identity. The profile must be an explicit **App Store Connect distribution**
profile for the exact app bundle identifier, contain this certificate, and have
valid dates. Development, Ad Hoc, enterprise and wildcard App ID profiles fail.

## Run from GitHub or Windows

1. Merge these files into the repository's default branch. Preserve any existing
   account-specific project settings when merging the icon resource changes.
2. In **Settings → Environments**, create or configure `testflight`. Restrict its
   deployment branches to the default branch. Required reviewers are optional.
   The existing repository secrets work; no additional secret name is required.
3. Leave Actions debug logging disabled. The preparation step refuses
   `RUNNER_DEBUG=1` before the step that receives signing secrets.
4. Open **Actions → Signed TestFlight upload → Run workflow**. Select the default
   branch and click **Run workflow**.
5. The first job runs release-helper tests and the unchanged existing Simulator
   build/test script. Only a successful first job permits the signing job to run
   on a fresh GitHub-hosted macOS runner.

The toolchain is explicitly pinned to Xcode 26.6 on `macos-26`, matching the
existing CI. It does not silently choose a beta or a different Xcode if that
version becomes unavailable. Update the pin deliberately when Apple's upload
requirements or the hosted runner image changes.

Optional PowerShell commands, from your existing local Git repository:

```powershell
git add .github/workflows/testflight-upload.yml Scripts/testflight_release.py Scripts/testflight_signing.py Scripts/testflight_connect.py Scripts/Tests TESTFLIGHT_UPLOAD.md FitPhotoSpike/Assets.xcassets FitPhotoSpike.xcodeproj/project.pbxproj Scripts/verify_project.py
git diff --cached --stat
git commit -m "Add isolated manual signed TestFlight upload"
git push
gh workflow run testflight-upload.yml
gh run list --workflow testflight-upload.yml --limit 5
$runId = Read-Host 'Enter the new run ID from the list'
gh run watch $runId --exit-status
gh run view $runId --web
```

If needed, install/authenticate GitHub CLI from PowerShell:

```powershell
winget install --id GitHub.cli --exact
# Open a new PowerShell window after installation.
gh auth login --hostname github.com --git-protocol https --web
```

Do not use `gh secret list` output or authentication diagnostics as project
artifacts. This workflow does not need an App Store Connect password, App Review
credentials, extra signing secrets or a saved runner keychain.

## What runs before upload

1. Create a mode-0700 temporary directory and a fresh randomly passworded keychain.
   Import the P12 nonextractably, authorize `/usr/bin/codesign` and Apple's signing
   tool partitions, and use only the temporary keychain plus the system keychain
   for public certificate-chain lookup. Never import into or use the login/default
   keychain. Record and later restore the original user keychain search list.
2. Decode and inspect the profile with `security cms`. Match the exact App ID,
   team, distribution flags, validity dates and certificate DER. Install the
   profile with restrictive permissions under Xcode's standard
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles` directory. Never
   overwrite a preexisting profile.
3. Create the API private key only in the private temporary directory. Query
   App Store Connect for the matching app and existing/pending build numbers.
4. Archive the existing scheme in **Release**, `-sdk iphoneos`,
   `-destination generic/platform=iOS`, with manual signing enabled. Export with
   `method=app-store-connect`, manual signing, the exact certificate/profile, and
   `manageAppVersionAndBuildNumber=false`.
5. Inspect **both** the archive's app and exported IPA's app. Require the expected
   bundle ID, unchanged marketing version, chosen build number, valid code
   signature, exact distribution certificate, matching embedded profile and
   minimal permitted entitlements. Inspect Mach-O CPU and platform load commands
   to require **arm64 iPhoneOS**, rejecting an arm64 Simulator binary. Require
   generated App Intents metadata for **Fit Photos to 4:5**.
6. Run `xcrun altool --validate-app`, recheck build-number availability, then run
   `xcrun altool --upload-app`. Both use API key authentication and structured
   output. Nonzero exit, malformed response or reported errors stop the workflow.
   There is no automatic upload retry.

These checks reuse the existing device metadata/Mach-O inspection functions;
the unsigned-device validator itself is not used on a signed app.

## Build-number uniqueness

The candidate is `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT.0`. The driver reads all
existing builds and in-flight uploads for the current marketing version. If the
candidate is not greater than their maximum, it increments that maximum within
Apple's numeric component limits. It prints only:

```text
Marketing version: X
Build number: Y
```

Retries use a new attempt component and also query Apple again. The release
workflow is serialized without canceling the active release. Invalid counters,
unreadable API data, nonnumeric existing versions or exhausted number ranges stop
the release. Supported CI counter limits are run number 9999 and attempt 99;
existing build components are bounded to four/two/two digits.

App Store Connect has no atomic build-number reservation. An unrelated uploader
can still race this workflow between the final check and upload. A conflict
stops the job; inspect App Store Connect before starting a fresh manual run.

## Security and retention

- Signing secrets are scoped only to the release step, never to the Simulator
  job, pull requests, checkout step or cleanup step. Raw secret variables are
  removed from the environment before subprocesses run.
- Checkout is pinned to a full commit SHA, does not persist Git credentials, and
  receives only `contents: read`. No third-party signing action or Python package
  handles credentials. Protect the default branch and review changes to release
  scripts/workflows before merging; repository code executes with signing access.
- The shell explicitly disables tracing. Private files use mode 0600. JWTs are
  short-lived, generated in memory, and never printed or saved.
- Apple API requests validate HTTPS, reject redirects and external pagination
  hosts, and do not send bearer tokens through environment-configured proxies.
- Tool command lines, raw Apple responses, certificate/profile/entitlement data
  and raw build logs are never printed. Only fixed failure codes, concise check
  results and version numbers reach GitHub logs. This intentionally limits build
  diagnostics to avoid accidentally exposing signing data.
- Cleanup runs in the driver's `finally` block on success, failure and handled
  cancellation, and again in the workflow's `always()` step. Tool process groups
  are stopped on timeout/cancellation before cleanup. The copied profile,
  temporary keychain, private keys, P12, decoded data, archive, IPA and raw logs
  are deleted; the original search list is restored. A cleanup failure fails the
  job and the always step retries. A hard runner termination can prevent cleanup
  code from running; the GitHub-hosted runner is ephemeral. Do not move this
  workflow to a persistent/self-hosted runner without a separate cleanup design.
- **No artifacts or caches are uploaded by this workflow**, including signed IPA,
  raw logs, certificates, profiles or keychains. The validated IPA is sent only
  to Apple's upload service. Existing workflows retain their own existing policy.

## Success, failure and credential rotation

Success ends with **Upload accepted. Apple processing and physical-iPhone testing
remain pending.** The summary records marketing/build versions and completed
local artifact checks. Upload acceptance is not successful Apple processing.
Open **App Store Connect → My Apps → your app → TestFlight → iOS** and wait for
processing. Check Apple's processing messages, export-compliance questions and
build status. This workflow does not submit App Review, release the app, add
external testers, or opt builds into any new tester groups. Existing App Store
Connect group settings may automatically distribute processed builds.

For a signing/profile mismatch, stop and compare the app target's Release bundle
ID against the registered App ID, App Store Connect app, certificate team and
profile. Regenerate an **App Store Connect** profile containing the active
distribution certificate, then replace the appropriate existing GitHub secret.
Never weaken the validators or switch to development/ad-hoc signing to bypass
the error. `CERTIFICATE_TEAM_ID_UNAVAILABLE` needs the non-secret Apple Developer
Team ID and a valid distribution certificate; no guessed team is accepted.

For `ASC_REQUEST_FAILED`/`ASC_APP_NOT_UNIQUE`, confirm the key role/app access,
active agreements and exact bundle registration. For an Apple validation/upload
failure, inspect the build's status and Apple's account messages. If an upload
may already have arrived, check its build number before retrying. Do not enable
debug logs or upload raw signing logs to troubleshoot.

To rotate the API key, create a replacement with the required minimum role/app
access in **Users and Access → Integrations → App Store Connect API**. Replace
the three existing API secrets together, verify a controlled manual run, then
revoke the old key in App Store Connect. If compromised, revoke it immediately
instead of waiting for a successful replacement upload.

To rotate the distribution certificate, create a replacement Apple Distribution
certificate with its matching private key, securely export a password-protected
P12, and regenerate the App Store Connect profile with that certificate. Replace
the P12, P12-password and profile secrets together. Verify the replacement run
before revoking the old certificate, unless compromise requires immediate
revocation. Check other apps/workflows using that certificate first.

To replace an expired profile, generate/download a current App Store Connect
distribution profile for the same explicit App ID and active certificate, and
replace `IOS_PROVISIONING_PROFILE_BASE64`. The next run validates its dates,
certificate, bundle and team again. Do not commit any downloaded signing file.

## Remaining validation

Synthetic helper tests and project/workflow checks run on Windows. They do not
exercise Xcode, Security.framework, real credentials or Apple's servers. The
first GitHub run must prove Simulator tests, actual certificate import, archive,
App Store export, signed-app checks and upload all work with your account.

Local validation on 2026-09-18: **116 synthetic helper tests passed**. All three
workflow YAML files passed static checks. Project references, XML/plists and
source policy checks passed. SHA-256 comparisons confirmed both existing
workflow files are byte-for-byte unchanged; the only changed baseline files are
the icon's project wiring and the asset-catalog-aware project verifier. All 30
existing native XCTest methods remain present; Windows did not execute them.

To repeat the new helper tests from the repository root:

```powershell
python -m unittest discover -s Scripts/Tests -p 'test_testflight_*.py'
python Scripts/verify_project.py
```

After Apple processing succeeds, install through TestFlight on a real iPhone,
open the app once, then perform the existing `PHYSICAL_DEVICE_TEST.md` checklist.
Verify Shortcuts discovers **Fit Photos to 4:5**, accepts Select Photos and Share
Sheet inputs, returns 1–20 correctly oriented 4:5 outputs to Share, and does not
write duplicate photos. Output lifetime/cleanup, large-image memory behavior and
cross-app sharing remain physical-device tests. **Physical validation is pending.**

## References

- [Apple: Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple: App icons in asset catalogs](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Apple: Xcode build settings](https://developer.apple.com/documentation/xcode/build-settings-reference)
- [Apple: Xcode 16 release notes — profile location](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)
- [Apple: App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi)
- [Apple: API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [GitHub: macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
