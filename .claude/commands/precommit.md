---
description: Loop of (build+test → review → fix) until clean, then commit (auto). The gated path for agent commits on a feature branch.
argument-hint: "[review effort: low|medium|high|max] (default high)"
allowed-tools: Bash, Read, Edit, Grep, Glob, Skill
---

Run the full pre-commit pipeline and, only once it is clean, create the commit.
Do not skip steps — the commit guard will block the commit unless the final review
ran against the exact staged code.

**Review effort:** use the level in `$ARGUMENTS`; if empty, default to `high`.
Valid levels are `low`, `medium`, `high`, `max` (broadest coverage the command can
run). Do **not** use `ultra` here — that is a billed, user-triggered cloud review
and must not be launched automatically.

1. **Refuse on main.** If the current branch is `main`/`master`, stop and tell the
   user to branch first. Do not commit.

2. **Review loop.** Repeat the following until a review comes back clean:

   a. **Green before every review.** Build and run the tests (`/check`). If the
      build or any test fails, fix the *code* — never weaken or delete a test —
      and repeat (a) until green. **A `code-review` must never run on red code.**

   b. **Review.** First `git add -A` so brand-new/untracked files are part of the
      diff — `code-review` inspects `git diff HEAD`, which excludes untracked
      files, so anything unstaged would go unreviewed. Then run the `code-review`
      skill at the chosen effort over the changes.

   c. **Fix.** If the review has any actionable findings, apply them all (edit
      source, not tests), then go back to step (a) — re-green, then re-review.

   d. **Clean exit.** When a review returns no actionable findings *and* the build
      and tests are green, the loop is done.

3. **Stage + mark + commit** — as TWO separate shell calls, so the guard sees the
   staged tree when the commit runs:

   - First call (stage everything, then record the review marker):

     ```bash
     git add -A && bash .claude/hooks/precommit-hash.sh > "$(git rev-parse --git-dir)/precommit-review.ok"
     ```

   - Second call (the commit itself):

     ```bash
     git commit -m "<concise conventional-commit message: what changed and why>"
     ```

   The guard allows this commit because the marker now matches the staged code.
   Write a real message summarizing the change — do not leave it generic.

If you cannot reach a clean, green state, stop and report. Do not commit.
