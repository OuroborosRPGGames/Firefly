# frozen_string_literal: true

# This spec ensures test_migration.rb stays in sync with the actual database schema.
# When this spec fails, it means:
# 1. A migration was added but test_migration.rb wasn't updated
# 2. test_migration.rb creates tables that don't exist in production
# 3. Columns are missing or different between test_migration and production
#
# To fix: Update db/test_migration.rb to match the current schema

RSpec.describe 'Schema synchronization' do
  # Tables that are intentionally different between test and production
  IGNORED_TABLES = %i[
    schema_info
    schema_migrations
  ].freeze

  # Tables that exist in test_migration but not in production
  # (e.g., tables that require extensions like pgvector)
  # Add tables here only if they're conditionally created based on environment
  CONDITIONAL_TABLES = %i[
    embeddings  # Requires pgvector extension - migration 086 only creates if pgvector installed
  ].freeze

  describe 'table-level sync' do
    let(:production_tables) do
      # Use the production database to get actual tables
      prod_db = Sequel.connect(
        ENV['PRODUCTION_DATABASE_URL'] ||
        'postgres://prom_user:prom_password@localhost/firefly'
      )
      tables = prod_db.tables - IGNORED_TABLES
      prod_db.disconnect
      tables.sort
    end

    let(:test_migration_tables) do
      # Extract table names from test_migration.rb
      test_migration_file = File.read(File.join(__dir__, '../../db/test_migration.rb'))
      # Match both create_table(:name) and create_table?(:name) patterns
      tables = test_migration_file.scan(/create_table\??\s*\(:(\w+)\)/).flatten.map(&:to_sym)
      tables.sort - CONDITIONAL_TABLES
    end

    it 'test_migration creates all production tables' do
      missing_in_test = production_tables - test_migration_tables - CONDITIONAL_TABLES

      if missing_in_test.any?
        missing_list = missing_in_test.map { |t| "  - #{t}" }.join("\n")
        fail <<~MSG
          Tables exist in production but are MISSING from test_migration.rb:
          #{missing_list}

          To fix: Add these tables to backend/db/test_migration.rb
          Check the corresponding migrations in backend/db/migrations/ for the table definitions.
        MSG
      end
    end

    it 'test_migration does not create non-existent tables' do
      extra_in_test = test_migration_tables - production_tables - CONDITIONAL_TABLES

      if extra_in_test.any?
        extra_list = extra_in_test.map { |t| "  - #{t}" }.join("\n")
        fail <<~MSG
          Tables in test_migration.rb do NOT exist in production:
          #{extra_list}

          To fix: Either:
          1. Remove these tables from backend/db/test_migration.rb, OR
          2. Add them to CONDITIONAL_TABLES if they depend on extensions like pgvector, OR
          3. Create a migration to add the table to production
        MSG
      end
    end
  end

  describe 'column-level sync for critical tables' do
    # Tables that are critical and should have exact column matching
    CRITICAL_TABLES = %i[
      users
      characters
      character_instances
      rooms
      locations
      events
      fights
    ].freeze

    let(:production_db) do
      Sequel.connect(
        ENV['PRODUCTION_DATABASE_URL'] ||
        'postgres://prom_user:prom_password@localhost/firefly'
      )
    end

    after do
      production_db.disconnect if production_db
    end

    CRITICAL_TABLES.each do |table_name|
      next unless DB.table_exists?(table_name)

      describe "#{table_name} table" do
        let(:production_columns) do
          if production_db.table_exists?(table_name)
            production_db.schema(table_name).map { |col| col[0] }.sort
          else
            []
          end
        end

        let(:test_columns) do
          if DB.table_exists?(table_name)
            DB.schema(table_name).map { |col| col[0] }.sort
          else
            []
          end
        end

        it 'has matching columns between test and production' do
          skip "Table #{table_name} doesn't exist in production" if production_columns.empty?
          skip "Table #{table_name} doesn't exist in test" if test_columns.empty?

          missing_in_test = production_columns - test_columns
          extra_in_test = test_columns - production_columns

          issues = []

          if missing_in_test.any?
            issues << "Columns in production but MISSING from test_migration:\n" +
                     missing_in_test.map { |c| "  - #{c}" }.join("\n")
          end

          if extra_in_test.any?
            issues << "Columns in test_migration but NOT in production:\n" +
                     extra_in_test.map { |c| "  - #{c}" }.join("\n")
          end

          if issues.any?
            fail <<~MSG
              Column mismatch in #{table_name} table:

              #{issues.join("\n\n")}

              To fix: Update the #{table_name} table definition in backend/db/test_migration.rb
              Check backend/db/migrations/ for the correct column definitions.
            MSG
          end
        end
      end
    end
  end

  describe 'migration file sync' do
    let(:latest_migration_number) do
      migration_files = Dir[File.join(__dir__, '../../db/migrations/*.rb')]
      # Only consider sequential migrations (< 100000), not timestamp-based ones
      migration_files.map { |f| File.basename(f).split('_').first.to_i }.select { |n| n < 100_000 }.max
    end

    let(:test_migration_comment_number) do
      test_migration_file = File.read(File.join(__dir__, '../../db/test_migration.rb'))
      # Look for a comment like "# Synced with migration 272"
      match = test_migration_file.match(/# Synced with migration (\d+)/)
      match ? match[1].to_i : nil
    end

    it 'test_migration indicates which migration it is synced with' do
      unless test_migration_comment_number
        pending <<~MSG
          Add a sync marker comment to test_migration.rb, e.g.:
          # Synced with migration #{latest_migration_number}
        MSG
      end
    end

    it 'test_migration is synced with latest migration' do
      skip 'No sync marker in test_migration.rb' unless test_migration_comment_number

      if test_migration_comment_number < latest_migration_number
        fail <<~MSG
          test_migration.rb is out of sync!

          test_migration synced with: migration #{test_migration_comment_number}
          Latest migration: #{latest_migration_number}

          Migrations needing sync: #{test_migration_comment_number + 1} through #{latest_migration_number}

          To fix: Apply changes from migrations #{test_migration_comment_number + 1}-#{latest_migration_number}
          to backend/db/test_migration.rb, then update the sync marker.
        MSG
      end
    end
  end
end
