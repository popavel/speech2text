# CI and automation

Two halves, deliberately separate: **local** automation that runs on your Mac inside a normal Claude
Code session (no API key, no extra subscription), and **GitHub** workflows that run on GitHub's
runners. Both are indexed here.

> **Migration in progress.** `.github/workflows/README.md` and `.claude/README.md` still carry the
> full prose (and still point at `AGENTS.md`); they are reduced to one-line-per-file stubs pointing
> back to this page in a later commit. Until then the material is duplicated — see
> [README.md](README.md) for the plan.

All bot workflows authenticate the model via the `CLAUDE_CODE_OAUTH_TOKEN` repo secret —
**subscription auth, not a pay-as-you-go API key**. Generate it locally with `claude setup-token`
and store it under Settings → Secrets and variables → Actions.

---

## CI pipelines

**Backs:** `.github/workflows/build-and-test.yml`, `feature.yml`, `main.yml`, `release.yml`

- **`build-and-test.yml`** — reusable (`workflow_call`) job: build + test (Debug, signing off) on
  `macos-26`, pinned to Xcode 26.4.1.
- **`feature.yml`** — calls it on `feature/**` **and `chore/**`** branches.
- **`main.yml`** — calls it on pushes to `main`.
- **`release.yml`** — calls it on `release/**` branches. Despite the name it publishes nothing; the
  distribution pipeline is `publish-release.yml`.

Each of the three also calls `integration-whisperkit` and `ui-tests`, both with
`needs: build-and-test`, so the expensive jobs only spin up once the cheap one is green.

### Push-only, deliberately no `pull_request:` trigger

A push-event check attaches to the branch head SHA, which is also the head commit of a
`feature/**` or `chore/**` → main PR, so `feature.yml`'s push run already satisfies the
`main protection` ruleset's required contexts on that PR.

**Re-adding `pull_request:` fires a second run for the same commit.** Today's concurrency groups
are keyed on `${{ github.workflow }}-${{ github.ref }}`, and `github.ref` differs between the two
events (`refs/heads/…` vs `refs/pull/N/merge`), so the pair would *not* collide — it would simply
burn double the CI minutes.

The merge-blocking failure this guards against is historical but worth knowing, because it is what
a naive re-enable would recreate: in `1845f46` the group was keyed on
`github.event.pull_request.head.ref || github.ref_name`, which **did** put both runs in one group,
so one was cancelled and left a `cancelled` required check on the PR head that blocked the merge.
`55db068` reverted the key *and* made the workflow push-only. Re-adding the trigger without also
re-checking the concurrency key walks straight back into it.

All three pipelines are push-only for this reason. `main.yml`/`release.yml` keep the disabled
`pull_request:` block commented with a tripwire that points at the concurrency key rather than
forbidding the trigger outright — enabling it on `main.yml` is in fact the natural fix for the gap
below, and what must not be repeated is enabling it *without* re-checking the key.

**A gap worth naming:** coverage comes from `feature.yml`, which triggers only on `feature/**` and
`chore/**`. A PR into `main` from a branch with any other prefix gets no required-context run at
all — `main.yml` fires only on pushes *to* `main`, i.e. after the merge.

---

## Integration and UI jobs

**Backs:** `.github/workflows/integration-whisperkit.yml`, `ui-tests.yml`

