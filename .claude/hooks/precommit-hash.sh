#!/usr/bin/env bash
# Canonical hash of the STAGED tree, shared by /precommit and the commit guard.
# MUST emit nothing when nothing is staged — the empty-input digest is a non-empty string that
# would satisfy the guard's `[ -n "$want" ]` check.
# Why: docs/automation.md#the-commit-guard
git diff --cached --quiet HEAD 2>/dev/null && exit 0
git diff --cached HEAD 2>/dev/null | shasum -a 256 | cut -c1-64
