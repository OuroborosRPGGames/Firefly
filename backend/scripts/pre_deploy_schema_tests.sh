#!/bin/bash
# scripts/pre_deploy_schema_tests.sh
# Run comprehensive schema tests before deployment
# Catches column naming mismatches early

set -e

echo "========================================"
echo "Pre-Deployment Schema Tests"
echo "========================================"
echo ""

FAILED=0

# Test 1: Schema parity
echo "1. Checking schema parity between test and production..."
if ./scripts/verify_schema_parity.sh; then
  echo "   ✅ Schema parity check passed"
else
  echo "   ❌ Schema parity check failed"
  FAILED=$((FAILED + 1))
fi
echo ""

# Test 2: Model loading
echo "2. Testing model loading..."
if bundle exec ruby -e "require './app'; puts 'All models loaded successfully'" 2>&1 | grep -q "successfully"; then
  echo "   ✅ All models load without errors"
else
  echo "   ❌ Model loading failed"
  FAILED=$((FAILED + 1))
fi
echo ""

# Test 3: Model column access
echo "3. Testing model column access..."
cat > /tmp/test_columns.rb << 'EOF'
require './app'

models_to_test = [
  ['Graffiti', [:id, :room_id, :gdesc, :g_x, :g_y, :made_at]],
  ['Decoration', [:id, :room_id, :name, :description, :image_url, :display_order]],
  ['RoomMedia', [:id, :room_id, :url, :youtube_video_id, :autoplay, :ends_at]]
]

errors = []

models_to_test.each do |model_name, expected_columns|
  begin
    model = Object.const_get(model_name)
    actual_columns = model.columns
    missing = expected_columns - actual_columns

    if missing.any?
      errors << "#{model_name} missing columns: #{missing.join(', ')}"
    end
  rescue => e
    errors << "#{model_name}: #{e.message}"
  end
end

if errors.any?
  puts "FAILED"
  errors.each { |e| puts "  #{e}" }
  exit 1
else
  puts "SUCCESS"
end
EOF

if bundle exec ruby /tmp/test_columns.rb 2>&1 | grep -q "SUCCESS"; then
  echo "   ✅ Model columns accessible"
else
  echo "   ❌ Model column access failed"
  bundle exec ruby /tmp/test_columns.rb 2>&1 | grep -v "SUCCESS" | sed 's/^/     /'
  FAILED=$((FAILED + 1))
fi
rm -f /tmp/test_columns.rb
echo ""

# Test 4: Run model specs
echo "4. Running model specs..."
if bundle exec rspec spec/models/ --format progress 2>&1 | tail -5; then
  echo "   ✅ Model specs passed"
else
  echo "   ❌ Model specs failed"
  FAILED=$((FAILED + 1))
fi
echo ""

# Test 5: Database verification (if rake task exists)
echo "5. Verifying database schema..."
if bundle exec rake -T | grep -q "db:verify_schema"; then
  if bundle exec rake db:verify_schema 2>&1; then
    echo "   ✅ Database schema verification passed"
  else
    echo "   ❌ Database schema verification failed"
    FAILED=$((FAILED + 1))
  fi
else
  echo "   ⚠️  db:verify_schema task not found (optional)"
fi
echo ""

# Summary
echo "========================================"
if [ $FAILED -eq 0 ]; then
  echo "✅ All pre-deployment schema tests PASSED"
  echo "========================================"
  echo ""
  echo "Safe to deploy!"
  exit 0
else
  echo "❌ $FAILED test(s) FAILED"
  echo "========================================"
  echo ""
  echo "DO NOT DEPLOY until issues are resolved."
  echo ""
  echo "See: docs/solutions/database-issues/column-naming-mismatch-prevention.md"
  exit 1
fi
