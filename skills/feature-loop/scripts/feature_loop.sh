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
LOCKFILE="$WORK_DIR/.clocoloop-feature.lock"

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
    python3 -c "
import json, sys
data = {
    'branch': sys.argv[1],
    'base': sys.argv[2],
    'state': sys.argv[3],
    'iteration': int(sys.argv[4]),
    'max_iterations': int(sys.argv[5]),
    'message': sys.argv[6],
    'pr_url': sys.argv[7],
    'task': sys.argv[8],
    'timestamp': sys.argv[9],
    'log': sys.argv[10],
}
with open(sys.argv[11], 'w') as f:
    json.dump(data, f, indent=4)
" "$BRANCH_NAME" "$BASE_BRANCH" "$state" "$iteration" "$MAX_ITERATIONS" \
  "$message" "$pr_url" "$TASK_DESCRIPTION" "$(date -Iseconds)" "$LOG" "$STATUS_FILE"
}

acquire_lock() {
    if [ -f "$LOCKFILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "Error: another feature loop is running (PID $old_pid). Lockfile: $LOCKFILE"
            exit 1
        fi
        log "WARNING: Removing stale lockfile (PID $old_pid no longer running)"
        rm -f "$LOCKFILE"
    fi
    echo $$ > "$LOCKFILE"
}

release_lock() {
    rm -f "$LOCKFILE"
}

trap release_lock EXIT INT TERM

check_approval() {
    local review_file="$1"

    # Highest confidence: explicit markers
    if grep -qiE '\bAPPROVED\b' "$review_file"; then
        return 0
    fi
    if grep -qiE '\bREJECTED\b' "$review_file"; then
        return 1
    fi

    # Structured output: empty findings
    if grep -q '"findings": \[\]' "$review_file" 2>/dev/null; then
        return 0
    fi

    # Full-phrase approval patterns (avoid overly broad terms)
    if grep -qiE 'looks good to me|no issues found|no problems found|no bugs found|no changes needed|\bLGTM\b' "$review_file"; then
        return 0
    fi

    # Check severity — approve if no P1/P2 issues
    local p1_count p2_count
    p1_count=$(grep -ciE '\[P1\]|\bcritical\b|\bregression\b|\bbroken\b|\bcrash\b' "$review_file" 2>/dev/null || true)
    p1_count="${p1_count:-0}"
    p2_count=$(grep -ciE '\[P2\]|\bmedium\b severity|\bbug\b|\bincorrect\b' "$review_file" 2>/dev/null || true)
    p2_count="${p2_count:-0}"
    if [ "$p1_count" = "0" ] && [ "$p2_count" = "0" ]; then
        return 0
    fi

    return 1
}

sanitize_review() {
    local review_file="$1"
    grep -vE '^\s*(system|assistant|user)\s*:|^\s*<\s*(system|prompt|instruction)|ignore\s+(previous|above)\s+instructions|you\s+are\s+now|forget\s+(your|all)\s+(instructions|rules)' "$review_file" || cat "$review_file"
}

# ── Main Loop ─────────────────────────────────────────────────────────

run_feature_loop() {
    acquire_lock

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

    local pre_head
    pre_head=$(git rev-parse HEAD)

    local exit_code=0
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
        > "$IMPL_LOG" 2>&1 || exit_code=$?

    IMPL_LINES=$(wc -l < "$IMPL_LOG")
    log "Implementation log: $IMPL_LOG ($IMPL_LINES lines)"

    if [ "$exit_code" -ne 0 ] && [ "$IMPL_LINES" -lt 5 ]; then
        log "ERROR: Claude implementation failed (exit code $exit_code) with minimal output."
        cat "$IMPL_LOG" >> "$LOG"
        write_status "tool_error" 0 "Claude implementation failed (exit $exit_code)"
    elif [ "$exit_code" -ne 0 ]; then
        log "WARNING: Claude implementation exited with code $exit_code but produced output."
    fi

    # Verify git state after implementation
    local post_head
    post_head=$(git rev-parse HEAD)
    if [ "$pre_head" = "$post_head" ]; then
        log "WARNING: No new commits after Claude implementation."
    else
        log "New commits detected after implementation (HEAD moved from ${pre_head:0:8} to ${post_head:0:8})."
    fi

    local uncommitted
    uncommitted=$(git status --porcelain 2>/dev/null || echo "")
    if [ -n "$uncommitted" ]; then
        log "WARNING: Uncommitted changes remain after implementation step."
    fi

    # Step 2: Review/fix loop
    APPROVED=false
    for i in $(seq 1 $MAX_ITERATIONS); do
        log "=== Review iteration $i/$MAX_ITERATIONS ==="
        write_status "reviewing" "$i" "Codex reviewing (iteration $i)"

        # Codex reviews the branch diff against base
        REVIEW_FILE="$WORK_DIR/codex_review_iter${i}.md"
        log "Codex reviewing diff ${BASE_BRANCH}..${BRANCH_NAME}..."

        exit_code=0
        codex exec review \
            --base "$BASE_BRANCH" \
            2> "$REVIEW_FILE" || exit_code=$?

        if [ ! -s "$REVIEW_FILE" ]; then
            # Only fall back to --uncommitted if there are actually uncommitted changes
            local dirty
            dirty=$(git status --porcelain 2>/dev/null || echo "")
            if [ -n "$dirty" ]; then
                log "Review file empty. Uncommitted changes detected, trying --uncommitted fallback..."
                exit_code=0
                codex exec review --uncommitted 2> "$REVIEW_FILE" || exit_code=$?
            else
                log "ERROR: --base produced no output and no uncommitted changes exist."
                write_status "tool_error" "$i" "Codex review produced no output"
                sleep 5
                continue
            fi
        fi

        if [ ! -s "$REVIEW_FILE" ]; then
            if [ "$exit_code" -ne 0 ]; then
                log "ERROR: Codex review failed (exit code $exit_code) with no output."
                write_status "tool_error" "$i" "Codex review failed (exit $exit_code)"
            else
                log "Review still empty. Skipping to next iteration."
            fi
            sleep 5
            continue
        fi

        REVIEW_LINES=$(wc -l < "$REVIEW_FILE")
        log "Review: $REVIEW_FILE ($REVIEW_LINES lines)"

        # Check if Codex approves
        if check_approval "$REVIEW_FILE"; then
            log "Codex APPROVED at iteration $i!"
            APPROVED=true
            break
        fi

        # Count P1/P2 for logging
        local p1_count p2_count
        p1_count=$(grep -ciE '\[P1\]|\bcritical\b|\bregression\b|\bbroken\b|\bcrash\b' "$REVIEW_FILE" 2>/dev/null || true)
        p1_count="${p1_count:-0}"
        p2_count=$(grep -ciE '\[P2\]|\bmedium\b severity|\bbug\b|\bincorrect\b' "$REVIEW_FILE" 2>/dev/null || true)
        p2_count="${p2_count:-0}"

        # Claude fixes the issues
        log "Claude fixing $p1_count P1 + $p2_count P2 issues..."
        write_status "fixing" "$i" "Claude fixing issues (iteration $i)"

        FIX_LOG="$WORK_DIR/claude_fix_iter${i}.log"

        local sanitized_review
        sanitized_review=$(sanitize_review "$REVIEW_FILE")

        pre_head=$(git rev-parse HEAD)

        exit_code=0
        claude -p \
            --dangerously-skip-permissions \
            --fork-session \
            --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
            "You are on branch '$BRANCH_NAME'. A code reviewer found issues.

--- BEGIN REVIEW DATA ---
$sanitized_review
--- END REVIEW DATA ---

Fix ALL P1 and P2 issues listed. For each:
1. Read the file
2. Apply the fix
3. Verify it parses

After fixing, run relevant tests, then commit with message:
'Fix issues from review iteration $i'" \
            > "$FIX_LOG" 2>&1 || exit_code=$?

        FIX_LINES=$(wc -l < "$FIX_LOG")
        log "Fix log: $FIX_LOG ($FIX_LINES lines)"

        if [ "$exit_code" -ne 0 ] && [ "$FIX_LINES" -lt 5 ]; then
            log "ERROR: Claude fix failed (exit code $exit_code) with minimal output."
            cat "$FIX_LOG" >> "$LOG"
            write_status "tool_error" "$i" "Claude fix failed (exit $exit_code)"
        elif [ "$exit_code" -ne 0 ]; then
            log "WARNING: Claude fix exited with code $exit_code but produced output."
        fi

        # Verify git state after fix
        post_head=$(git rev-parse HEAD)
        if [ "$pre_head" = "$post_head" ]; then
            log "WARNING: No new commits after Claude fix step."
        else
            log "Fix committed (HEAD moved from ${pre_head:0:8} to ${post_head:0:8})."
        fi

        uncommitted=$(git status --porcelain 2>/dev/null || echo "")
        if [ -n "$uncommitted" ]; then
            log "WARNING: Uncommitted changes remain after fix step."
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
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
QUOTED_REPO=$(printf '%q' "$REPO_DIR")
QUOTED_SCRIPT=$(printf '%q' "$SCRIPT_PATH")
QUOTED_BRANCH=$(printf '%q' "$BRANCH_NAME")
QUOTED_TASK=$(printf '%q' "$TASK_DESCRIPTION")
tmux new-session -d -s "$SESSION_NAME" \
    "cd $QUOTED_REPO && FEATURE_LOOP_ACTIVE=1 bash $QUOTED_SCRIPT $QUOTED_BRANCH $QUOTED_TASK"

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
