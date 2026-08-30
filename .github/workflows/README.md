# GitHub Actions workflows

What runs when. **How it fits together, the design decisions, and the known limitations live in
[docs/automation.md](../../docs/automation.md).**

| Workflow | Runs |
| --- | --- |
| [`build-and-test.yml`](build-and-test.yml) | Reusable job: build + test (Debug, signing off) on `macos-26`, Xcode 26.4.1. |
| [`feature.yml`](feature.yml) | Pushes to `feature/**` and `chore/**`. |
| [`main.yml`](main.yml) | Pushes to `main`. |
| [`release.yml`](release.yml) | Pushes to `release/**`. Despite the name, publishes nothing. |
| [`integration-whisperkit.yml`](integration-whisperkit.yml) | Reusable job: the end-to-end WhisperKit suite. |
| [`ui-tests.yml`](ui-tests.yml) | Reusable job: the XCUITest suite. Runs **signed**. |
| [`publish-release.yml`](publish-release.yml) | A `v*` tag: signed, notarized DMG + ZIP + Sparkle appcast → GitHub Release. |
| [`claude.yml`](claude.yml) | `@claude` mentions on issues, PR comments and reviews. |
| [`claude-code-review.yml`](claude-code-review.yml) | PR pushes: posts inline review findings. |
| [`claude-fix.yml`](claude-fix.yml) | `@claude fix` from a maintainer: applies findings, builds, pushes, re-reviews. |
| [`dependency-drift.yml`](dependency-drift.yml) | Weekly: re-resolves the SwiftPM graph, then opens a PR or files an issue. |

The three branch pipelines each call `build-and-test`, then `integration-whisperkit` and `ui-tests`
with `needs: build-and-test`.
