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

# Act only on real `git commit` calls (word boundary): leaves `git commit-tree`,
# `git committed`, and unrelated commands alone.
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_-])git[[:space:]]+commit($|[^[:alnum:]_-])' || exit 0

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

here=$(cd "$(dirname "$0")" && pwd)
marker="$(git rev-parse --git-dir 2>/dev/null)/precommit-review.ok"
want=$(bash "$here/precommit-hash.sh")

# Allow only when a review marker exists AND matches the exact staged tree.
if [ -n "$want" ] && [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$want" ]; then
  exit 0
fi

deny "This commit hasn't passed review. Run /precommit — it reviews the staged changes, applies fixes, runs a FINAL review, then commits once clean. Re-run it if anything changed since the last review (the marker is tied to the exact staged code)."
