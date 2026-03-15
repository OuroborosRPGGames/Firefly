#!/bin/bash
# Check for Rails/ActiveSupport methods that don't exist in plain Ruby
#
# This script detects common Rails methods that cause NoMethodError
# when used in this Sequel-based Ruby application.
#
# Usage:
#   ./scripts/check-rails-methods.sh           # Check all files
#   ./scripts/check-rails-methods.sh --staged  # Check only staged files (for pre-commit)
#
# Exit codes:
#   0 - No violations found
#   1 - Violations found
#
# See: docs/solutions/runtime-errors/rails-methods-in-plain-ruby-prevention.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Rails methods to check for
RAILS_PATTERNS=(
    '\.present\?'
    '\.blank\?'
    '\.titleize'
    '\.humanize[^d]'  # Exclude 'humanized' variables
    '\.truncate\('
    '\.camelize'
    '\.second[^a-z_]'
    '\.third[^a-z_]'
    '\.fourth[^a-z_]'
    '\.fifth[^a-z_]'
    '\.try\(:?'
    '\.days\.(ago|from_now)'
    '\.hours\.(ago|from_now)'
    '\.minutes\.(ago|from_now)'
    '\.seconds\.(ago|from_now)'
)

# Build combined pattern
PATTERN=$(IFS='|'; echo "${RAILS_PATTERNS[*]}")

echo -e "${YELLOW}Checking for Rails/ActiveSupport methods in plain Ruby...${NC}"
echo ""

# Determine which files to check
if [[ "$1" == "--staged" ]]; then
    echo "Checking staged files only..."
    FILES=$(git diff --cached --name-only --diff-filter=ACM | grep '\.rb$' || true)
    if [[ -z "$FILES" ]]; then
        echo -e "${GREEN}No staged Ruby files to check.${NC}"
        exit 0
    fi
else
    echo "Checking all Ruby files in app/, plugins/, lib/..."
    FILES=$(find "$BACKEND_DIR/app" "$BACKEND_DIR/plugins" "$BACKEND_DIR/lib" -name "*.rb" 2>/dev/null || true)
fi

# Track violations
VIOLATION_COUNT=0
VIOLATION_FILES=()

# Check each file
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && continue

    # Skip spec files and the core_extensions module itself
    [[ "$file" == *"_spec.rb" ]] && continue
    [[ "$file" == *"core_extensions.rb" ]] && continue
    [[ "$file" == *"spec/"* ]] && continue

    # Search for violations
    MATCHES=$(grep -n -E "$PATTERN" "$file" 2>/dev/null | grep -v '^\s*#' || true)

    if [[ -n "$MATCHES" ]]; then
        VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
        VIOLATION_FILES+=("$file")

        echo -e "${RED}VIOLATION in:${NC} $file"
        echo "$MATCHES" | while read -r line; do
            LINE_NUM=$(echo "$line" | cut -d: -f1)
            CONTENT=$(echo "$line" | cut -d: -f2-)
            echo -e "  Line $LINE_NUM: $CONTENT"
        done
        echo ""
    fi
done <<< "$FILES"

# Summary
echo "----------------------------------------"
if [[ $VIOLATION_COUNT -gt 0 ]]; then
    echo -e "${RED}FAILED: Found $VIOLATION_COUNT file(s) with Rails method violations${NC}"
    echo ""
    echo "These methods are NOT available in plain Ruby/Sequel:"
    echo "  .present?   - Use: !obj.nil? && !obj.empty? or CoreExtensions.present?(obj)"
    echo "  .blank?     - Use: obj.nil? || obj.empty? or CoreExtensions.blank?(obj)"
    echo "  .titleize   - Use: CoreExtensions.titleize(str)"
    echo "  .humanize   - Use: str.tr('_', ' ').capitalize"
    echo "  .truncate() - Use: CoreExtensions.truncate(str, length)"
    echo "  .camelize   - Use: CoreExtensions.camelize(str)"
    echo "  .second/third/etc - Use: arr[1], arr[2], etc."
    echo "  .try(:method) - Use: obj&.method (safe navigation)"
    echo "  .days.ago   - Use: Time.now - (n * 86400)"
    echo ""
    echo "See: docs/solutions/runtime-errors/rails-methods-in-plain-ruby-prevention.md"
    exit 1
else
    echo -e "${GREEN}PASSED: No Rails method violations found${NC}"
    exit 0
fi
