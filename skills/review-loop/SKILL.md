---
name: review-loop
description: Run a Codex review loop on uncommitted changes. Codex reviews, Claude fixes issues, loops until clean or max iterations reached.
disable-model-invocation: true
---

# CloCoLoop Review Loop

Launch the automated review loop on uncommitted changes in the current repository.

## Project context

- Current branch: !`git branch --show-current 2>/dev/null || echo "(not in a git repo)"`
- Uncommitted changes: !`git status --short 2>/dev/null | head -10`

## Execute

Run from the current working directory (must be a git repo):

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/review_loop.sh"
```

If the user specifies a number (e.g. `/review-loop 10`), set MAX_ITERATIONS:

```bash
MAX_ITERATIONS=<n> bash "${CLAUDE_SKILL_DIR}/scripts/review_loop.sh"
```

$ARGUMENTS

The script launches a persistent tmux session (`review-loop`) and returns immediately.

After running, report to the user:
- Tmux session name
- `tmux attach -t review-loop` to watch live
- How to find logs in `reviews/`

## Prerequisites

Requires: `claude`, `codex`, `tmux`
