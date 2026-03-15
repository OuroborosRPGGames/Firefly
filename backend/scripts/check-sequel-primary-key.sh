#!/bin/bash
# Check for Sequel models missing explicit primary key declarations
#
# This script detects Sequel models that don't have set_primary_key
# which can cause association and lookup issues.
#
# Usage:
#   ./scripts/check-sequel-primary-key.sh           # Check all files
#   ./scripts/check-sequel-primary-key.sh --staged  # Check only staged files
#
# Exit codes:
#   0 - No violations found
#   1 - Violations found
#
# See: docs/solutions/ACTIVITY-SYSTEM-SEQUEL-PREVENTION-STRATEGIES.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Checking for Sequel models without primary key declarations...${NC}"
echo ""

# Determine which files to check
if [[ "$1" == "--staged" ]]; then
    echo "Checking staged model files only..."
    FILES=$(git diff --cached --name-only --diff-filter=ACM | grep 'app/models/.*\.rb$' || true)
    if [[ -z "$FILES" ]]; then
        echo -e "${GREEN}No staged model files to check.${NC}"
        exit 0
    fi
else
    echo "Checking all model files in app/models/..."
    FILES=$(find "$BACKEND_DIR/app/models" -name "*.rb" 2>/dev/null || true)
fi

# Track violations
VIOLATION_COUNT=0
VIOLATION_FILES=()

# Check each file
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && continue

    # Skip non-Sequel models
    if ! grep -q "< Sequel::Model" "$file" 2>/dev/null; then
        continue
    fi

    # Check for set_primary_key
    if ! grep -q "set_primary_key" "$file" 2>/dev/null; then
        VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
        VIOLATION_FILES+=("$file")

        echo -e "${RED}VIOLATION:${NC} $file"
        echo "  Missing 'set_primary_key' declaration"
        echo ""
    fi
done <<< "$FILES"

# Summary
echo "----------------------------------------"
if [[ $VIOLATION_COUNT -gt 0 ]]; then
    echo -e "${RED}FAILED: Found $VIOLATION_COUNT model(s) without primary key declaration${NC}"
    echo ""
    echo "All Sequel models should include:"
    echo "  unrestrict_primary_key  # If assigning IDs explicitly"
    echo "  set_primary_key :id     # Or [:col1, :col2] for composite"
    echo ""
    echo "Example:"
    echo "  class MyModel < Sequel::Model(:my_models)"
    echo "    unrestrict_primary_key"
    echo "    set_primary_key :id"
    echo "    # ..."
    echo "  end"
    echo ""
    echo "See: docs/solutions/ACTIVITY-SYSTEM-SEQUEL-PREVENTION-STRATEGIES.md"
    exit 1
else
    echo -e "${GREEN}PASSED: All Sequel models have primary key declarations${NC}"
    exit 0
fi
