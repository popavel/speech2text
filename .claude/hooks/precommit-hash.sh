#!/usr/bin/env bash
# Canonical hash of the STAGED tree — i.e. exactly what `git commit` will record.
# Used by both /precommit (to mark a clean review) and the commit guard (to verify
# the review covered exactly this code). Stage with `git add` BEFORE calling this.
#
# Nothing staged -> emit nothing. An empty staged tree otherwise hashes to the
# well-known empty-input digest (e3b0c442...), a non-empty string that would satisfy
# the guard's `[ -n "$want" ]` check; emitting "" keeps that check meaningful.
git diff --cached --quiet HEAD 2>/dev/null && exit 0
git diff --cached HEAD 2>/dev/null | shasum -a 256 | cut -c1-64
