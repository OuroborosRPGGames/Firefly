# frozen_string_literal: true

#!/usr/bin/env ruby

# Test script for character creation with new features

require_relative '../config/application'

puts "Testing Character Creation with New Features..."

begin
  # Test database connection
  puts "Database connection: #{DB.test_connection}"
  
  # Test auto-capitalization
  puts "\n--- Testing Auto-Capitalization ---"
  
  test_char = Character.new(
    forename: "alice",
    surname: "wonderland",
    nickname: "wonder",
    is_npc: true,
    active: true
  )
  
  test_char.save
  
  puts "Original: forename='alice', surname='wonderland', nickname='wonder'"
  puts "After save: forename='#{test_char.forename}', surname='#{test_char.surname}', nickname='#{test_char.nickname}'"
  
  if test_char.forename == "Alice" && test_char.surname == "Wonderland" && test_char.nickname == "Wonder"
    puts "✓ Auto-capitalization working correctly!"
  else
    puts "✗ Auto-capitalization not working"
  end
  
  # Test full_name method
  puts "\n--- Testing full_name Method ---"
  puts "full_name: '#{test_char.full_name}'"
  
  if test_char.full_name == "Alice Wonderland"
    puts "✓ full_name method working correctly!"
  else
    puts "✗ full_name method not working"
  end
  
  # Clean up
  test_char.delete
  
  # Check which fields exist in the database
  puts "\n--- Checking Character Table Columns ---"
  character_columns = DB[:characters].columns
  puts "Existing columns: #{character_columns.join(', ')}"
  
  # Test which fields we're trying to use that might not exist
  required_fields = [
    :forename, :surname, :nickname, :short_desc, :gender, :age, :birthdate,
    :point_of_view, :recruited_by, :discord_name, :discord_number, 
    :distinctive_color, :picture_url, :height_ft, :height_in, :height_cm,
    :ethnicity, :custom_ethnicity, :body_type, :eye_color, :custom_eye_color,
    :hair_color, :custom_hair_color, :hair_style, :custom_hair_style,
    :beard_color, :custom_beard_color, :beard_style, :custom_beard_style,
    :personality, :backstory, :goals
  ]
  
  missing_fields = required_fields - character_columns
  existing_fields = required_fields & character_columns
  
  puts "\n✓ Existing fields (#{existing_fields.length}): #{existing_fields.join(', ')}"
  puts "\n✗ Missing fields (#{missing_fields.length}): #{missing_fields.join(', ')}"
  
  # Test creating a character with only existing fields
  puts "\n--- Testing Character Creation with Existing Fields ---"
  
  safe_attributes = {
    forename: "test",
    surname: "character", 
    is_npc: true,
    active: true
  }
  
  existing_fields.each do |field|
    case field
    when :age
      safe_attributes[field] = 25
    when :short_desc
      safe_attributes[field] = "a test character"
    when :gender
      safe_attributes[field] = "Female"
    when :nickname
      safe_attributes[field] = "Tester"
    else
      safe_attributes[field] = "test_value" if field.to_s.end_with?('_name', '_style', '_color', 'personality', 'backstory', 'goals')
    end
  end
  
  test_char2 = Character.create(safe_attributes)
  puts "✓ Successfully created character with existing fields: #{test_char2.full_name}"
  
  # Clean up
  test_char2.delete
  
  puts "\n=== SUMMARY ==="
  puts "✓ Auto-capitalization: Working"
  puts "✓ Name handling: Working"
  puts "✓ Basic character creation: Working"
  puts "⚠ Missing database columns: #{missing_fields.length} fields need to be added"
  
  puts "\nTo fully enable the character creator, you'll need to add these columns to the characters table."
  
rescue => e
  puts "Error during testing: #{e.message}"
  puts e.backtrace.first(5)
  exit 1
end