- **`integration-whisperkit.yml`** — runs the end-to-end WhisperKit suite (downloads the tiny model
  and actually transcribes), not just a compile. Gated by a `TEST_RUNNER_`-prefixed environment
  variable — see [testing.md#integration-gating](testing.md#integration-gating).
- **`ui-tests.yml`** — reusable job running the XCUITest suite against the real app. **The only
  *test* job that runs signed** (no `CODE_SIGNING_ALLOWED=NO` — an unsigned test runner is killed
  before it can attach); `publish-release.yml` also builds signed, but with a Developer ID identity
  rather than Xcode's default ad-hoc signature. Called by feature/main/release with `needs: build-and-test`, and still
  `workflow_dispatch`-able for manual runs.

  This was held back as manual-only until a green dispatch run proved XCUITest works on `macos-26`;
  that run passed, so it was wired in. The signed runner means **a flaky UI run can turn the whole
  pipeline red** — which is also why UI tests stay out of the `Speech2Text` scheme's own test
  action. See [testing.md#the-xctest-exception](testing.md#the-xctest-exception).

`ui-tests.yml` passes `-configuration Debug` explicitly rather than relying on the test-action
default, because the UI-test seam is `#if DEBUG`.

---

## Distribution

**Backs:** `.github/workflows/publish-release.yml`

Triggered by a `v*` tag push (or a manual `workflow_dispatch`; the strict `vX.Y.Z` shape is
enforced by the preflight, not the trigger). Gates on a separate `build-and-test` job, then:
preflight (the tag must equal both
versions in `project.yml`; `SUFeedURL`/`SUPublicEDKey` must be present) → import the Developer ID
cert into a throwaway keychain → Release build with hardened runtime → verify the **built product**
→ notarize + staple → ZIP for Sparkle → build, sign, notarize and staple a DMG → `generate_appcast`
→ upload everything to a **draft** GitHub Release and flip it to published last.

The full reasoning — why the product is verified rather than the source, why draft-then-publish, the
per-tag concurrency, the secret preflight, and the single-item-appcast limitation — lives in
[distribution.md](distribution.md).

It needs `contents: write` and seven repository secrets. Two `notarytool --wait` round-trips
dominate the runtime, hence the 75-minute timeout. It refuses to overwrite an already-published
release, but will delete and rebuild a stale *draft* so a failed run can be retried on the same tag.

---

## The `@claude` bot

**Backs:** `.github/workflows/claude.yml`

Responds to `@claude` mentions in issues, PR comments and reviews, running on macOS so Claude can
regenerate, build and test the project. `@claude fix` is excluded — the fixer owns those.

A cheap **ubuntu gate job** does the word-boundary match before the macOS runner spins up. The
job-level `if:` is the expression-only `author_association` allowlist; the step does the boundary
matching that `contains()` cannot.

Quoted (`> …`) lines are stripped so a quote-reply doesn't re-trigger the bot. The comment body and
the issue body/title are handled **separately on purpose**: a comment or review body can be a quote
reply, an issue body/title cannot, and `format()`-joining them would put the title on the body's
last line, where a trailing quote line would strip it too.

The `issues` trigger is `opened` **only, not `assigned`** — the gate matches `@claude` in the
body/title, which is unchanged across (re)assignments, so `assigned` would re-fire the macOS bot on
every assignment of an `@claude` issue.

---

## Review and fix loop

**Backs:** `.github/workflows/claude-code-review.yml`, `claude-fix.yml`

**`claude-code-review.yml`** runs `/code-review --comment` on PR pushes, posting inline findings via
the `github_inline_comment` MCP tool (which must stay in the step's `--allowedTools`). A new push
cancels the stale in-flight review. Static review, no build, on a cheap Linux runner.

Its `branches:` filter is the PR's **base**, and lists only `feature/**` and `main` — so a PR based
on `release/**` gets no automatic review.

It uses `pull_request`, **not `pull_request_target`**, so a PR from a fork runs with no secrets and
a read-only token and the review silently no-ops there. That is intentional: `pull_request_target`
would run untrusted fork code with our secrets. Same-repo `feature/**` PRs are the supported path.

It **skips bot-authored PRs** (e.g. the weekly drift PR): `claude-code-action` refuses bot actors,
and a lockfile-only bump needs no static review.

Cost note: the review fans out subagents on every `synchronize`. If that gets too heavy, drop
`synchronize` from the triggers and review only on `opened`.

**`claude-fix.yml`** is the human-in-the-loop half. A trusted maintainer — a person, never the review
bot — comments `@claude fix` on a PR or replies it to an inline review comment, and in **one** macOS
run the workflow: applies the open review findings → builds and tests them (a **green gate**; a
broken fix is not pushed) → pushes to the PR branch → re-runs the review.

Doing build/test/review inline is what means **no PAT is needed**: it doesn't rely on the push to
re-trigger other workflows, which GitHub suppresses for `GITHUB_TOKEN` pushes. It is the CI-side
mirror of the local `/precommit` loop.

It skips build/commit/re-review entirely when Claude made no edits, gates on the same boundary match
as the bot, and accepts `@claude fix` from issue comments, inline review comments, or a review
summary. **The review bot itself can't trigger the fixer** — `author_association` plus GitHub's
`GITHUB_TOKEN` loop-prevention block that by design.

The commit is made by a **run-step** (a workflow command, not a Claude tool call), so the local
commit guard doesn't intercept it. `xcodegen` runs *after* change detection.

---

## Dependency drift

**Backs:** `.github/workflows/dependency-drift.yml`

Runs weekly (Mondays 06:00 UTC). Dependencies are pinned with `from:` constraints, which are
up-to-next-major, so any of them can ship a newer release *within* its pinned major that breaks the
build at any time. The job drops `Package.resolved` and re-resolves the **whole** SwiftPM graph
(WhisperKit, Sparkle, ViewInspector, and transitives like swift-argument-parser) to the latest
release each `from:` allows, builds + tests, and either opens a PR listing which pins moved (still green) or
files an issue mentioning `@claude` (broken → needs adapting).

**`from:` never crosses a major boundary**, so a new major of any dependency is **not** picked up
here — that needs a manual `from:` bump in `project.yml`. This check covers within-major drift only.

Drift runs are serialized so a manual dispatch racing the weekly cron can't both pass the open-PR
dedup check and open duplicate PRs. Queued rather than cancelled, so an in-flight build+test
finishes.

The test step **un-gates the end-to-end WhisperKit suite** (`TEST_RUNNER_RUN_WHISPERKIT_TESTS=1`),
so a drift check proves WhisperKit still *runs* and not merely still *compiles* — which is the whole
point of catching upstream drift. A **manual** bump gets the same evidence from
`integration-whisperkit.yml` once pushed to a branch; what it doesn't get is a proposal, since
`from:` never crosses a major. See [testing.md#whisperkit-drift](testing.md#whisperkit-drift).

---

## Local automation

**Backs:** `.claude/settings.json`, `.claude/hooks/`, `.claude/commands/`, `.claude/agents/`

### Hooks

Three, all in `.claude/settings.json`:

- **Branch guard** (`PreToolUse` on `Edit|Write|MultiEdit`) — denies any file edit while on
  `main`/`master`, pointing at `git checkout -b feature/<short-name>`. This is what enforces step 1
  of the change workflow; the commit guard below is a second line of defence, not the same check.
- **Commit guard** (`PreToolUse` on `Bash`) — see [below](#the-commit-guard). It fails closed: if
  `commit-guard.sh` can't run at all, the wrapper emits its own deny.
- **Auto-regen** (`PostToolUse` on `Edit|Write|MultiEdit`) — runs `xcodegen generate` automatically
  whenever `project.yml` is edited, so step 4 of the change workflow can't be forgotten. It matches
  on basename, and reports a failed regeneration back rather than silently continuing.

### Commands

- **`/check`** — builds then tests with the exact CI incantation (Debug, signing off). Pass
  `-only-testing:…` to scope it.
- **`/precommit`** — the gated path for agent commits: loops build+test → `code-review` → fix until
  clean, then stages, records the review marker, and commits. Review effort defaults to `high`;
  `ultra` is intentionally excluded — it's a billed cloud review.
- **`/fix-pr`** — addresses a PR's review findings **locally** (the on-your-Mac alternative to the
  `@claude fix` workflow): checks out the PR, reads its review comments, fixes them, then verifies
  and commits via `/precommit` and pushes.

### Subagents

- **`build-verifier`** — owns the build → test → fix loop in its own context, keeping `xcodebuild`
  logs out of the main thread.
- **`test-author`** — writes the failing Swift Testing test first.

---

## The commit guard

**Backs:** `.claude/hooks/commit-guard.sh`, `.claude/hooks/precommit-hash.sh`

`commit-guard.sh` governs how the **agent** commits. Commits you type in your own terminal never
reach it — hooks only see Bash commands the agent runs.

- On `main`/`master` → **blocked outright**.
- On a feature branch → **blocked unless** a `/precommit` review marker
  (`<git-dir>/precommit-review.ok`) equals the SHA-256 of the staged tree
  (`git diff --cached HEAD`), as computed by `precommit-hash.sh`.
- Working-tree staging flags (`-a`/`--all`/`-p`/`--patch`/`--include`) are **refused**: they record
  changes the review never saw, because the marker covers only the staged index. `/precommit` stages
  explicitly and commits with `-m`, so it is unaffected.

Because the marker is tied to the exact staged code, any later change to the staged tree invalidates
it and forces a re-review.

**It is a guardrail for a cooperative agent, not an adversarial sandbox.** The marker attests *that
a review ran on this exact code*, not that the review was thorough.

Some details worth knowing before editing it:

- It **fails closed** if `jq` is unavailable — without `jq` it could neither parse the command (the
  detector would match nothing and silently allow) nor emit a deny. The fixed deny JSON is printed
  directly, needing no `jq`.
- The detector matches the commit verb only at a **command position**: start of a line (`grep`
  matches line by line, so `^` also covers newline-separated commands), right after a separator
  (`;` `&` `|` `(` or command substitution), or after an env-var prefix (`VAR=val …` — the `=` is
  what distinguishes it from prose). This leaves `git commit-tree`, `git committed`, and — unlike a
  bare word-boundary match — quoted or echoed prose mentions alone.
- Only the commit's **own** args are inspected, from the commit keyword to the next separator, so
  flags on a chained command (`git add --all && …`) don't trip the staging-flag refusal.
- `precommit-hash.sh` emits **nothing** when nothing is staged. An empty staged tree would otherwise
  hash to the well-known empty-input digest (`e3b0c442…`), a non-empty string that would satisfy the
  guard's `[ -n "$want" ]` check; emitting `""` keeps that check meaningful.

---

## Known limitations

**Backs:** `.claude/hooks/commit-guard.sh` · `.github/workflows/claude.yml`,
`dependency-drift.yml`, `publish-release.yml`

Accepted edges of the automation, recorded so maintainers aren't surprised by them. Sources name the
construct rather than a line number, because comment edits renumber these files.

| Component | Caveat | Trigger → impact |
| --- | --- | --- |
| `commit-guard.sh` — the greedy `sed` in the args extractor | Chained commits inspect only the **last** commit's args. | The `sed` strips up to the last commit keyword, so in a `… -a -m x ; … -m y` chain the `-a` on the first commit escapes the refusal and records changes the review never saw. |
| `commit-guard.sh` — the command-position regex | The detector matches the commit verb inside quoted data / prose. | When it is preceded by an env-style `word=word ` prefix or an in-string `;`, the guard fires — so legitimate commands that merely *reference* it (echoes, analysis or review scripts, **or documentation like this file**) are wrongly denied. |
| `commit-guard.sh` — the command-position regex | The detector allows some commits through. | Redirect-prefixed (`>out.log …`) and absolute-path (`/usr/bin/git …`) forms are not matched — a fail-open regression that lets those forms commit unreviewed. Global options between `git` and the verb (`git -c user.name=x …`, `git -C <dir> …`) and wrappers (`time …`, `{ …; }`) are likewise unmatched; catching them would need full shell tokenization. Brand-new files aren't part of the hash until staged, and a literal ` -a ` inside a commit message is conservatively refused. |
| `claude.yml` — the mention-boundary regex in the gate job | The `@claude` regex treats `-` as a word boundary, so handles like `@claude-bot` or `@claude-code` match as a mention of the bot. | A comment mentioning an unrelated `@claude-*` user passes the gate, spinning up the privileged `macos-26` runner (with `contents: write`) even though no one summoned this bot — wasted compute, and an unintended privileged run on attacker-influenceable text. (`email@claude.com` correctly does **not** match, since `@` is preceded by an alphanumeric.) |
| `dependency-drift.yml` — the PR opened with `GITHUB_TOKEN` | A drift PR is opened by `github-actions[bot]`, which GitHub won't let trigger `on: push` workflows. | The PR's required checks sit at "Expected — Waiting for status to be reported" forever; a manual `workflow_dispatch` does not reliably attach to the PR head. **Unblock:** push one **human** empty commit to the PR branch, which fires `feature.yml`'s push trigger on the new head SHA. |
| `publish-release.yml` — `generate_appcast` input dir | The appcast carries exactly one item. | See [distribution.md#the-appcast-carries-exactly-one-item](distribution.md#the-appcast-carries-exactly-one-item). |
