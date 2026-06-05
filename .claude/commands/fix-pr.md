---
description: Fix a PR's review findings locally, then verify + commit via /precommit and push. The on-your-Mac alternative to the @claude fix workflow.
argument-hint: "<pr-number> [review effort: low|medium|high|max] (default high)"
allowed-tools: Bash, Read, Edit, Grep, Glob, Skill
---

Address the review findings on a pull request **on this machine** (not the GitHub
`@claude fix` workflow), then verify, commit through the guard, and push.

Parse `$ARGUMENTS`: the first token is the PR number (required); an optional second
token is the review effort for the verify step (default `high`; `ultra` is not
allowed here — it's a billed cloud review).

1. **Get on the PR branch.** Confirm the working tree is clean (`git status`), then
   `gh pr checkout <pr-number>`. If you're already on that branch this just updates
   it. If the tree is dirty, stop and ask the user to stash or commit first.

2. **Read the review.** PR comments live on two different surfaces — fetch both:
   - **Conversation comments** (top-level, not tied to a code line — a human's general
     feedback or a review summary):
     `gh pr view <pr-number> --comments`
   - **Inline review comments** (anchored to a file + line; this is where the
     max-review bot posts its findings, each with `path`, `line`, `body`):
     `gh api repos/{owner}/{repo}/pulls/<pr-number>/comments`

   Also `gh pr diff <pr-number>` for context. If nothing is posted yet, say so and run
   a fresh `/code-review` locally to generate findings instead.

3. **Fix.** Apply the smallest correct fix for each actionable finding. Edit source —
   never weaken or delete a test. Follow AGENTS.md (Swift Testing style, @MainActor /
   strict-concurrency rules, one-way state flow off TranscriptionManager). If a finding
   is wrong, do not change code for it — note why for the summary.

4. **Verify + commit via `/precommit`.** Run the `/precommit` pipeline at the chosen
   effort: it loops build+test → `code-review` → fix until clean, then stages, marks,
   and commits past the commit guard. Do not bypass it.

5. **Push.** `git push` to update the PR.

6. **Summarize.** Leave one short PR comment noting what you fixed and what you skipped
   (and why): `gh pr comment <pr-number> --body "..."`.

If you cannot reach a clean, green state, stop and report — do not push a broken fix.
