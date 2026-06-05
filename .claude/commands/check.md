---
description: Build then run tests (Debug, no signing) exactly as CI does
argument-hint: "[-only-testing:Target/Suite] (optional)"
allowed-tools: Bash
---

Build the app, and if the build succeeds, run the tests — using the exact
incantation CI uses (Debug, code signing off). Pipe through `xcbeautify` when
it is installed, otherwise run raw.

Steps:

1. If `project.yml` is newer than the `.xcodeproj`, run `xcodegen generate` first.
2. Build:

   ```bash
   set -o pipefail
   xcodebuild -project Speech2Text.xcodeproj -scheme Speech2Text \
     -configuration Debug -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build \
     | { command -v xcbeautify >/dev/null && xcbeautify || cat; }
   ```

3. **Only if the build passed**, run tests. If `$ARGUMENTS` is non-empty, pass it
   through verbatim (e.g. `-only-testing:Speech2TextTests/TranscriptionLanguageTests`):

   ```bash
   set -o pipefail
   xcodebuild -project Speech2Text.xcodeproj -scheme Speech2Text \
     -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test $ARGUMENTS \
     | { command -v xcbeautify >/dev/null && xcbeautify || cat; }
   ```

4. If either step fails, surface the relevant failing output and fix the **code,
   not the test** (per AGENTS.md). Do not weaken or delete a failing test to make
   it pass. Stop and report once build + tests are green.
