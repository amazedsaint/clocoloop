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

run_loop() {
    log "Starting review loop (max $MAX_ITERATIONS iterations)"
    log "Repo: $REPO_DIR"

    for i in $(seq 1 $MAX_ITERATIONS); do
        log "=== Iteration $i/$MAX_ITERATIONS ==="

        # Step 1: Codex reviews uncommitted changes
        # Note: codex exec outputs to stderr, not stdout
        REVIEW_FILE="$REVIEWS_DIR/codex_review_iter${i}_$(date +%Y%m%d_%H%M%S).md"
        log "Step 1: Running codex review -> $REVIEW_FILE"

        codex exec review --uncommitted 2> "$REVIEW_FILE" || true

        if [ ! -f "$REVIEW_FILE" ] || [ ! -s "$REVIEW_FILE" ]; then
            log "Review file empty or not created. Skipping iteration."
            sleep 5
            continue
        fi

        REVIEW_LINES=$(wc -l < "$REVIEW_FILE")
        log "Review written to $REVIEW_FILE ($REVIEW_LINES lines)"

        # Step 2: Check if Codex found no issues
        if grep -qi "LGTM\|no issues\|looks good\|no problems\|no bugs\|no changes needed" "$REVIEW_FILE"; then
            log "Codex approves! Review loop complete."
            break
        fi

        if grep -q '"findings": \[\]' "$REVIEW_FILE" 2>/dev/null; then
            log "Codex returned empty findings. Review loop complete."
            break
        fi

        # Check severity — only continue loop for P1/P2
        P1_COUNT=$(grep -ci '\[P1\]\|critical\|regression\|broken\|crash' "$REVIEW_FILE" 2>/dev/null || echo "0")
        P2_COUNT=$(grep -ci '\[P2\]\|medium\|bug\|incorrect' "$REVIEW_FILE" 2>/dev/null || echo "0")
        if [ "$P1_COUNT" = "0" ] && [ "$P2_COUNT" = "0" ]; then
            log "No P1/P2 issues found — treating as approved."
            break
        fi

        # Step 3: Claude fixes the issues found by Codex
        log "Step 2: Claude fixing $P1_COUNT P1 + $P2_COUNT P2 issues..."
        FIX_LOG="$REVIEWS_DIR/claude_fix_iter${i}_$(date +%Y%m%d_%H%M%S).log"

        claude -p \
            --continue \
            --fork-session \
            --dangerously-skip-permissions \
            --allowedTools "Read,Edit,Write,Bash,Glob,Grep" \
            "Read the codex review at $REVIEW_FILE and fix ALL issues listed.
For each issue:
1. Read the file mentioned
2. Apply the fix
3. Verify the fix parses

After fixing all issues, run relevant tests to verify nothing broke.
Do NOT commit changes. Just fix and verify.
Be concise — just fix, don't explain at length." \
            > "$FIX_LOG" 2>&1 || true

        FIX_LINES=$(wc -l < "$FIX_LOG")
        log "Claude fix log: $FIX_LOG ($FIX_LINES lines)"

        if [ "$FIX_LINES" -lt 5 ]; then
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
tmux new-session -d -s "$SESSION_NAME" \
    "cd '$REPO_DIR' && TMUX_REVIEW_LOOP=1 bash '$(realpath "$0")'"

echo "Review loop started in tmux session '$SESSION_NAME'"
echo "  Attach:  tmux attach -t $SESSION_NAME"
echo "  Logs:    tail -f $LOG"
echo "  Reviews: ls $REVIEWS_DIR/"
echo ""
echo "This will persist even if you disconnect SSH."
