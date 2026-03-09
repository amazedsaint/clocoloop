# CloCoLoop

**Automated Claude + Codex code review loop.** Claude writes code, Codex reviews it, Claude fixes what Codex finds — looping until the code passes review, then submitting a pull request. Runs in tmux, survives SSH disconnects.

```
┌──────────────────────────────────────────────────┐
│  tmux session (background)                       │
│                                                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐   │
│  │  Claude   │───>│  Codex   │───>│  Claude  │   │
│  │ implement │    │  review  │    │   fix    │   │
│  └──────────┘    └──────────┘    └──────────┘   │
│       │               │               │          │
│       │               v               │          │
│       │         Pass? ──> PR          │          │
│       │         Fail? ──> Loop <──────┘          │
│                                                  │
│  Status: reviews/<branch>/status.json            │
│  Logs:   reviews/<branch>/loop.log               │
└──────────────────────────────────────────────────┘
```

## Why

AI coding assistants make mistakes. Manual review is slow. CloCoLoop pits two independent AI systems against each other: Claude implements, Codex reviews from a different perspective. They iterate until the code is clean. You get a PR with a full audit trail.

## Prerequisites

```bash
# Claude Code (Anthropic's CLI)
npm install -g @anthropic-ai/claude-code

# Codex CLI (OpenAI)
npm install -g @openai/codex

# GitHub CLI (for PR creation)
# macOS: brew install gh
# Ubuntu: sudo apt install gh
gh auth login

# tmux (for background persistence)
# macOS: brew install tmux
# Ubuntu: sudo apt install tmux
```

Verify:

```bash
claude --version && codex --version && gh --version && tmux -V
```

## Install

```bash
git clone https://github.com/amazedsaint/clocoloop.git
cd clocoloop
chmod +x review_loop.sh feature_loop.sh
```

Or just copy the two scripts into your project's `scripts/` directory.

## Quick Start

### Review uncommitted changes

```bash
./review_loop.sh
```

Launches in tmux. Codex reviews your current diff, Claude fixes issues, repeat until clean.

### Develop a feature end-to-end

```bash
./feature_loop.sh "fix-auth-bug" "Fix the session expiry bug in auth.py"
```

Creates a branch, Claude implements the task, Codex reviews, Claude fixes P1/P2 issues, pushes and opens a PR when Codex approves.

### Monitor progress

```bash
# Watch live
tmux attach -t feature-fix-auth-bug

# Poll status
cat reviews/fix-auth-bug/status.json

# Follow logs
tail -f reviews/fix-auth-bug/loop.log

# List all running loops
tmux list-sessions | grep -E 'feature-|review-'
```

## Usage

### `review_loop.sh`

Reviews whatever is currently uncommitted in your repo.

```bash
# Run from your project root
/path/to/clocoloop/review_loop.sh

# Or if you copied it to scripts/
bash scripts/review_loop.sh
```

The loop:
1. Runs `codex exec review --uncommitted` on your current diff
2. If issues found, Claude reads the review and fixes them
3. Repeats until Codex says "looks good" or max iterations hit

### `feature_loop.sh`

Full feature delivery — branch, implement, review, fix, PR.

```bash
./feature_loop.sh <branch-name> <task-description>
```

Examples:

```bash
# Fix a bug
./feature_loop.sh "fix-auth" "Fix session expiry bug in auth.py"

# Add tests
./feature_loop.sh "add-tests" "Add unit tests for the payment module"

# Refactor
./feature_loop.sh "refactor-db" "Extract database queries into repository pattern"
```

### Environment variables

```bash
# Use a different base branch (default: main)
BASE_BRANCH=develop ./feature_loop.sh "my-feature" "Add payment processing"

# Allow more review iterations (default: 5)
MAX_ITERATIONS=10 ./feature_loop.sh "big-refactor" "Refactor the entire auth system"
```

### Run multiple loops in parallel

Each loop runs in its own tmux session on a separate branch:

```bash
./feature_loop.sh "fix-auth" "Fix session expiry bug"
./feature_loop.sh "add-tests" "Add unit tests for payments"
./feature_loop.sh "refactor-db" "Extract DB queries into repository pattern"

# Monitor all
for branch in fix-auth add-tests refactor-db; do
    state=$(python3 -c "import json; print(json.load(open('reviews/$branch/status.json'))['state'])" 2>/dev/null || echo "unknown")
    echo "$branch: $state"
done
```

## Status File

The feature loop writes `reviews/<branch>/status.json`:

```json
{
    "branch": "fix-auth-bug",
    "base": "main",
    "state": "reviewing",
    "iteration": 2,
    "max_iterations": 5,
    "message": "Codex reviewing (iteration 2)",
    "pr_url": "",
    "task": "Fix the session expiry bug in auth.py",
    "timestamp": "2026-03-08T20:35:00+00:00",
    "log": "reviews/fix-auth-bug/loop.log"
}
```

States: `starting` > `implementing` > `reviewing` > `fixing` > `creating_pr` > `completed`

Error states: `push_failed`, `pr_failed`, `max_iterations`

## Gotchas

Hard-won lessons from running this in production.

### Codex outputs to stderr

`codex exec review` sends output to stderr, not stdout:

```bash
# Wrong — captures nothing
codex exec review --uncommitted > review.md

# Correct
codex exec review --uncommitted 2> review.md
```

### Use `--fork-session` not `--resume`

Claude's `--resume` fails on active sessions. Use `--continue --fork-session`:

```bash
# Wrong — fails if session is active
claude -p --resume SESSION_ID "Fix the bugs"

# Correct
claude -p --continue --fork-session "Fix the bugs"
```

### `codex review` vs `codex exec review`

Different commands:
- `codex review` — limited, doesn't support `--uncommitted` with a prompt
- `codex exec review` — full-featured, supports `--base BRANCH` and `--uncommitted`

### Approval detection is fuzzy

Codex doesn't output structured pass/fail. The scripts grep for patterns:

```bash
grep -qi 'LGTM\|no issues\|looks good\|no problems' review.md
grep -q '"findings": \[\]' review.md
```

And check severity — only loop on P1/P2, treat P3-only as approved.

### Permission prompts hang in background

Always use `--dangerously-skip-permissions` for unattended Claude. Restrict `--allowedTools` to limit scope:

```bash
claude -p \
    --dangerously-skip-permissions \
    --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
    "Your prompt"
```

### Large diffs are slow

Codex review on a 2000+ line diff can take 5-10 minutes. Don't set aggressive timeouts.

### Gitignore review artifacts

Add to your `.gitignore`:

```gitignore
reviews/
review.md
```

## CI Integration

Trigger from CI or webhooks:

```bash
# In a GitHub Action
ssh your-server "cd /path/to/repo && \
    /path/to/feature_loop.sh 'auto-fix-$ISSUE_NUMBER' '$ISSUE_TITLE'"
```

Poll for completion:

```bash
while true; do
    state=$(python3 -c "
import json
print(json.load(open('reviews/my-feature/status.json'))['state'])
")
    [ "$state" = "completed" ] || [ "$state" = "max_iterations" ] && break
    sleep 60
done
```

## Cost

Each iteration: one Codex review call + one Claude fix call. A typical 3-iteration loop costs ~$1-3 in API calls. Full feature loop (implementation + review cycles) runs $2-5 total.

Set `MAX_ITERATIONS` conservatively. If Codex hasn't approved after 5 rounds, the issue likely needs human judgment.

## License

MIT
