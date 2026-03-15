# frozen_string_literal: true

require_relative '../app'
require 'json'

# Export all helpfile descriptions to JSON format
# Run: bundle exec ruby scripts/export_helpfile_descriptions_json.rb

OUTPUT_FILE = File.join(__dir__, '../db/seeds/helpfile_descriptions.json')

puts "Exporting helpfile descriptions to JSON..."

# Get all helpfiles with descriptions
helpfiles = Helpfile.exclude(description: nil)
                    .where { Sequel.lit("description != ''") }
                    .order(:command_name)
                    .all

if helpfiles.empty?
  puts "No helpfiles with descriptions found."
  exit 0
end

# Build hash of command_name => description
descriptions = {}
helpfiles.each do |hf|
  descriptions[hf.command_name] = hf.description
end

# Write to JSON file
File.write(OUTPUT_FILE, JSON.pretty_generate(descriptions))

puts "✓ Exported #{helpfiles.count} helpfile descriptions to:"
puts "  #{OUTPUT_FILE}"
puts ""
puts "File size: #{File.size(OUTPUT_FILE)} bytes"
