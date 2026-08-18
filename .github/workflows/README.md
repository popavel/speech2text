# GitHub Actions workflows

This folder holds the CI and Claude-automation workflows for Speech2Text. For the deeper
prose on how the automation fits together, see the **Automation helpers** section of
[AGENTS.md](../../AGENTS.md) and the local-automation [.claude/README.md](../../.claude/README.md)
(commands, agents, commit-guard hooks).

## Workflows

### Build / release CI

- [`build-and-test.yml`](build-and-test.yml) — reusable (`workflow_call`) job: build + test
  (Debug, signing off) on `macos-26`, pinned to Xcode 26.4.1.
- [`feature.yml`](feature.yml) — calls `build-and-test` on `feature/**` branches.
- [`main.yml`](main.yml) — calls `build-and-test` on pushes / PRs to `main`.
- [`release.yml`](release.yml) — calls `build-and-test` on `release/**` branches. Despite the
  name it publishes nothing; the distribution pipeline is `publish-release.yml` below.

Each of the three pipelines also calls `integration-whisperkit` and `ui-tests` (both
`needs: build-and-test`) — see below.

### Distribution

- [`publish-release.yml`](publish-release.yml) — the actual release pipeline, triggered by a
  `vX.Y.Z` tag. Gates on `build-and-test`, then: preflight (the tag must equal both versions in
  `project.yml`; `SUFeedURL`/`SUPublicEDKey` must be present) → import the Developer ID cert into
  a throwaway keychain → Release build with hardened runtime → verify the **built product**
  (versions, signature, runtime flag, unsandboxed, `Sparkle.framework` embedded, feed keys intact)
  → notarize + staple the app → ZIP it for Sparkle → build, sign, notarize and staple a DMG →
  `generate_appcast` (from the verified SwiftPM artifact store, never a download) → upload
  everything to a **draft** GitHub Release and flip it to published last.

  Known limitations: it needs `contents: write` and seven repository secrets
  (`DEVID_CERT_P12_BASE64`, `DEVID_CERT_PASSWORD`, `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_API_KEY_P8`, `SPARKLE_ED_PRIVATE_KEY`). Two `notarytool --wait` round-trips dominate the
  runtime, hence the 75-minute timeout. It refuses to overwrite an already-published release, but
  will delete and rebuild a stale *draft* so a failed run can be retried on the same tag. See
  AGENTS.md "Distribution & updates" for the runbook and the reasoning behind the guards.

  **The appcast carries exactly one item.** `artifacts/` starts empty each run and the previous
  feed is never fetched, so every release publishes a single-entry appcast. Two consequences,
  neither biting today: raising `LSMinimumSystemVersion` in a future release would leave users on
  the older OS with a feed containing nothing they can install (and so no update path), and
  Sparkle can't generate delta updates without the prior archives. Both are fixed the same way —
  download the previous release's archives into `artifacts/` before `generate_appcast` runs.

### Integration

- [`integration-whisperkit.yml`](integration-whisperkit.yml) — runs the end-to-end WhisperKit
  suite (downloads the tiny model and actually transcribes), not just a compile.

### UI tests

- [`ui-tests.yml`](ui-tests.yml) — reusable (`workflow_call`) job: runs the XCUITest UI suite,
  which launches the real app and drives it via accessibility identifiers. Unlike every other job
  it runs **signed** (no `CODE_SIGNING_ALLOWED=NO` — an unsigned runner is killed before it can
  attach). Called by feature/main/release with `needs: build-and-test`, and still dispatchable
  manually from the Actions tab.

### Claude automation

- [`claude.yml`](claude.yml) — the `@claude` bot. A cheap ubuntu **gate** job does the
  word-boundary mention match (excluding `@claude fix`, which the fixer owns) before the macOS
  job runs. Triggers on issue/PR comments, reviews, and opened issues.
- [`claude-code-review.yml`](claude-code-review.yml) — runs `/code-review --comment` on every PR
  push and posts inline findings; a new push cancels the stale in-flight review. **Skips
  bot-authored PRs (e.g. the weekly drift PR) — `claude-code-action` refuses bot actors, and a
  lockfile-only bump needs no static review.**
- [`claude-fix.yml`](claude-fix.yml) — the human-in-the-loop `@claude fix` loop: applies open
  review findings, builds + tests (green gate — a broken fix is not pushed), pushes, and
  re-reviews, all in one macOS run.
- [`dependency-drift.yml`](dependency-drift.yml) — weekly: drops `Package.resolved` and
  re-resolves the whole SwiftPM graph (WhisperKit, ViewInspector, transitives) to the latest
  release each `from:` allows, builds + tests, and opens a PR if still green or files an
  issue if upstream drift broke the build.

## Known limitations

These are accepted edges of the automation, recorded so maintainers aren't surprised by them.

| Caveat | Trigger → impact | Source |
| ------ | ---------------- | ------ |
| The `@claude` mention regex treats `-` as a word boundary, so handles like `@claude-bot` or `@claude-code` are matched as a mention of the bot. | A comment that mentions an unrelated `@claude-*` user (e.g. `@claude-bot please`) passes the gate, spinning up the privileged `macos-26` runner (with `contents: write`) even though no one summoned this bot — wasted compute, and an unintended privileged run on attacker-influenceable text. (`email@claude.com` correctly does **not** match, since `@` is preceded by an alphanumeric.) | [claude.yml:59](claude.yml#L59) |
| A `dependency-drift.yml` PR is opened by `github-actions[bot]` via `GITHUB_TOKEN`, which GitHub won't let trigger `on: push` workflows. | The PR's required checks (`build-and-test`, Integration, UI Tests) sit at "Expected — Waiting for status to be reported" forever; a manual `workflow_dispatch` does not reliably attach to the PR head. **Unblock:** push one **human** commit to the PR branch — `git commit --allow-empty -m "ci: re-trigger checks" && git push` — which fires feature.yml's push trigger on the new head SHA and reports the checks. | [dependency-drift.yml:16](dependency-drift.yml#L16) |
