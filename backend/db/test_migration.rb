# frozen_string_literal: true

# TestMigration — ensures the test database exists and schema is current.
# Called from spec_helper.rb before test suite runs.

module TestMigration
  def self.run(db)
    migrations_dir = File.expand_path('migrations', __dir__)
    Sequel::Migrator.run(db, migrations_dir)
  rescue Sequel::DatabaseError => e
    # If vector extension is missing, try to create it
    if e.message.include?('extension "vector"')
      db.run('CREATE EXTENSION IF NOT EXISTS vector')
      retry
    end
    raise
  end
end
