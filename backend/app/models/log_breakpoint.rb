# frozen_string_literal: true

# LogBreakpoint tracks session boundaries for RP log pagination
#
# Types:
# - Wake: Character logged in
# - Sleep: Character logged out
# - Move: Character changed rooms
# - RP: Manual RP session marker
#
class LogBreakpoint < Sequel::Model
  plugin :timestamps

  many_to_one :character_instance
  many_to_one :target, class: :CharacterInstance, key: :target_id
  many_to_one :room

  BREAKPOINT_TYPES = %w[Wake Sleep Move RP].freeze

  def validate
    super
    errors.add(:breakpoint_type, 'must be valid') unless BREAKPOINT_TYPES.include?(breakpoint_type)
    errors.add(:character_instance_id, 'is required') unless character_instance_id
  end

  # Get recent breakpoints for a character
  # @param character_instance [CharacterInstance]
  # @param limit [Integer]
  # @return [Array<LogBreakpoint>]
  def self.recent_for(character_instance, limit: 20)
    where(character_instance_id: character_instance.id)
      .order(Sequel.desc(:happened_at))
      .limit(limit)
  end

  # Get session boundaries (Wake/Sleep pairs) for pagination
  # @param character_instance [CharacterInstance]
  # @param limit [Integer]
  # @return [Array<LogBreakpoint>]
  def self.sessions_for(character_instance, limit: 20)
    where(character_instance_id: character_instance.id)
      .where(breakpoint_type: %w[Wake Sleep])
      .order(Sequel.desc(:happened_at))
      .limit(limit)
  end

  # Create a Wake breakpoint (login)
  # @param character_instance [CharacterInstance]
  # @return [LogBreakpoint]
  def self.record_login(character_instance)
    room = character_instance.current_room
    create(
      character_instance_id: character_instance.id,
      breakpoint_type: 'Wake',
      happened_at: Time.now,
      room_id: room&.id,
      room_title: room&.name,
      weather: room&.respond_to?(:current_weather_description) ? room.current_weather_description : nil
    )
  end

  # Create a Sleep breakpoint (logout)
  # @param character_instance [CharacterInstance]
  # @return [LogBreakpoint]
  def self.record_logout(character_instance)
    room = character_instance.current_room
    create(
      character_instance_id: character_instance.id,
      breakpoint_type: 'Sleep',
      happened_at: Time.now,
      room_id: room&.id,
      room_title: room&.name,
      weather: room&.respond_to?(:current_weather_description) ? room.current_weather_description : nil
    )
  end

  # Create a Move breakpoint (room change)
  # @param character_instance [CharacterInstance]
  # @param to_room [Room]
  # @return [LogBreakpoint]
  def self.record_move(character_instance, to_room)
    create(
      character_instance_id: character_instance.id,
      breakpoint_type: 'Move',
      subtype: to_room&.name,
      happened_at: Time.now,
      room_id: to_room&.id,
      room_title: to_room&.name,
      weather: to_room&.respond_to?(:current_weather_description) ? to_room.current_weather_description : nil
    )
  end

  # Format for API response
  # @return [Hash]
  def to_api_hash
    {
      id: id,
      type: breakpoint_type,
      subtype: subtype,
      happened_at: happened_at&.iso8601,
      room_name: room_title,
      weather: weather
    }
  end
end
