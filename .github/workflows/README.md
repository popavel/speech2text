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
- [`release.yml`](release.yml) — calls `build-and-test` on `release/**` branches.

### Integration

- [`integration-whisperkit.yml`](integration-whisperkit.yml) — runs the end-to-end WhisperKit
  suite (downloads the tiny model and actually transcribes), not just a compile.

### Claude automation

- [`claude.yml`](claude.yml) — the `@claude` bot. A cheap ubuntu **gate** job does the
  word-boundary mention match (excluding `@claude fix`, which the fixer owns) before the macOS
  job runs. Triggers on issue/PR comments, reviews, and opened issues.
- [`claude-code-review.yml`](claude-code-review.yml) — runs `/code-review --comment` on every PR
  push and posts inline findings; a new push cancels the stale in-flight review.
- [`claude-fix.yml`](claude-fix.yml) — the human-in-the-loop `@claude fix` loop: applies open
  review findings, builds + tests (green gate — a broken fix is not pushed), pushes, and
  re-reviews, all in one macOS run.
- [`whisperkit-drift.yml`](whisperkit-drift.yml) — weekly: re-resolves WhisperKit to the latest
  release within the pinned major, builds + tests, and opens a PR if still green or files an
  issue if upstream drift broke the build.

## Known limitations

These are accepted edges of the automation, recorded so maintainers aren't surprised by them.

| Caveat | Trigger → impact | Source |
| ------ | ---------------- | ------ |
| The `@claude` mention regex treats `-` as a word boundary, so handles like `@claude-bot` or `@claude-code` are matched as a mention of the bot. | A comment that mentions an unrelated `@claude-*` user (e.g. `@claude-bot please`) passes the gate, spinning up the privileged `macos-26` runner (with `contents: write`) even though no one summoned this bot — wasted compute, and an unintended privileged run on attacker-influenceable text. (`email@claude.com` correctly does **not** match, since `@` is preceded by an alphanumeric.) | [claude.yml:59](claude.yml#L59) |
