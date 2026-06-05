#!/usr/bin/env bash
# Canonical hash of the STAGED tree — i.e. exactly what `git commit` will record.
# Used by both /precommit (to mark a clean review) and the commit guard (to verify
# the review covered exactly this code). Stage with `git add` BEFORE calling this.
git diff --cached HEAD 2>/dev/null | shasum -a 256 | cut -c1-64
