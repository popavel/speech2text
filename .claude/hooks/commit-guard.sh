#!/usr/bin/env bash
# PreToolUse(Bash) commit guard — governs how the AGENT commits.
#
# Commits you type in a real terminal never reach this hook; it only ever sees
# Bash commands Claude runs. Behaviour for the agent:
#   - on main/master            -> blocked outright
#   - on a feature branch       -> blocked UNLESS a /precommit review marker
#                                  matches the currently-staged tree
set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Act only on a real `git commit` at a COMMAND position — start of a line (grep
# matches line by line, so `^` also covers newline-separated commands), right after
# a separator (`;` `&` `|` `(` or command substitution), or after an env-var prefix
# (`VAR=val git commit`; the `=` distinguishes it from prose). This leaves
# `git commit-tree`, `git committed`, and — unlike a bare word-boundary match —
# quoted/echoed prose mentions of "git commit" alone.
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

# Refuse working-tree staging flags (-a/--all/-p/--patch/--include): they record
# changes the review never saw, because the marker covers only the staged index
# (`git diff --cached HEAD`). /precommit stages explicitly and commits with `-m`, so
# it is unaffected. Inspect only the commit's OWN args — from the `git commit`
# keyword to the next command separator — so flags on a CHAINED command (e.g.
# `git add --all && git commit`, `ls -la && git commit`) don't trip this. (A literal
# " -a " inside the commit message is still refused — conservative, safe, fail-closed.)
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
