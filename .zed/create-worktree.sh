#!/usr/bin/env bash

set -u

ZED_MAIN_GIT_WORKTREE=${ZED_MAIN_GIT_WORKTREE:-}
ZED_WORKTREE_ROOT=${ZED_WORKTREE_ROOT:-}

if [ -z "$ZED_MAIN_GIT_WORKTREE" ] || [ -z "$ZED_WORKTREE_ROOT" ]; then
    echo "This file should only be called from Zed create worktree" >&2
    exit 1
fi

files=(
    ".agents/deployments.jsonc"
    ".agents/grafana-deploy-excludes.txt"
    ".env"
)

links=(
    ".agents/logs"
)

for file in "${files[@]}"; do
    cp -n "$ZED_MAIN_GIT_WORKTREE/$file" "$ZED_WORKTREE_ROOT/$file"
done

for link in "${links[@]}"; do
    ln -s "$ZED_MAIN_GIT_WORKTREE/$link" "$ZED_WORKTREE_ROOT/$link"
done
