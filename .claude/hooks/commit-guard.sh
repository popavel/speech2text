#!/usr/bin/env bash
# PreToolUse(Bash) commit guard — governs how the AGENT commits. Commits you type in a real
# terminal never reach it. Blocked outright on main/master; on a feature branch, blocked unless a
# /precommit review marker matches the currently-staged tree.
# Why: docs/automation.md#the-commit-guard
set -u

# MUST fail closed without jq — the detector would otherwise match nothing and silently allow.
# Why: docs/automation.md#the-commit-guard
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"commit-guard: jq not found on PATH — denying to fail closed. Install jq so the commit guard can run."}}'
  exit 0
fi

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Act only at a COMMAND position: start of line, after a separator, or after an env-var prefix.
# Leaves the -tree and -ed variants, and most quoted prose, alone.
# Why: docs/automation.md#known-limitations
printf '%s' "$cmd" | grep -Eq '(^|[;&|`(]|[^[:space:]]+=[^[:space:]]*[[:space:]]+)[[:space:]]*git[[:space:]]+commit($|[^[:alnum:]_-])' || exit 0

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$branch" in
  main|master)
    deny "Commits on $branch are blocked for the agent. Create a feature branch first (git checkout -b feature/<short-name>)."
    ;;
esac

# Refuse working-tree staging flags: they record changes the review never saw. Only the commit's
# OWN args are inspected, so flags on a chained command don't trip this.
# Why: docs/automation.md#the-commit-guard
commit_args=$(printf '%s' "$cmd" | sed -E 's/.*git[[:space:]]+commit//')
commit_args=${commit_args%%[;&|]*}
if printf '%s' "$commit_args" | grep -Eq '(^|[[:space:]])(--all|--patch|--include|-[A-Za-z]*[ap][A-Za-z]*)([[:space:]]|=|$)'; then
  deny "This commit uses a working-tree staging flag (-a/--all/-p/--patch/--include), which records changes the review never saw — the /precommit marker covers only the staged index. Stage what you want with 'git add', then commit via /precommit."
fi

here=$(cd "$(dirname "$0")" && pwd)
marker="$(git rev-parse --git-dir 2>/dev/null)/precommit-review.ok"
want=$(bash "$here/precommit-hash.sh")

# Allow only when a review marker exists AND matches the exact staged tree.
if [ -n "$want" ] && [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$want" ]; then
  exit 0
fi

deny "This commit hasn't passed review. Run /precommit — it reviews the staged changes, applies fixes, runs a FINAL review, then commits once clean. Re-run it if anything changed since the last review (the marker is tied to the exact staged code)."
