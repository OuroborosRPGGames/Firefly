# frozen_string_literal: true

#!/usr/bin/env ruby

# Simple script to test the new models

require_relative 'config/application'

puts "Testing database connection..."

begin
  # Test basic connection
  puts "Database connection successful: #{DB.test_connection}"
  
  # Test that we can query existing tables
  puts "\nExisting tables:"
  DB.tables.each { |table| puts "  - #{table}" }
  
  # If characters table exists, test the existing model
  if DB.table_exists?(:characters)
    puts "\nTesting existing Character model..."
    character_count = Character.count
    puts "Found #{character_count} characters"
    
    if character_count > 0
      latest_char = Character.order(:created_at).last
      puts "Latest character: #{latest_char.name || latest_char.forename}"
    end
  end
  
  # Test creating a simple user if the table exists
  if DB.table_exists?(:users)
    puts "\nTesting User model..."
    user_count = User.count
    puts "Found #{user_count} users"
  end
  
rescue => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5)
end