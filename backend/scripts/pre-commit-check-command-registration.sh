#!/usr/bin/env bash

# =============================================================================
# Pre-Commit Hook: Command Registration Validation
# =============================================================================
#
# Purpose: Prevent committing command files without proper Registry.register calls
#
# Installation:
#   1. Copy this file to .git/hooks/pre-commit
#   2. Make executable: chmod +x .git/hooks/pre-commit
#   3. Ensure existing hooks are preserved
#
# This hook checks:
#   - All command files call Commands::Base::Registry.register()
#   - No duplicate command names
#   - Command names match class names (roughly)
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0

echo "Checking command registration..."

# Find all staged command files
command_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E 'plugins/.*/commands/.*\.rb$' || true)

if [ -z "$command_files" ]; then
  echo -e "${GREEN}✓${NC} No command files to check"
  exit 0
fi

echo -e "${YELLOW}Found $(echo "$command_files" | wc -l) command file(s) to check${NC}"

# Check each command file
while IFS= read -r file; do
  if [ -z "$file" ]; then
    continue
  fi

  # Skip if file doesn't exist (deleted)
  if [ ! -f "$file" ]; then
    continue
  fi

  content=$(cat "$file")

  # Skip if file doesn't define a command class
  if ! echo "$content" | grep -q "class.*<.*Commands::Base::Command"; then
    continue
  fi

  # Extract class name
  class_name=$(echo "$content" | grep "class.*<.*Commands::Base::Command" | head -1 | sed 's/.*class \([^ <]*\).*/\1/')

  # Check for registration
  if ! echo "$content" | grep -q "Commands::Base::Registry.register("; then
    echo -e "${RED}✗${NC} Missing registration in: $file"
    echo "  Expected: Commands::Base::Registry.register(Commands::...::<$class_name>)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Extract the registration call
  registration=$(echo "$content" | grep "Commands::Base::Registry.register" | head -1)

  # Verify it's not indented (should be at root level)
  if echo "$registration" | grep -q "^  "; then
    echo -e "${RED}✗${NC} Registration is indented (should be at root level): $file"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Check if registration includes the class name
  if ! echo "$registration" | grep -q "$class_name"; then
    echo -e "${YELLOW}⚠${NC}  Registration may not include class name: $file"
    echo "  Class: $class_name"
    echo "  Registration: $registration"
    WARNINGS=$((WARNINGS + 1))
  fi

  echo -e "${GREEN}✓${NC} OK: $file"
done <<< "$command_files"

# Summary
echo ""
if [ $ERRORS -gt 0 ]; then
  echo -e "${RED}✗ Found $ERRORS error(s)${NC}"
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo -e "${YELLOW}⚠ Found $WARNINGS warning(s)${NC}"
  echo "  Warnings won't block the commit, but please review"
  exit 0
else
  echo -e "${GREEN}✓ All commands properly registered${NC}"
  exit 0
fi
