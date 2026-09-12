# Windows â†’ GitHub Actions setup

Run these commands in PowerShell. Publish the **FitPhotoSpike folder itself** as the repository root: `.github` and `FitPhotoSpike.xcodeproj` must be directly under that root. The commands create a private repository named `fit-photo-spike`; choose another unused name if needed. No GitHub repository has been created by this workspace. The internal project name is retained for the temporary-output MVP. If you already uploaded an earlier version yourself, use the update commands in section 5 instead of initializing or creating another repository.

## 1. Install and authenticate GitHub CLI

Git is already installed. Check GitHub CLI:

```powershell
git --version
gh --version
```

If `gh` is not recognized, install it:

```powershell
winget install --id GitHub.cli --exact --source winget
```

Close and reopen PowerShell after installation, then authenticate. The browser/device authentication is interactive; do not paste a token into a script or this repository.

```powershell
gh auth login --hostname github.com --git-protocol https --web --scopes workflow
gh auth setup-git
gh auth status
```

If `winget` is unavailable, use the Windows installer linked from [GitHub CLI installation](https://github.com/cli/cli#installation). Authentication instructions: [gh auth login](https://cli.github.com/manual/gh_auth_login).

## 2. Initialize Git and create the first commit

Use the delivered folder below. If you extracted the ZIP elsewhere, substitute that extracted `FitPhotoSpike` folder in `Set-Location`.

```powershell
Set-Location -LiteralPath 'C:\Users\yesim\Documents\Codex\2026-09-10\files-pasted-by-the-user-i\outputs\FitPhotoSpike'
git init -b main
git config user.name (Read-Host 'Your Git commit author name')
git config user.email (Read-Host 'Your Git email or GitHub noreply email')
git add .
git diff --cached --stat
git commit -m 'Add temporary-output Fit Photos MVP and simulator CI'
```

The author settings apply only to this repository. Use the email shown in your GitHub email settings if you want commits associated with your account. `.gitignore` excludes Xcode output and common signing files; do not add personal photos or credentials. These initialization commands assume a new repository, as requested.

## 3. Create the GitHub repository and push

```powershell
$repoName = 'fit-photo-spike'
gh repo create $repoName --private --source . --remote origin
git push -u origin main
gh repo view --web
```

`gh repo create` must succeed before pushing. If that repository name already exists, select a different unused name and rerun the create command. The first push automatically starts **iOS Simulator validation**. No Apple Developer Program membership, signing certificates, App Store Connect access, or paid Apple secrets are used. GitHub Actions usage is subject to your account's included minutes and billing settings, particularly for private repositories and macOS runners. See [gh repo create](https://cli.github.com/manual/gh_repo_create) and [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

## 4. Trigger another run and inspect results

Run this after the first push has succeeded; it deliberately starts a new manual run. To watch the automatically triggered first run instead, omit the first command.

```powershell
gh workflow run ios-ci.yml --ref main
gh run list --workflow ios-ci.yml --limit 5
$runId = Read-Host 'Enter the run ID from the list'
gh run watch $runId --exit-status
gh run view $runId --web
```

The run may take a few seconds to appear; repeat `gh run list` if needed. `gh run watch --exit-status` returns a nonzero exit code for a failed run. Wait for completion before downloading the final artifacts:

```powershell
gh run view $runId --log-failed
gh run download $runId --dir "ci-artifacts\run-$runId"
```

If the first command has no output for a successful run, that is normal. Artifacts include toolchain information, build/test logs, Simulator selection/boot diagnostics, and available `.xcresult` bundles, retained for 14 days. No result bundle exists if the run failed before Xcode created it. Read the plain-text logs on Windows; open result bundles in Xcode later if needed. Definitions: [gh workflow run](https://cli.github.com/manual/gh_workflow_run), [gh run watch](https://cli.github.com/manual/gh_run_watch), [gh run download](https://cli.github.com/manual/gh_run_download).

## 5. Make changes and rerun

```powershell
git add .
git commit -m 'Fix simulator validation findings'
git push
gh run list --workflow ios-ci.yml --limit 5
```

Record the successful run URL, commit SHA, selected Xcode/SDK/Simulator, actual test counts, and every skipped test in [VALIDATION.md](VALIDATION.md). Do not change a pending entry to passed until the corresponding evidence exists. The workflow runs on pushes, pull requests, and manual dispatch. If Actions is disabled in your account/repository, enable it in GitHub's Actions settings before dispatching.

## What the workflow executes

`.github/workflows/ios-ci.yml` selects GitHub's `macos-26` runner and `/Applications/Xcode_26.6.app/Contents/Developer`. The runner script also runs Scripts/verify_project.py to check source membership and the no-Photos-access policy. It verifies that exact Xcode version and fails clearly if it is no longer installed. It builds the app with `xcodebuild build`, chooses or creates an available compatible iPhone Simulator, boots it and waits for readiness, then executes `xcodebuild test` for the entire shared `FitPhotoSpike` scheme. There are no test-name filters. Both commands set `CODE_SIGNING_ALLOWED=NO` and target the Simulator.

To reproduce on a Mac with that Xcode installed:

```bash
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
export FITPHOTO_EXPECTED_XCODE_VERSION=26.6
bash Scripts/validate-on-mac.sh
```

An optional Simulator UDID can be passed as the script's sole argument; `--help` describes it. The script stores each run separately under `ValidationRuns/`. No-argument invocation performs the build and tests automatically. On a GitHub-hosted runner the workflow uploads logs/results even on failure, when available. A hosted runner image can change; if the pinned Xcode disappears, review the official [macOS runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) and update the pin and validation record together.

AppIntentsTesting requires the newer Xcode 27/iOS 27 toolchain; it is unavailable in this selected configuration. The 3 direct intent XCTest methods are included in the ordinary 30-method suite. They do not validate Shortcuts routing. See [APP_INTENTS_TESTING.md](APP_INTENTS_TESTING.md). Physical iPhone validation remains **NOT RUN** regardless of CI outcome.
