# frozen_string_literal: true

# Per-user library of saved NPC spawn locations.
# Allows users to bookmark rooms for quick selection when configuring NPC schedules.
#
# @example Save a location
#   NpcSpawnLocation.create(user: current_user, room: room, name: 'Town Square')
#
# @example Find user's saved locations
#   NpcSpawnLocation.for_user(current_user)
#
class NpcSpawnLocation < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :user
  many_to_one :room

  def validate
    super
    validates_presence [:user_id, :room_id, :name]
    validates_max_length 100, :name
    validates_max_length 500, :notes, allow_nil: true
    validates_unique [:user_id, :name], message: 'already exists in your library'
  end

  # Get all saved locations for a user
  # @param user [User] the user
  # @return [Sequel::Dataset] ordered by name
  def self.for_user(user)
    where(user_id: user.id).order(:name)
  end

  # Find a location by name (case-insensitive)
  # @param user [User] the user
  # @param name [String] location name to search
  # @return [NpcSpawnLocation, nil]
  def self.find_by_name(user, name)
    first(user_id: user.id) { Sequel.ilike(:name, name) }
  end

  # Formatted display string for room
  # @return [String] room name with location context
  def room_display
    location_name = room&.location&.name || 'Unknown Area'
    "#{room&.name} (#{location_name})"
  end

  # Short description for dropdowns
  # @return [String]
  def dropdown_text
    "#{name} - #{room&.name}"
  end
end
