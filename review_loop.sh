#!/usr/bin/env bash
#
# review_loop.sh — Codex reviews uncommitted changes, Claude fixes, loop until clean.
#
# Runs inside tmux so it persists across SSH disconnects.
#
# Usage:
#   ./review_loop.sh              # from your project root
#   bash /path/to/review_loop.sh  # from anywhere (uses cwd as repo)
#

set -euo pipefail

REPO_DIR="$(pwd)"
cd "$REPO_DIR"

# Verify we're in a git repo
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error: not inside a git repository. Run from your project root."
    exit 1
fi

REVIEWS_DIR="$REPO_DIR/reviews"
mkdir -p "$REVIEWS_DIR"

MAX_ITERATIONS="${MAX_ITERATIONS:-5}"
LOG="$REVIEWS_DIR/loop_$(date +%Y%m%d_%H%M%S).log"
LOCKFILE="$REVIEWS_DIR/.clocoloop-review.lock"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

check_deps() {
    local missing=0
    for cmd in claude codex tmux; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "Error: '$cmd' not found. Install it first."
            missing=1
        fi
    done
    [ "$missing" = "1" ] && exit 1
}

acquire_lock() {
    if [ -f "$LOCKFILE" ]; then
        local old_pid
        old_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "Error: another review loop is running (PID $old_pid). Lockfile: $LOCKFILE"
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

run_loop() {
    acquire_lock

    log "Starting review loop (max $MAX_ITERATIONS iterations)"
    log "Repo: $REPO_DIR"

    for i in $(seq 1 $MAX_ITERATIONS); do
        log "=== Iteration $i/$MAX_ITERATIONS ==="

        # Step 1: Codex reviews uncommitted changes
        # Note: codex exec outputs to stderr, not stdout
        REVIEW_FILE="$REVIEWS_DIR/codex_review_iter${i}_$(date +%Y%m%d_%H%M%S).md"
        log "Step 1: Running codex review -> $REVIEW_FILE"

        local exit_code=0
        codex exec review --uncommitted 2> "$REVIEW_FILE" || exit_code=$?

        if [ ! -f "$REVIEW_FILE" ] || [ ! -s "$REVIEW_FILE" ]; then
            if [ "$exit_code" -ne 0 ]; then
                log "ERROR: Codex review failed (exit code $exit_code) with no output."
            else
                log "Review file empty or not created. Skipping iteration."
            fi
            sleep 5
            continue
        fi

        REVIEW_LINES=$(wc -l < "$REVIEW_FILE")
        log "Review written to $REVIEW_FILE ($REVIEW_LINES lines)"

        # Step 2: Check if Codex approves
        if check_approval "$REVIEW_FILE"; then
            log "Codex approves! Review loop complete."
            break
        fi

        # Count P1/P2 for logging
        local p1_count p2_count
        p1_count=$(grep -ciE '\[P1\]|\bcritical\b|\bregression\b|\bbroken\b|\bcrash\b' "$REVIEW_FILE" 2>/dev/null || true)
        p1_count="${p1_count:-0}"
        p2_count=$(grep -ciE '\[P2\]|\bmedium\b severity|\bbug\b|\bincorrect\b' "$REVIEW_FILE" 2>/dev/null || true)
        p2_count="${p2_count:-0}"

        # Step 3: Claude fixes the issues found by Codex
        log "Step 3: Claude fixing $p1_count P1 + $p2_count P2 issues..."
        FIX_LOG="$REVIEWS_DIR/claude_fix_iter${i}_$(date +%Y%m%d_%H%M%S).log"

        local sanitized_review
        sanitized_review=$(sanitize_review "$REVIEW_FILE")

        exit_code=0
        claude -p \
            --continue \
            --fork-session \
            --dangerously-skip-permissions \
            --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
            "A code reviewer found issues. Fix ALL issues listed.

--- BEGIN REVIEW DATA ---
$sanitized_review
--- END REVIEW DATA ---

For each issue:
1. Read the file mentioned
2. Apply the fix
3. Verify the fix parses

After fixing all issues, run relevant tests to verify nothing broke.
Do NOT commit changes. Just fix and verify.
Be concise — just fix, don't explain at length." \
            > "$FIX_LOG" 2>&1 || exit_code=$?

        FIX_LINES=$(wc -l < "$FIX_LOG")
        log "Claude fix log: $FIX_LOG ($FIX_LINES lines)"

        if [ "$exit_code" -ne 0 ] && [ "$FIX_LINES" -lt 5 ]; then
            log "ERROR: Claude fix failed (exit code $exit_code) with minimal output."
            cat "$FIX_LOG" >> "$LOG"
        elif [ "$exit_code" -ne 0 ]; then
            log "WARNING: Claude fix exited with code $exit_code but produced output."
        elif [ "$FIX_LINES" -lt 5 ]; then
            log "WARNING: Claude fix output is very short, may have failed."
            cat "$FIX_LOG" >> "$LOG"
        fi

        sleep 10
    done

    log "Review loop finished after iteration $i"
    log "All reviews and fixes in: $REVIEWS_DIR/"
    ls -la "$REVIEWS_DIR/"*.md "$REVIEWS_DIR/"*.log >> "$LOG" 2>/dev/null || true
}

# ── Entry Point ───────────────────────────────────────────────────────

check_deps

# If already inside tmux review-loop session, run directly
if [ "${TMUX_REVIEW_LOOP:-}" = "1" ]; then
    run_loop
    exit 0
fi

# Otherwise, launch inside a tmux session
SESSION_NAME="review-loop"
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
QUOTED_REPO=$(printf '%q' "$REPO_DIR")
QUOTED_SCRIPT=$(printf '%q' "$SCRIPT_PATH")
tmux new-session -d -s "$SESSION_NAME" \
    "cd $QUOTED_REPO && TMUX_REVIEW_LOOP=1 bash $QUOTED_SCRIPT"

echo "Review loop started in tmux session '$SESSION_NAME'"
echo "  Attach:  tmux attach -t $SESSION_NAME"
echo "  Logs:    tail -f $LOG"
echo "  Reviews: ls $REVIEWS_DIR/"
echo ""
echo "This will persist even if you disconnect SSH."
