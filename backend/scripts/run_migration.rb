# frozen_string_literal: true

#!/usr/bin/env ruby

require 'sequel'

DB = Sequel.connect(
  adapter: 'postgres',
  host: 'localhost',
  database: 'firefly',
  user: 'prom_user',
  password: 'prom_password'
)

# Load the migration file
migration_path = File.join(__dir__, '../db/migrations/014_add_coordinates_to_worlds_and_areas.rb')
migration_content = File.read(migration_path)

# Create a temporary migration class
migration_class = Class.new(Sequel::Migration)
migration_class.class_eval(migration_content)

# Create migration instance and run it
migration = migration_class.new(DB)

puts "Running migration: Add coordinates to worlds and areas..."
begin
  migration.apply(DB, :up)
  puts "✅ Migration completed successfully!"
rescue => e
  puts "❌ Migration failed: #{e.message}"
  puts e.backtrace
end