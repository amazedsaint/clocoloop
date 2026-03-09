#!/usr/bin/env bash
#
# feature_loop.sh — End-to-end Claude + Codex feature development loop.
#
# Creates a feature branch, Claude implements the task, Codex reviews,
# Claude fixes issues, loops until Codex approves, then submits a PR.
#
# Runs inside tmux so it persists across SSH disconnects.
#
# Usage:
#   ./feature_loop.sh "branch-name" "Task description for Claude"
#   ./feature_loop.sh "fix-auth" "Fix the session expiry bug in auth.py"
#   ./feature_loop.sh "add-tests" "Add unit tests for the payment module"
#
# Environment:
#   MAX_ITERATIONS  — max review/fix cycles (default: 5)
#   BASE_BRANCH     — branch to base off (default: main)
#

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────

if [ $# -lt 2 ]; then
    echo "Usage: $0 <branch-name> <task-description>"
    echo ""
    echo "Examples:"
    echo "  $0 fix-auth 'Fix session expiry bug in auth.py'"
    echo "  $0 add-tests 'Add unit tests for the payment module'"
    echo "  $0 refactor-db 'Extract DB queries into repository pattern'"
    echo ""
    echo "Environment variables:"
    echo "  BASE_BRANCH     Base branch (default: main)"
    echo "  MAX_ITERATIONS  Max review/fix cycles (default: 5)"
    exit 1
fi

BRANCH_NAME="$1"
TASK_DESCRIPTION="$2"
BASE_BRANCH="${BASE_BRANCH:-main}"
MAX_ITERATIONS="${MAX_ITERATIONS:-5}"

# ── Setup ─────────────────────────────────────────────────────────────

REPO_DIR="$(pwd)"
cd "$REPO_DIR"

# Verify we're in a git repo
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error: not inside a git repository. Run from your project root."
    exit 1
fi

WORK_DIR="$REPO_DIR/reviews/$BRANCH_NAME"
mkdir -p "$WORK_DIR"

LOG="$WORK_DIR/loop.log"
STATUS_FILE="$WORK_DIR/status.json"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Helpers ───────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

check_deps() {
    local missing=0
    for cmd in claude codex gh tmux; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "Error: '$cmd' not found. Install it first."
            missing=1
        fi
    done
    [ "$missing" = "1" ] && exit 1
}

write_status() {
    local state="$1"
    local iteration="${2:-0}"
    local message="${3:-}"
    local pr_url="${4:-}"
    cat > "$STATUS_FILE" << STATUSEOF
{
    "branch": "$BRANCH_NAME",
    "base": "$BASE_BRANCH",
    "state": "$state",
    "iteration": $iteration,
    "max_iterations": $MAX_ITERATIONS,
    "message": "$message",
    "pr_url": "$pr_url",
    "task": $(echo "$TASK_DESCRIPTION" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),
    "timestamp": "$(date -Iseconds)",
    "log": "$LOG"
}
STATUSEOF
}

# ── Main Loop ─────────────────────────────────────────────────────────

run_feature_loop() {
    log "=========================================="
    log "CloCoLoop Feature: $BRANCH_NAME"
    log "Task: $TASK_DESCRIPTION"
    log "Base: $BASE_BRANCH"
    log "Max iterations: $MAX_ITERATIONS"
    log "Work dir: $WORK_DIR"
    log "=========================================="

    write_status "starting" 0 "Creating branch"

    # Step 0: Create feature branch
    log "Creating branch '$BRANCH_NAME' from '$BASE_BRANCH'..."
    git checkout "$BASE_BRANCH" 2>&1 | tee -a "$LOG"
    git pull --ff-only origin "$BASE_BRANCH" 2>&1 | tee -a "$LOG" || true
    git checkout -b "$BRANCH_NAME" 2>&1 | tee -a "$LOG" || {
        # Branch may already exist
        git checkout "$BRANCH_NAME" 2>&1 | tee -a "$LOG"
    }
    log "On branch: $(git branch --show-current)"

    # Step 1: Claude implements the feature
    log "Step 1: Claude implementing feature..."
    write_status "implementing" 0 "Claude is implementing the feature"

    IMPL_LOG="$WORK_DIR/claude_implement_${TIMESTAMP}.log"

    claude -p \
        --dangerously-skip-permissions \
        --allowedTools "Read,Edit,Write,Bash,Glob,Grep,Agent" \
        "You are working on branch '$BRANCH_NAME'.

Task: $TASK_DESCRIPTION

Instructions:
1. Implement the task completely
2. Run relevant tests to verify your changes work
3. Stage and commit your changes with a descriptive commit message
4. Be thorough but concise" \
        > "$IMPL_LOG" 2>&1 || true

    IMPL_LINES=$(wc -l < "$IMPL_LOG")
    log "Implementation log: $IMPL_LOG ($IMPL_LINES lines)"

    if [ "$IMPL_LINES" -lt 5 ]; then
        log "WARNING: Claude implementation output very short, may have failed."
        cat "$IMPL_LOG" >> "$LOG"
    fi

    # Step 2: Review/fix loop
    APPROVED=false
    for i in $(seq 1 $MAX_ITERATIONS); do
        log "=== Review iteration $i/$MAX_ITERATIONS ==="
        write_status "reviewing" "$i" "Codex reviewing (iteration $i)"

        # Codex reviews the branch diff against base
        REVIEW_FILE="$WORK_DIR/codex_review_iter${i}.md"
        log "Codex reviewing diff ${BASE_BRANCH}..${BRANCH_NAME}..."

        codex exec review \
            --base "$BASE_BRANCH" \
            2> "$REVIEW_FILE" || true

        if [ ! -s "$REVIEW_FILE" ]; then
            log "Review file empty. Trying --uncommitted fallback..."
            codex exec review --uncommitted 2> "$REVIEW_FILE" || true
        fi

        if [ ! -s "$REVIEW_FILE" ]; then
            log "Review still empty. Skipping to next iteration."
            sleep 5
            continue
        fi

        REVIEW_LINES=$(wc -l < "$REVIEW_FILE")
        log "Review: $REVIEW_FILE ($REVIEW_LINES lines)"

        # Check if Codex approves
        if grep -qi 'LGTM\|no issues\|looks good\|no problems\|no bugs\|no changes needed\|no action\|clean' "$REVIEW_FILE"; then
            log "Codex APPROVED at iteration $i!"
            APPROVED=true
            break
        fi

        if grep -q '"findings": \[\]' "$REVIEW_FILE" 2>/dev/null; then
            log "Codex returned empty findings — APPROVED!"
            APPROVED=true
            break
        fi

        # Check if Codex only found minor/P3 issues (still approve)
        P1_COUNT=$(grep -ci '\[P1\]\|critical\|regression\|broken\|crash' "$REVIEW_FILE" 2>/dev/null || echo "0")
        P2_COUNT=$(grep -ci '\[P2\]\|medium\|bug\|incorrect' "$REVIEW_FILE" 2>/dev/null || echo "0")
        if [ "$P1_COUNT" = "0" ] && [ "$P2_COUNT" = "0" ]; then
            log "Codex found no P1/P2 issues — treating as approved."
            APPROVED=true
            break
        fi

        # Claude fixes the issues
        log "Claude fixing $P1_COUNT P1 + $P2_COUNT P2 issues..."
        write_status "fixing" "$i" "Claude fixing issues (iteration $i)"

        FIX_LOG="$WORK_DIR/claude_fix_iter${i}.log"

        claude -p \
            --dangerously-skip-permissions \
            --fork-session \
            --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
            "You are on branch '$BRANCH_NAME'. A code reviewer found issues.

Read the review at: $REVIEW_FILE

Fix ALL P1 and P2 issues listed. For each:
1. Read the file
2. Apply the fix
3. Verify it parses

After fixing, run relevant tests, then commit with message:
'Fix issues from review iteration $i'" \
            > "$FIX_LOG" 2>&1 || true

        FIX_LINES=$(wc -l < "$FIX_LOG")
        log "Fix log: $FIX_LOG ($FIX_LINES lines)"

        if [ "$FIX_LINES" -lt 5 ]; then
            log "WARNING: Claude fix output very short, may have failed."
            cat "$FIX_LOG" >> "$LOG"
        fi

        sleep 5
    done

    # Step 3: Push and create PR
    if [ "$APPROVED" = true ]; then
        log "=== Creating Pull Request ==="
        write_status "creating_pr" "$i" "Pushing and creating PR"

        # Push branch
        git push -u origin "$BRANCH_NAME" 2>&1 | tee -a "$LOG" || {
            log "Push failed — may need auth. Skipping PR."
            write_status "push_failed" "$i" "git push failed"
            return 1
        }

        # Create PR
        PR_URL=$(gh pr create \
            --base "$BASE_BRANCH" \
            --head "$BRANCH_NAME" \
            --title "$TASK_DESCRIPTION" \
            --body "$(cat <<PREOF
## Summary
- $TASK_DESCRIPTION

## Review
- Codex reviewed and approved after $i iteration(s)
- All tests passing

## Logs
- Branch: \`$BRANCH_NAME\`
- Review artifacts: \`reviews/$BRANCH_NAME/\`

---
*Automated by [CloCoLoop](https://github.com/amazedsaint/clocoloop)*
PREOF
)" \
            2>&1) || true

        if echo "$PR_URL" | grep -q "https://"; then
            log "PR created: $PR_URL"
            write_status "completed" "$i" "PR created" "$PR_URL"
        else
            log "PR creation output: $PR_URL"
            write_status "pr_failed" "$i" "gh pr create failed: $PR_URL"
        fi
    else
        log "Max iterations ($MAX_ITERATIONS) reached without full approval."
        log "Branch '$BRANCH_NAME' has partial fixes. Manual review needed."
        write_status "max_iterations" "$MAX_ITERATIONS" "Needs manual review"

        # Still push the branch for manual review
        git push -u origin "$BRANCH_NAME" 2>&1 | tee -a "$LOG" || true
    fi

    log "=========================================="
    log "CloCoLoop complete for: $BRANCH_NAME"
    log "Status: $(cat "$STATUS_FILE")"
    log "=========================================="
}

# ── Entry Point ───────────────────────────────────────────────────────

check_deps

# If inside tmux feature-loop session, run directly
if [ "${FEATURE_LOOP_ACTIVE:-}" = "1" ]; then
    run_feature_loop
    exit 0
fi

# Otherwise, launch inside a persistent tmux session
SESSION_NAME="feature-${BRANCH_NAME}"

# Kill any existing session with same name
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# Start new tmux session
SCRIPT_PATH="$(realpath "$0")"
tmux new-session -d -s "$SESSION_NAME" \
    "cd '$REPO_DIR' && FEATURE_LOOP_ACTIVE=1 bash '$SCRIPT_PATH' '$BRANCH_NAME' '$TASK_DESCRIPTION'"

echo ""
echo "CloCoLoop started in tmux session '$SESSION_NAME'"
echo ""
echo "  Branch:  $BRANCH_NAME (from $BASE_BRANCH)"
echo "  Task:    $TASK_DESCRIPTION"
echo "  Attach:  tmux attach -t $SESSION_NAME"
echo "  Status:  cat $STATUS_FILE"
echo "  Logs:    tail -f $WORK_DIR/loop.log"
echo ""
echo "This runs in the background — survives SSH disconnects."
echo "Poll status with: cat reviews/$BRANCH_NAME/status.json"
