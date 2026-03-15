# frozen_string_literal: true

# Provides character lookup helpers to reduce duplication of common queries.
#
# Consolidates the repeated CharacterInstance.where(..., online: true) patterns
# found across many services.
#
# Usage:
#   class MyService
#     include CharacterLookupHelper
#
#     def process
#       characters = find_characters_in_room(room_id)
#       # ...
#     end
#   end
#
module CharacterLookupHelper
  # Find an online character instance by character ID
  #
  # @param character_id [Integer] The character's ID
  # @return [CharacterInstance, nil] The online instance or nil
  def find_online_character(character_id)
    return nil if character_id.nil?

    CharacterInstance.where(character_id: character_id, online: true).first
  end

  # Find all online character instances in a specific room
  #
  # @param room_id [Integer] The room's ID
  # @param eager [Array<Symbol>] Associations to eager load (default: [:character])
  # @return [Array<CharacterInstance>] Online characters in the room
  def find_characters_in_room(room_id, eager: [:character])
    return [] if room_id.nil?

    query = CharacterInstance.where(current_room_id: room_id, online: true)
    query = query.eager(*eager) if eager.any?
    query.all
  end

  # Find all online character instances across all rooms
  #
  # @param eager [Array<Symbol>] Associations to eager load (default: [:character])
  # @return [Array<CharacterInstance>] All online character instances
  def find_all_online_characters(eager: [:character])
    query = CharacterInstance.where(online: true)
    query = query.eager(*eager) if eager.any?
    query.all
  end

  # Find online staff members with staff vision enabled
  #
  # @return [Array<CharacterInstance>] Staff with vision enabled
  def find_online_staff_with_vision
    CharacterInstance.where(online: true, staff_vision_enabled: true).all
  end

  # Find all online characters except one (useful for broadcasts)
  #
  # @param room_id [Integer] The room's ID
  # @param exclude_id [Integer] CharacterInstance ID to exclude
  # @param eager [Array<Symbol>] Associations to eager load (default: [:character])
  # @return [Array<CharacterInstance>] Online characters excluding the specified one
  def find_others_in_room(room_id, exclude_id:, eager: [:character])
    return [] if room_id.nil?

    query = CharacterInstance.where(current_room_id: room_id, online: true)
                             .exclude(id: exclude_id)
    query = query.eager(*eager) if eager.any?
    query.all
  end

  # Find a character by name, searching room first then globally
  # Uses TargetResolverService for consistent matching across commands
  #
  # Common pattern used by finger, profile, and info commands
  # Searches local room first (respects reality), then all online characters
  #
  # @param name [String] The character name to search for
  # @param room [Room] The current room to search first
  # @param reality_id [Integer, nil] Reality dimension to filter by
  # @param exclude_instance_id [Integer, nil] CharacterInstance ID to exclude
  # @return [CharacterInstance, nil] The matched character instance or nil
  def find_character_room_then_global(name, room:, reality_id: nil, exclude_instance_id: nil, viewer: nil)
    return nil if StringHelper.blank?(name)

    # First check current room
    room_query = CharacterInstance.where(
      current_room_id: room&.id,
      status: 'alive'
    ).eager(:character)
    room_query = room_query.where(reality_id: reality_id) if reality_id
    room_query = room_query.exclude(id: exclude_instance_id) if exclude_instance_id
    room_chars = room_query.all

    room_match = TargetResolverService.resolve_character(
      query: name,
      candidates: room_chars,
      viewer: viewer
    )
    return room_match if room_match

    # Search globally for online characters
    global_query = CharacterInstance.where(online: true, status: 'alive').eager(:character)
    global_query = global_query.where(reality_id: reality_id) if reality_id
    global_query = global_query.exclude(id: exclude_instance_id) if exclude_instance_id
    global_chars = global_query.all

    TargetResolverService.resolve_character(
      query: name,
      candidates: global_chars,
      viewer: viewer
    )
  end

  # Find a character by name globally (all characters in database)
  # Uses TargetResolverService for consistent matching
  #
  # More efficient than Character.all.find {} anti-pattern
  # Returns Character, not CharacterInstance
  #
  # @param name [String] The character name to search for
  # @param limit [Integer] Max characters to search (default: 500)
  # @return [Character, nil] The matched character or nil
  def find_character_by_name_globally(name, limit: 500)
    return nil if StringHelper.blank?(name)

    name_lower = name.downcase.strip

    # Try exact forename match first (efficient query)
    exact = Character.where(Sequel.ilike(:forename, name_lower)).first
    return exact if exact

    # Try exact full name (forename + surname) with efficient query
    # Look for characters where forename or full_name matches
    candidates = Character.limit(limit).all
    TargetResolverService.resolve_character(
      query: name_lower,
      candidates: candidates,
      forename_field: :forename,
      full_name_method: :full_name
    )
  end
end
