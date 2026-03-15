#!/bin/bash
# scripts/schema_check.sh - Check database schema before creating models
#
# Usage: ./scripts/schema_check.sh <table_name>
#
# This script helps prevent schema mismatch errors by showing you
# the actual production schema before you write a model.

set -e

TABLE_NAME=$1
if [ -z "$TABLE_NAME" ]; then
  echo "Usage: ./scripts/schema_check.sh <table_name>"
  echo ""
  echo "Examples:"
  echo "  ./scripts/schema_check.sh media_library"
  echo "  ./scripts/schema_check.sh graffiti"
  echo "  ./scripts/schema_check.sh saved_locations"
  exit 1
fi

PROD_DB="postgres://prom_user:prom_password@localhost/firefly"
RAVEN_DB="postgres://cyber:cyber@localhost/ravencroft"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║ SCHEMA CHECK: $TABLE_NAME"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Check if table exists in production
echo "═══ STEP 1: Check if table exists in production ═══"
if psql $PROD_DB -c "\dt $TABLE_NAME" 2>/dev/null | grep -q "$TABLE_NAME"; then
  echo "✅ Table EXISTS in production database"
  echo "⚠️  IMPORTANT: You MUST match the existing schema!"
  TABLE_EXISTS=1
else
  echo "❌ Table does NOT exist in production"
  echo "✅ Safe to create new table with standard column names"
  TABLE_EXISTS=0
fi
echo ""

# If table doesn't exist, we can exit early
if [ $TABLE_EXISTS -eq 0 ]; then
  echo "═══ RECOMMENDATION ═══"
  echo "Since the table doesn't exist, you can:"
  echo "1. Create migration with standard column names"
  echo "2. Create model without column mappings"
  echo "3. Update test_migration.rb with your new schema"
  exit 0
fi

# Step 2: Show production schema
echo "═══ STEP 2: Production Schema ═══"
psql $PROD_DB -c "\d $TABLE_NAME"
echo ""

# Step 3: Check Ravencroft reference
echo "═══ STEP 3: Ravencroft Reference Schema ═══"
if psql $RAVEN_DB -c "\dt $TABLE_NAME" 2>/dev/null | grep -q "$TABLE_NAME"; then
  echo "✅ Table also exists in Ravencroft (legacy reference)"
  psql $RAVEN_DB -c "\d $TABLE_NAME"
else
  echo "ℹ️  Table not found in Ravencroft reference database"
fi
echo ""

# Step 4: Column details for copy-paste
echo "═══ STEP 4: Column Details (for documentation) ═══"
psql $PROD_DB -c "
SELECT
  column_name,
  data_type,
  CASE WHEN character_maximum_length IS NOT NULL
       THEN '(' || character_maximum_length || ')'
       ELSE '' END AS length,
  CASE WHEN is_nullable = 'YES' THEN 'NULL' ELSE 'NOT NULL' END AS nullable,
  COALESCE(column_default, '-') AS default_value
FROM information_schema.columns
WHERE table_name='$TABLE_NAME'
ORDER BY ordinal_position;
"
echo ""

# Step 5: Foreign keys
echo "═══ STEP 5: Foreign Keys ═══"
FK_COUNT=$(psql $PROD_DB -t -c "
SELECT COUNT(*)
FROM information_schema.table_constraints tc
WHERE tc.table_name='$TABLE_NAME' AND tc.constraint_type = 'FOREIGN KEY';
" | tr -d ' ')

if [ "$FK_COUNT" -gt 0 ]; then
  psql $PROD_DB -c "
SELECT
  tc.constraint_name,
  kcu.column_name AS fk_column,
  ccu.table_name AS references_table,
  ccu.column_name AS references_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
WHERE tc.table_name='$TABLE_NAME' AND tc.constraint_type = 'FOREIGN KEY';
"
else
  echo "ℹ️  No foreign keys found"
fi
echo ""

# Step 6: Indexes
echo "═══ STEP 6: Indexes ═══"
IDX_COUNT=$(psql $PROD_DB -t -c "
SELECT COUNT(*)
FROM pg_indexes
WHERE tablename = '$TABLE_NAME';
" | tr -d ' ')

if [ "$IDX_COUNT" -gt 0 ]; then
  psql $PROD_DB -c "
SELECT
  indexname,
  indexdef
FROM pg_indexes
WHERE tablename = '$TABLE_NAME'
ORDER BY indexname;
"
else
  echo "ℹ️  No indexes found"
fi
echo ""

# Step 7: Primary key analysis
echo "═══ STEP 7: Primary Key ═══"
PK_COLS=$(psql $PROD_DB -t -c "
SELECT string_agg(kcu.column_name, ', ')
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
WHERE tc.table_name='$TABLE_NAME' AND tc.constraint_type = 'PRIMARY KEY'
GROUP BY tc.constraint_name;
" | tr -d ' ')

if [ -z "$PK_COLS" ]; then
  echo "⚠️  NO PRIMARY KEY FOUND"
  echo "   You may need: unrestrict_primary_key"
else
  # Count commas to determine if composite
  COMMA_COUNT=$(echo "$PK_COLS" | tr -cd ',' | wc -c)
  if [ "$COMMA_COUNT" -gt 0 ]; then
    echo "⚠️  COMPOSITE PRIMARY KEY: [$PK_COLS]"
    echo "   Add to model:"
    echo "   unrestrict_primary_key"
    echo "   set_primary_key [:${PK_COLS//,/, :}]"
  else
    echo "✅ Single column primary key: $PK_COLS"
  fi
fi
echo ""

# Step 8: Legacy naming pattern detection
echo "═══ STEP 8: Legacy Naming Pattern Detection ═══"
LEGACY_PATTERNS=$(psql $PROD_DB -t -c "
SELECT column_name
FROM information_schema.columns
WHERE table_name='$TABLE_NAME'
  AND (
    column_name LIKE 'g\_%' OR
    column_name LIKE 'd\_%' OR
    column_name LIKE 'm%' OR
    column_name ~ '^[a-z](type|name|text|desc)$'
  );
")

if [ -n "$LEGACY_PATTERNS" ]; then
  echo "⚠️  LEGACY RAVENCROFT PATTERNS DETECTED:"
  echo "$LEGACY_PATTERNS" | while read -r col; do
    if [ -n "$col" ]; then
      case "$col" in
        g_*)
          echo "   $col → Graffiti prefix (map to ${col#g_})"
          ;;
        d_*)
          echo "   $col → Decoration prefix (map to ${col#d_})"
          ;;
        m*)
          echo "   $col → Media abbreviation (check if mtype→media_type, mname→name, mtext→content)"
          ;;
        *type|*name|*text|*desc)
          echo "   $col → Abbreviated column (consider mapping)"
          ;;
      esac
    fi
  done
  echo ""
  echo "🔧 RECOMMENDATION: Use accessor methods for column mapping"
else
  echo "✅ No obvious legacy patterns detected"
fi
echo ""

# Step 9: Recommendations
echo "═══ STEP 9: Next Steps ═══"
echo ""
echo "1. Document schema:"
echo "   vim docs/schema/${TABLE_NAME}.md"
echo ""
echo "2. Create model with column mappings:"
echo "   vim app/models/${TABLE_NAME}.rb"
echo ""
echo "3. Update test migration to match production:"
echo "   vim db/test_migration.rb"
echo ""
echo "4. Write tests:"
echo "   vim spec/models/${TABLE_NAME}_spec.rb"
echo ""
echo "5. Verify schema parity:"
echo "   ./scripts/verify_schema_parity.sh"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "See also: docs/solutions/database-issues/legacy-schema-prevention-strategies.md"
echo ""
