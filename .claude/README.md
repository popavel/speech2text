# Local Claude automation

Project-local Claude Code automation that runs on your Mac — no API key or subscription beyond a
normal Claude Code session. **How it works, why the guard is shaped the way it is, and its known
limitations live in [docs/automation.md](../docs/automation.md).**

| | |
| --- | --- |
| **Hooks** ([settings.json](settings.json)) | Branch guard (refuses edits on `main`), commit guard ([commit-guard.sh](hooks/commit-guard.sh) + [precommit-hash.sh](hooks/precommit-hash.sh)), and auto-`xcodegen` on `project.yml` edits. |
| [`/check`](commands/check.md) | Build then test with the CI incantation. |
| [`/precommit`](commands/precommit.md) | The gated path for agent commits: build+test → review → fix → commit. |
| [`/fix-pr`](commands/fix-pr.md) | Address a PR's review findings locally, then verify and push. |
| [`build-verifier`](agents/build-verifier.md) | Owns the build → test → fix loop in its own context. |
| [`test-author`](agents/test-author.md) | Writes the failing Swift Testing test first. |

The commit guard is a guardrail for a cooperative agent, **not** an adversarial sandbox — its
accepted gaps are tabled in
[docs/automation.md](../docs/automation.md#known-limitations).
