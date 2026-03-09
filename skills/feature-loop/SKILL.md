---
name: feature-loop
description: Run a Claude+Codex automated feature development loop. Creates a feature branch, Claude implements the task, Codex reviews, Claude fixes issues, loops until approved, then creates a PR.
disable-model-invocation: true
argument-hint: <branch-name> <task description>
---

# CloCoLoop Feature Loop

Launch the automated feature development loop with the provided arguments.

## Arguments

$ARGUMENTS

Parse the above: the **first word** is the branch name, **everything after it** is the task description.

## Project context

- Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repo)"`
- Uncommitted changes: !`git status --short 2>/dev/null | head -5`

## Execute

Run from the current working directory (must be a git repo):

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/feature_loop.sh" "<branch-name>" "<task-description>"
```

Replace `<branch-name>` and `<task-description>` with the parsed values. **Quote the task description** as a single argument.

The script launches a persistent tmux session (`feature-<branch>`) and returns immediately.

After running, report to the user:
- Tmux session name
- `tmux attach -t feature-<branch>` to watch live
- `cat reviews/<branch>/status.json` to check status
- `tail -f reviews/<branch>/loop.log` to stream logs

## Environment variables

If the user specifies these, prefix them to the bash command:
- `MAX_ITERATIONS` — max review/fix cycles (default: 5)
- `BASE_BRANCH` — base branch (default: main)

Example: `MAX_ITERATIONS=10 BASE_BRANCH=develop bash "${CLAUDE_SKILL_DIR}/scripts/feature_loop.sh" ...`

## Prerequisites

Requires: `claude`, `codex`, `gh`, `tmux`
