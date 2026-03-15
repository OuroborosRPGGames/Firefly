# frozen_string_literal: true

#!/usr/bin/env ruby

# Script to create a test user for development

require_relative '../config/application'

puts "Creating test user for development..."

begin
  # Check if test user already exists
  existing_user = User.where(Sequel.ilike(:username, 'firefly_test')).first

  if existing_user
    puts "Test user already exists:"
    puts "  Username: Firefly_Test"
    puts "  Email: test@firefly.local"
    puts "  Password: firefly_test_2024"
    puts "  ID: #{existing_user.id}"
  else
    # Create new test user
    test_user = User.new(
      username: 'Firefly_Test',
      email: 'test@firefly.local',
      is_test_account: true
    )

    # Set password
    test_user.set_password('firefly_test_2024')

    # Save user
    test_user.save

    puts "Test user created successfully!"
    puts "  Username: Firefly_Test"
    puts "  Email: test@firefly.local"
    puts "  Password: firefly_test_2024"
    puts "  ID: #{test_user.id}"

    # Create a test character for this user
    test_character = Character.create(
      user_id: test_user.id,
      forename: 'Test',
      surname: 'Account',
      nickname: 'Tester',
      short_desc: 'A test account for exploring the MUD',
      gender: 'Androgynous',
      age: 25,
      birthdate: '1999-01-01',
      point_of_view: 'Third',
      distinctive_color: '#87ceeb',
      ethnicity: 'Digital',
      body_type: 'Average-build',
      eye_color: 'Blue',
      hair_color: 'Silver',
      hair_style: 'Short',
      personality: 'Helpful, curious, and analytical',
      backstory: 'A test account for exploring and testing the Firefly MUD system.',
      goals: 'To help test the MUD experience for all players.',
      is_npc: false,
      active: true
    )

    puts "\nTest character created:"
    puts "  Name: #{test_character.full_name}"
    puts "  ID: #{test_character.id}"
  end

  puts "\nYou can now log in at /login with these credentials"
  puts "This will give you access to all protected pages for testing."

rescue => e
  puts "Error creating test user: #{e.message}"
  puts e.backtrace.first(5)
end
