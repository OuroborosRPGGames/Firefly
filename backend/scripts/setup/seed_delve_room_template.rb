#!/usr/bin/env ruby
# frozen_string_literal: true

# Seed the delve room template for TemporaryRoomPoolService.
#
# Usage:
#   bundle exec ruby scripts/setup/seed_delve_room_template.rb
#
# This creates a standard template used by TemporaryRoomPoolService
# to instantiate temporary rooms for delve dungeon encounters.

require_relative '../../config/application'

RoomTemplate.find_or_create(template_type: 'delve_room') do |t|
  t.name = 'Delve Room'
  t.category = 'delve'
  t.room_type = 'dungeon'
  t.short_description = 'A dark dungeon chamber.'
  t.long_description = 'Stone walls surround you. The air is damp and cold.'
  t.width = 30
  t.length = 30
  t.height = 10
  t.active = true
end

puts 'Delve room template seeded.'
