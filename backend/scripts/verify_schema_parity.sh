#!/bin/bash
# scripts/verify_schema_parity.sh
# Verify test schema matches production schema for critical tables
# Run before deployment to catch schema mismatches

set -e

PROD_DB="postgres://prom_user:prom_password@localhost/firefly"
TEST_DB="postgres://prom_user:prom_password@localhost/firefly_test"

# Critical tables that MUST match between test and production
TABLES=(
  "graffiti"
  "decorations"
  "room_media"
  "rooms"
  "characters"
  "character_instances"
  "objects"
)

echo "========================================"
echo "Schema Parity Verification"
echo "========================================"
echo ""
echo "Comparing production and test schemas for critical tables..."
echo ""

ERRORS=0

for table in "${TABLES[@]}"; do
  echo "Checking: $table"

  # Get production columns
  PROD_COLS=$(psql "$PROD_DB" -t -c "SELECT column_name FROM information_schema.columns WHERE table_name='$table' ORDER BY ordinal_position;" 2>/dev/null | tr -d ' ' | grep -v '^$' | sort)

  # Get test columns
  TEST_COLS=$(psql "$TEST_DB" -t -c "SELECT column_name FROM information_schema.columns WHERE table_name='$table' ORDER BY ordinal_position;" 2>/dev/null | tr -d ' ' | grep -v '^$' | sort)

  if [ -z "$PROD_COLS" ]; then
    echo "  ⚠️  Table not found in production"
    continue
  fi

  if [ -z "$TEST_COLS" ]; then
    echo "  ❌ Table exists in production but NOT in test database!"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Compare
  if [ "$PROD_COLS" = "$TEST_COLS" ]; then
    echo "  ✅ Schemas match"
  else
    echo "  ❌ Schema mismatch detected!"
    echo ""
    echo "  Production columns:"
    echo "$PROD_COLS" | sed 's/^/    /'
    echo ""
    echo "  Test columns:"
    echo "$TEST_COLS" | sed 's/^/    /'
    echo ""

    # Show differences
    MISSING_IN_TEST=$(comm -23 <(echo "$PROD_COLS") <(echo "$TEST_COLS"))
    EXTRA_IN_TEST=$(comm -13 <(echo "$PROD_COLS") <(echo "$TEST_COLS"))

    if [ -n "$MISSING_IN_TEST" ]; then
      echo "  Missing in test:"
      echo "$MISSING_IN_TEST" | sed 's/^/    - /'
      echo ""
    fi

    if [ -n "$EXTRA_IN_TEST" ]; then
      echo "  Extra in test:"
      echo "$EXTRA_IN_TEST" | sed 's/^/    - /'
      echo ""
    fi

    ERRORS=$((ERRORS + 1))
  fi
  echo ""
done

echo "========================================"
if [ $ERRORS -eq 0 ]; then
  echo "✅ All schemas match!"
  echo "========================================"
  exit 0
else
  echo "❌ Found $ERRORS schema mismatch(es)"
  echo "========================================"
  echo ""
  echo "Action required:"
  echo "1. Update db/test_migration.rb to match production schema"
  echo "2. Run: bundle exec rake db:drop db:create db:test:prepare"
  echo "3. Run this script again to verify"
  echo ""
  echo "See: docs/solutions/database-issues/column-naming-mismatch-prevention.md"
  echo ""
  exit 1
fi
