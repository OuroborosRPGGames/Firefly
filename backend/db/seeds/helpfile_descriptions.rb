# frozen_string_literal: true

# Helpfile Descriptions Seed
# Loads command descriptions from JSON file
# Run: bundle exec ruby db/seeds/helpfile_descriptions.rb

require 'json'
require_relative '../../app'

json_file = File.join(__dir__, 'helpfile_descriptions.json')

unless File.exist?(json_file)
  puts "Error: #{json_file} not found"
  puts "Run: bundle exec ruby scripts/export_helpfile_descriptions_json.rb"
  exit 1
end

puts "Loading helpfile descriptions from JSON..."

descriptions = JSON.parse(File.read(json_file))

puts "Updating #{descriptions.count} helpfile descriptions..."

count = 0
errors = []

descriptions.each do |command_name, description|
  helpfile = Helpfile.first(command_name: command_name)
  if helpfile
    helpfile.update(description: description)
    count += 1
    print '.'
  else
    errors << command_name
  end
end

puts "\n"
puts "✓ Seeded #{count} helpfile descriptions"

if errors.any?
  puts "\nWarning: #{errors.count} helpfiles not found:"
  errors.each { |cmd| puts "  - #{cmd}" }
end
