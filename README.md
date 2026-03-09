# CloCoLoop

**Automated Claude + Codex code review loop.** Claude writes code, Codex reviews it, Claude fixes what Codex finds — looping until the code passes review, then submitting a pull request.


⠀⠀⠀⠀⡠⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⠀⠀⠀
⠀⠀⠀⣾⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢱⡄⠀⠀
⠀⠀⣼⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣸⣷⡄⠀
⢘⢸⣿⣿⣦⠀⠀⠀⠀⠄⠀⠀⠀⣠⣿⣿⡇⢠
⣾⡘⣿⣿⣿⡷⠀⠀⠀⡇⠀⠀⠰⣿⣿⣿⡇⣼
⢻⣧⣻⣿⣿⠁⠀⠀⠀⡇⠀⠀⠀⢿⣿⡿⣱⣿
⠚⣿⣷⣿⣿⠀⠀⠈⣄⣇⠂⠀⠀⢸⣿⣿⣿⡧
⠈⢿⣿⣿⣿⡀⠀⠀⡿⡿⡃⠀⠀⣾⣿⣿⣿⠃
⠀⠘⢿⣿⣿⣿⡀⠘⠀⡇⠀⢀⣼⣿⣿⡿⠃⠀
⠀⠀⠀⠉⠻⠿⢿⣦⣤⣇⣴⣿⠿⠟⠋⠀⠀⠀


```
  ┌──────────┐     ┌──────────┐    ┌──────────┐
  │  Claude  │───> │  Codex   │───>│  Claude  │
  │ implement│     │  review  │    │   fix    │
  └──────────┘     └──────────┘    └──────────┘
       │               │               │
       │               v               │
       │         Pass? ──> PR          │
       │         Fail? ──> Loop <──────┘
```

## Install

### As Claude Code skills (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/amazedsaint/clocoloop/main/install.sh | bash
```

This installs `/feature-loop` and `/review-loop` as slash commands in Claude Code.

### As standalone scripts

```bash
git clone https://github.com/amazedsaint/clocoloop.git
cd clocoloop
chmod +x feature_loop.sh review_loop.sh
```

### Prerequisites

- [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) — `npm install -g @anthropic-ai/claude-code`
- [Codex CLI](https://www.npmjs.com/package/@openai/codex) — `npm install -g @openai/codex`
- [GitHub CLI](https://cli.github.com/) — `brew install gh` / `apt install gh`, then `gh auth login`
- [tmux](https://github.com/tmux/tmux) — `brew install tmux` / `apt install tmux`

## Usage

### Claude Code skills

```
/feature-loop fix-auth Fix the session expiry bug in auth.py
/feature-loop add-tests Add unit tests for the payment module
/review-loop
```

### Standalone scripts

```bash
# Feature loop: branch, implement, review, fix, PR
./feature_loop.sh "fix-auth" "Fix the session expiry bug in auth.py"

# Review loop: review uncommitted changes, fix, repeat
./review_loop.sh
```

### Environment variables

```bash
BASE_BRANCH=develop ./feature_loop.sh "my-feature" "Add payment processing"
MAX_ITERATIONS=10 ./feature_loop.sh "big-refactor" "Refactor the auth system"
```

### Monitor progress

```bash
tmux attach -t feature-fix-auth          # Watch live
cat reviews/fix-auth/status.json         # Poll status
tail -f reviews/fix-auth/loop.log        # Stream logs
tmux list-sessions | grep -E 'feature-|review-'  # List all loops
```

### Run multiple loops in parallel

Each loop runs in its own tmux session on a separate branch:

```bash
./feature_loop.sh "fix-auth" "Fix session expiry bug"
./feature_loop.sh "add-tests" "Add unit tests for payments"
./feature_loop.sh "refactor-db" "Extract DB queries into repository pattern"
```

## Status file

The feature loop writes `reviews/<branch>/status.json`:

```json
{
    "branch": "fix-auth",
    "state": "reviewing",
    "iteration": 2,
    "max_iterations": 5,
    "message": "Codex reviewing (iteration 2)",
    "task": "Fix the session expiry bug in auth.py"
}
```

States: `starting` > `implementing` > `reviewing` > `fixing` > `creating_pr` > `completed`

Error states: `tool_error`, `push_failed`, `pr_failed`, `max_iterations`

## How it works

**Feature loop** (`feature_loop.sh`):
1. Creates a feature branch from base
2. Claude implements the task via `claude -p`
3. Codex reviews the diff with `codex exec review --base <branch>`
4. If P1/P2 issues found, Claude fixes them and the loop repeats
5. On approval, pushes and creates a PR via `gh`

**Review loop** (`review_loop.sh`):
1. Codex reviews uncommitted changes with `codex exec review --uncommitted`
2. If issues found, Claude fixes them (no commit)
3. Repeats until clean or max iterations reached

**Safety features:**
- PID-based lockfiles prevent concurrent runs on the same branch
- Review content is sanitized before passing to Claude (prompt injection defense)
- Git state is verified after each agent step (commit detection, uncommitted change warnings)
- `write_status()` uses `json.dump()` for proper JSON escaping
- Explicit error handling with exit code capture instead of blanket `|| true`
- `printf '%q'` quoting for all tmux command interpolation

## Tips

- `codex exec review` outputs to **stderr**, not stdout — the scripts handle this with `2>`
- Always use `--dangerously-skip-permissions` and `--allowedTools` for unattended Claude
- Large diffs (2000+ lines) can take 5-10 minutes for Codex to review
- Add `reviews/` to your `.gitignore`
- If Codex hasn't approved after 5 rounds, the issue likely needs human judgment

## Cost

Each iteration: one Codex review call + one Claude fix call. A typical 3-iteration loop costs ~$1-3. Full feature loop (implementation + review cycles) runs $2-5 total.

## License

MIT
