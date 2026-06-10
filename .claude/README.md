# Local Claude automation

This folder holds the project-local Claude Code automation that runs on your Mac (no API key
or subscription beyond a normal Claude Code session). For the deeper prose on how it all fits
together, see the **Automation helpers** section of [AGENTS.md](../AGENTS.md); for the CI side,
see [.github/workflows/README.md](../.github/workflows/README.md).

## What's here

### Hooks ([settings.json](settings.json))

- **Commit guard** (PreToolUse) — [commit-guard.sh](hooks/commit-guard.sh) governs how the
  *agent* commits: blocked outright on `main`/`master`; on a feature branch, blocked unless a
  `/precommit` review marker matches the currently-staged tree. The marker is the SHA-256 of the
  staged diff, computed by [precommit-hash.sh](hooks/precommit-hash.sh). Commits you type in your
  own terminal never reach this hook. It is a guardrail for a cooperative agent, **not** an
  adversarial sandbox.
- **Auto-regen** (PostToolUse) — runs `xcodegen generate` automatically whenever `project.yml`
  is edited.

### Commands ([commands/](commands/))

- [`/check`](commands/check.md) — build then test with the exact CI incantation (Debug, signing
  off). Pass `-only-testing:...` to scope it.
- [`/precommit`](commands/precommit.md) — the gated path for agent commits: loops
  build+test → `code-review` → fix until clean, then stages, marks, and commits.
- [`/fix-pr`](commands/fix-pr.md) — addresses a PR's review findings locally, then verifies +
  commits via `/precommit` and pushes (the on-your-Mac alternative to the `@claude fix` workflow).

### Agents ([agents/](agents/))

- [`build-verifier`](agents/build-verifier.md) — owns the build → test → fix loop in its own
  context, keeping `xcodebuild` logs out of the main thread.
- [`test-author`](agents/test-author.md) — writes the failing Swift Testing test first.

## Known limitations

The commit guard is a guardrail for a cooperative agent, not an adversarial sandbox — these are
accepted edges, recorded so maintainers aren't surprised by them.

| Caveat | Trigger → impact | Source |
| ------ | ---------------- | ------ |
| Chained commits inspect only the **last** commit's args. | The greedy `sed` strips up to the last `git commit`, so in `git commit -a -m x ; git commit -m y` the `-a` (a working-tree staging flag) on the first commit escapes the refusal and records changes the review never saw. | [commit-guard.sh:49](hooks/commit-guard.sh#L49) |
| The detector matches `git commit` inside quoted data / prose. | When `git commit` is preceded by an env-style `word=word ` prefix or an in-string `;`, the guard fires — so legitimate commands that merely *reference* `git commit` (echoes, analysis or review scripts) are wrongly denied. | [commit-guard.sh:28](hooks/commit-guard.sh#L28) |
| The detector allows some commits through. | Redirect-prefixed (`>out.log git commit`) and absolute-path (`/usr/bin/git commit`) forms are not matched — a fail-open regression that lets those forms commit unreviewed. | [commit-guard.sh:28](hooks/commit-guard.sh#L28) |
