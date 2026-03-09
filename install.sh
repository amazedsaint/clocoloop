#!/usr/bin/env bash
#
# CloCoLoop installer — installs /feature-loop and /review-loop skills for Claude Code.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/amazedsaint/clocoloop/main/install.sh | bash
#
set -euo pipefail

REPO="amazedsaint/clocoloop"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
SKILLS_DIR="$HOME/.claude/skills"

echo "Installing CloCoLoop skills for Claude Code..."
echo ""

# Create skill directories
mkdir -p "$SKILLS_DIR/feature-loop/scripts"
mkdir -p "$SKILLS_DIR/review-loop/scripts"

# Download feature-loop skill
echo "  Downloading /feature-loop skill..."
curl -fsSL "$BASE_URL/skills/feature-loop/SKILL.md" \
    -o "$SKILLS_DIR/feature-loop/SKILL.md"
curl -fsSL "$BASE_URL/skills/feature-loop/scripts/feature_loop.sh" \
    -o "$SKILLS_DIR/feature-loop/scripts/feature_loop.sh"
chmod +x "$SKILLS_DIR/feature-loop/scripts/feature_loop.sh"

# Download review-loop skill
echo "  Downloading /review-loop skill..."
curl -fsSL "$BASE_URL/skills/review-loop/SKILL.md" \
    -o "$SKILLS_DIR/review-loop/SKILL.md"
curl -fsSL "$BASE_URL/skills/review-loop/scripts/review_loop.sh" \
    -o "$SKILLS_DIR/review-loop/scripts/review_loop.sh"
chmod +x "$SKILLS_DIR/review-loop/scripts/review_loop.sh"

echo ""
echo "CloCoLoop skills installed successfully!"
echo ""
echo "Available commands in Claude Code:"
echo "  /feature-loop <branch-name> <task description>"
echo "  /review-loop"
echo ""
echo "Examples:"
echo "  /feature-loop fix-auth Fix the session expiry bug in auth.py"
echo "  /feature-loop add-tests Add unit tests for the payment module"
echo "  /review-loop"
echo ""
echo "Prerequisites: claude, codex, gh, tmux"
echo "Skills installed to: $SKILLS_DIR/"
