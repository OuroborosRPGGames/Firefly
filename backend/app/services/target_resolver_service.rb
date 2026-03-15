# frozen_string_literal: true

require_relative '../helpers/string_helper'
require_relative '../helpers/canvas_helper'

# TargetResolverService provides unified target resolution across all commands.
#
# Handles:
# - HTML stripping from colored descriptions
# - Multiple matching strategies (exact, prefix, contains)
# - Disambiguation via quickmenu when multiple matches found
# - Callback-based continuation for async disambiguation
#
# Usage:
#   # Simple resolution (returns single match or nil)
#   item = TargetResolverService.resolve(
#     query: "red shirt",
#     candidates: inventory_items,
#     name_field: :name
#   )
#
#   # With disambiguation support (returns match, quickmenu, or nil)
#   result = TargetResolverService.resolve_with_disambiguation(
#     query: "shirt",
#     candidates: shop_items,
#     name_field: :name,
#     description_field: :description,
#     character_instance: char_instance,
#     context: { command: 'buy', shop_id: shop.id }
#   )
#
class TargetResolverService
  extend StringHelper
  extend QueryHelper

  class << self
    # Simple resolution - returns best single match or nil
    # @param query [String] user's search query
    # @param candidates [Array] items to search through
    # @param name_field [Symbol] method to get item name (default: :name)
    # @param description_field [Symbol] method to get description (default: :description)
    # @param min_prefix_length [Integer] minimum chars for prefix match (default: 1)
    # @return [Object, nil] matched item or nil
    def resolve(query:, candidates:, name_field: :name, description_field: :description, min_prefix_length: 1)
      return nil if blank?(query)
      return nil if candidates.nil? || candidates.empty?

      query_lower = query.downcase.strip

      # Strategy 0: ID-based targeting (e.g., "#123") - used by disambiguation responses
      if query_lower.match?(/\A#\d+\z/)
        target_id = query_lower[1..].to_i
        id_match = candidates.find { |c| identifier_for(c) == target_id }
        return id_match if id_match
      end

      # Strategy 1: Exact match on name (strip HTML for items with gradient names)
      if name_field
        exact_name = candidates.find { |c| strip_html(field_value(c, name_field))&.downcase == query_lower }
        return exact_name if exact_name
      end

      # Strategy 2: Exact match on stripped description
      if description_field
        exact_desc = candidates.find { |c| strip_html(field_value(c, description_field))&.downcase == query_lower }
        return exact_desc if exact_desc
      end

      # Strategy 3: Prefix match on name (min length check, strip HTML)
      if name_field && query_lower.length >= min_prefix_length
        prefix_name = candidates.find { |c| strip_html(field_value(c, name_field))&.downcase&.start_with?(query_lower) }
        return prefix_name if prefix_name
      end

      # Strategy 3b: Unique short prefix match (bypass min_prefix_length if unambiguous)
      if name_field && query_lower.length >= 1 && query_lower.length < min_prefix_length
        prefix_matches = candidates.select { |c| strip_html(field_value(c, name_field))&.downcase&.start_with?(query_lower) }
        return prefix_matches.first if prefix_matches.length == 1
      end

      # Strategy 4: Prefix match on stripped description
      if description_field && query_lower.length >= min_prefix_length
        prefix_desc = candidates.find { |c| strip_html(field_value(c, description_field))&.downcase&.start_with?(query_lower) }
        return prefix_desc if prefix_desc
      end

      # Strategy 5: Contains match on name (strip HTML)
      if name_field && query_lower.length >= min_prefix_length
        contains_name = candidates.find { |c| strip_html(field_value(c, name_field))&.downcase&.include?(query_lower) }
        return contains_name if contains_name
      end

      # Strategy 6: Contains match on stripped description
      if description_field && query_lower.length >= min_prefix_length
        contains_desc = candidates.find { |c| strip_html(field_value(c, description_field))&.downcase&.include?(query_lower) }
        return contains_desc if contains_desc
      end

      # Strategy 7: Word-start (initials) match on name
      # "js" matches "John Smith", "jd" matches "Jane Doe"
      # Only matches if exactly one candidate has matching initials
      if name_field && query_lower.length >= 2
        initials_matches = candidates.select { |c| matches_word_starts?(query_lower, strip_html(field_value(c, name_field))) }
        return initials_matches.first if initials_matches.length == 1
      end

      # Strategy 8: Fuzzy match on name (typo tolerance)
      # "bbo" matches "Bob", "ailce" matches "Alice"
      # Only matches if exactly one candidate is within edit distance
      if name_field && query_lower.length >= min_prefix_length
        fuzzy_matches = candidates.select { |c| fuzzy_match?(query_lower, strip_html(field_value(c, name_field))) }
        return fuzzy_matches.first if fuzzy_matches.length == 1
      end

      nil
    end

    # Resolution with disambiguation - returns match, disambiguation result, or nil
    # @param query [String] user's search query
    # @param candidates [Array] items to search through
    # @param name_field [Symbol] method to get item name
    # @param description_field [Symbol] method to get description
    # @param display_field [Symbol] method to get display text for disambiguation menu
    # @param character_instance [CharacterInstance] for creating quickmenu
    # @param context [Hash] context data passed to callback
    # @param min_prefix_length [Integer] minimum chars for partial match (default: 1)
    # @param max_disambiguation [Integer] max items to show in disambiguation (default: 10)
    # @return [Hash] { match: Object } or { quickmenu: Hash } or { error: String }
    def resolve_with_disambiguation(
      query:,
      candidates:,
      name_field: :name,
      description_field: :description,
      display_field: nil,
      character_instance: nil,
      context: {},
      min_prefix_length: 1,
      max_disambiguation: 10
    )
      return { error: "What are you looking for?" } if blank?(query)
      return { error: "Nothing to search." } if candidates.nil? || candidates.empty?

      query_lower = query.downcase.strip
      display_field ||= description_field || name_field

      # ID-based targeting (e.g., "#123") - used by disambiguation responses
      if query_lower.match?(/\A#\d+\z/)
        target_id = query_lower[1..].to_i
        id_match = candidates.find { |c| identifier_for(c) == target_id }
        return { match: id_match } if id_match
      end

      # First try exact match
      exact = find_exact_match(query_lower, candidates, name_field, description_field)
      return { match: exact } if exact

      # Then find all partial matches
      return { error: "Search query too short (minimum #{min_prefix_length} characters)." } if query_lower.length < min_prefix_length

      matches = find_all_matches(query_lower, candidates, name_field, description_field)

      case matches.length
      when 0
        { error: "No match found for '#{query}'." }
      when 1
        { match: matches.first }
      else
        # Multiple matches - create disambiguation menu
        if character_instance
          create_disambiguation_menu(
            matches: matches.take(max_disambiguation),
            query: query,
            display_field: display_field,
            character_instance: character_instance,
            context: context.merge(
              resolver_candidates: matches.map { |m| identifier_for(m) },
              resolver_query: query
            )
          )
        else
          # No character instance - just return first match with warning
          { match: matches.first, warning: "Multiple matches found, using first." }
        end
      end
    end

    # Find item by identifier (used after disambiguation)
    # @param identifier [Integer, String] item ID or unique identifier
    # @param candidates [Array] items to search
    # @return [Object, nil]
    def find_by_identifier(identifier, candidates)
      candidates.find { |c| identifier_for(c).to_s == identifier.to_s }
    end

    # Note: strip_html is now available via StringHelper (extended at class level)

    # Character resolution with disambiguation - returns match, quickmenu, or error
    # Works with CharacterInstance (accessing .character) or Character directly
    # @param query [String] character name to find
    # @param candidates [Array<CharacterInstance, Character>] characters to search
    # @param character_instance [CharacterInstance] the character making the request (for quickmenu + viewer context)
    # @param context [Hash] context data passed to callback
    # @param forename_field [Symbol] field name for forename (default: uses .character.forename for CharacterInstance)
    # @param full_name_method [Symbol] method name for full name (default: uses .character.full_name for CharacterInstance)
    # @param min_prefix_length [Integer] minimum chars for partial match (default: 1)
    # @param max_disambiguation [Integer] max items to show in disambiguation (default: 10)
    # @return [Hash] { match: Object } or { quickmenu: Hash } or { error: String }
    def resolve_character_with_disambiguation(
      query:,
      candidates:,
      character_instance:,
      context: {},
      forename_field: nil,
      full_name_method: nil,
      min_prefix_length: 1,
      max_disambiguation: 10
    )
      return { error: "Who are you looking for?" } if blank?(query)
      return { error: "No one to search." } if candidates.nil? || candidates.empty?

      query_lower = query.downcase.strip

      # ID-based targeting (e.g., "#123") - used by disambiguation responses
      if query_lower.match?(/\A#\d+\z/)
        target_id = query_lower[1..].to_i
        id_match = candidates.find { |c| identifier_for(c) == target_id }
        return { match: id_match } if id_match
      end

      # Build accessor lambdas
      get_forename = build_forename_accessor(forename_field)
      get_full_name = build_full_name_accessor(full_name_method)
      get_display_name = build_display_name_accessor(character_instance)

      # Exact display name match (what the viewer actually sees)
      if get_display_name
        exact_display = candidates.find { |c| get_display_name.call(c)&.downcase == query_lower }
        return { match: exact_display } if exact_display
      end

      # Exact forename match
      exact_forename = candidates.find { |c| get_forename.call(c)&.downcase == query_lower }
      return { match: exact_forename } if exact_forename

      # Exact full name match
      exact_full = candidates.find { |c| get_full_name.call(c)&.downcase == query_lower }
      return { match: exact_full } if exact_full

      # Need minimum length for fuzzy matching
      return { error: "Search query too short (minimum #{min_prefix_length} characters)." } if query_lower.length < min_prefix_length

      # Find all partial matches
      matches = find_all_character_matches(query_lower, candidates, get_forename, get_full_name, get_display_name)

      case matches.length
      when 0
        { error: "No one matching '#{query}' found." }
      when 1
        { match: matches.first }
      else
        # Multiple matches - create disambiguation menu
        create_character_disambiguation_menu(
          matches: matches.take(max_disambiguation),
          query: query,
          get_full_name: get_full_name,
          character_instance: character_instance,
          context: context
        )
      end
    end

    # Character resolution helper - finds characters by name (returns single best match)
    # Works with CharacterInstance (accessing .character) or Character directly
    # @param query [String] character name to find
    # @param candidates [Array<CharacterInstance, Character>] characters to search
    # @param viewer [CharacterInstance] the character doing the lookup (enables personalized name matching)
    # @param forename_field [Symbol] field name for forename (default: uses .character.forename for CharacterInstance)
    # @param full_name_method [Symbol] method name for full name (default: uses .character.full_name for CharacterInstance)
    # @param min_prefix_length [Integer] minimum chars for partial match (default: 1)
    # @return [Object, nil] matched candidate or nil
    def resolve_character(query:, candidates:, viewer: nil, forename_field: nil, full_name_method: nil, min_prefix_length: 1)
      return nil if blank?(query)
      return nil if candidates.nil? || candidates.empty?

      query_lower = query.downcase.strip

      # ID-based targeting (e.g., "#123") - used by disambiguation responses
      if query_lower.match?(/\A#\d+\z/)
        target_id = query_lower[1..].to_i
        return candidates.find { |c| identifier_for(c) == target_id }
      end

      # Determine how to get forename, nickname, and full_name from candidates
      get_forename = if forename_field
                       ->(c) { c.respond_to?(forename_field) ? c.send(forename_field) : nil }
                     else
                       ->(c) { c.respond_to?(:character) ? c.character&.forename : c.forename }
                     end

      get_nickname = ->(c) {
        char = c.respond_to?(:character) ? c.character : c
        char&.respond_to?(:nickname) ? char&.nickname : nil
      }

      get_full_name = if full_name_method
                        ->(c) { c.respond_to?(full_name_method) ? c.send(full_name_method) : nil }
                      else
                        ->(c) { c.respond_to?(:character) ? c.character&.full_name : c.full_name }
                      end

      get_display_name = build_display_name_accessor(viewer)

      # Exact display name match (what the viewer actually sees - personalized)
      if get_display_name
        exact_display = candidates.find { |c| get_display_name.call(c)&.downcase == query_lower }
        return exact_display if exact_display
      end

      # Exact nickname match
      exact_nickname = candidates.find { |c| get_nickname.call(c)&.downcase == query_lower }
      return exact_nickname if exact_nickname

      # Exact forename match
      exact_forename = candidates.find { |c| get_forename.call(c)&.downcase == query_lower }
      return exact_forename if exact_forename

      # Exact full name match
      exact_full = candidates.find { |c| get_full_name.call(c)&.downcase == query_lower }
      return exact_full if exact_full

      # Prefix match on display name (personalized)
      return nil if query_lower.length < min_prefix_length
      if get_display_name
        prefix_display = candidates.find { |c| get_display_name.call(c)&.downcase&.start_with?(query_lower) }
        return prefix_display if prefix_display
      end

      # Prefix match on nickname
      prefix_nick = candidates.find { |c| get_nickname.call(c)&.downcase&.start_with?(query_lower) }
      return prefix_nick if prefix_nick

      # Prefix match on forename
      prefix = candidates.find { |c| get_forename.call(c)&.downcase&.start_with?(query_lower) }
      return prefix if prefix

      # Contains match on display name (personalized)
      if get_display_name
        contains_display = candidates.find { |c| get_display_name.call(c)&.downcase&.include?(query_lower) }
        return contains_display if contains_display
      end

      # Contains match on forename
      candidates.find { |c| get_forename.call(c)&.downcase&.include?(query_lower) }
    end

    # Movement target resolution - resolves navigation targets (directions, rooms, characters, furniture)
    # Used by MovementService for the walk command
    # @param target [String] the target to resolve (direction name, room name, character name, etc.)
    # @param character_instance [CharacterInstance] the character doing the movement
    # @return [MovementResult] result with type, exit, target, error attributes
    MovementResult = Struct.new(:type, :exit, :target, :error, keyword_init: true)

    def resolve_movement_target(target, character_instance)
      return MovementResult.new(type: :error, error: "Where do you want to go?") if blank?(target)

      room = character_instance.current_room
      target_lower = target.downcase.strip

      # Priority 1: Check for direction match using spatial adjacency
      normalized_dir = normalize_direction(target_lower)
      if normalized_dir
        destination = RoomAdjacencyService.resolve_direction_movement(room, normalized_dir.to_sym)
        if destination
          spatial_exit = MovementService::SpatialExit.new(
            to_room: destination,
            direction: normalized_dir,
            from_room: room
          )
          return MovementResult.new(type: :exit, exit: spatial_exit)
        end

        # Target is a recognized direction but no exit exists - don't fall through
        # to room name matching (prevents "out" from walking to "Outdoor Patio")
        return MovementResult.new(type: :error, error: "You can't go that way.")
      end

      # Priority 1.5: Check for vehicle targets (car, vehicle, my car, or specific vehicle name)
      vehicle_result = resolve_vehicle_target(target_lower, character_instance)
      if vehicle_result.is_a?(Hash) && vehicle_result[:ambiguous]
        return MovementResult.new(type: :ambiguous, target: vehicle_result)
      elsif vehicle_result.is_a?(Vehicle)
        vehicle_room = vehicle_result.current_room
        if vehicle_room.nil?
          return MovementResult.new(type: :error, error: "Your vehicle '#{vehicle_result.name}' has no known location.")
        end
        return MovementResult.new(type: :room, target: vehicle_room)
      end

      # Priority 1.7: Check saved location bookmarks
      character = character_instance.character
      saved_loc = SavedLocation.find_by_name(character, target)
      return MovementResult.new(type: :room, target: saved_loc.room) if saved_loc&.room

      # Priority 1.8: Check for event targets (active/upcoming events by name)
      event_result = resolve_event_target(target_lower, character_instance)
      return event_result if event_result

      # Priority 2: Check for contained room by name (enterable locations)
      contained_rooms = RoomAdjacencyService.contained_rooms(room)
      contained_match = contained_rooms.find { |r| r.name&.downcase&.include?(target_lower) }
      if contained_match
        spatial_exit = MovementService::SpatialExit.new(
          to_room: contained_match,
          direction: 'enter',
          from_room: room
        )
        return MovementResult.new(type: :exit, exit: spatial_exit)
      end

      # Priority 2b: Check for sibling room by name (rooms sharing the same container)
      # Use :room type so pathfinding routes through the container room
      container = RoomAdjacencyService.containing_room(room)
      if container
        sibling_rooms = RoomAdjacencyService.contained_rooms(container).reject { |r| r.id == room.id }
        sibling_match = sibling_rooms.find { |r| r.name&.downcase&.include?(target_lower) }
        return MovementResult.new(type: :room, target: sibling_match) if sibling_match
      end

      # Priority 3: Check for character in same room (by visible name only)
      characters_in_room = room.character_instances.reject { |ci| ci.id == character_instance.id }
      char_match = resolve_character_by_visible_name(
        query: target,
        candidates: characters_in_room,
        viewer: character_instance
      )
      return MovementResult.new(type: :character, target: char_match) if char_match

      # Priority 4: Check for furniture/places in room
      if room.respond_to?(:places)
        furniture_match = resolve(
          query: target,
          candidates: room.places,
          name_field: :name,
          description_field: :description
        )
        return MovementResult.new(type: :furniture, target: furniture_match) if furniture_match
      end

      # Priority 5: Check for room by name (database queries instead of loading all)
      room_match = Room.where(ilike_match(:name, target_lower)).first
      room_match ||= Room.where(ilike_prefix(:name, target_lower)).first if target_lower.length >= 3
      room_match ||= Room.where(ilike_contains(:name, target_lower)).first if target_lower.length >= 3
      return MovementResult.new(type: :room, target: room_match) if room_match

      # Check for ambiguous matches
      ambiguous = check_ambiguous_movement_targets(target_lower, room, character_instance)
      return MovementResult.new(type: :ambiguous, target: ambiguous) if ambiguous

      MovementResult.new(type: :error, error: "Can't find '#{target}' to move toward.")
    end

    # Character resolution that only matches on what the viewer can see (display_name_for).
    # Does NOT match on hidden forename/surname/full_name for unknown characters.
    # Used by movement commands where players should only target characters by visible names.
    # @param query [String] user's search query
    # @param candidates [Array<CharacterInstance>] characters to search
    # @param viewer [CharacterInstance] the character doing the lookup
    # @return [Object, nil] matched candidate or nil
    def resolve_character_by_visible_name(query:, candidates:, viewer:)
      return nil if blank?(query)
      return nil if candidates.nil? || candidates.empty?
      return nil unless viewer

      query_lower = query.downcase.strip

      # ID-based targeting (e.g., "#123")
      if query_lower.match?(/\A#\d+\z/)
        target_id = query_lower[1..].to_i
        return candidates.find { |c| identifier_for(c) == target_id }
      end

      get_display = build_display_name_accessor(viewer)
      return nil unless get_display

      # Exact display name match
      exact = candidates.find { |c| get_display.call(c)&.downcase == query_lower }
      return exact if exact

      return nil if query_lower.length < 1

      # Prefix match on display name
      prefix = candidates.find { |c| get_display.call(c)&.downcase&.start_with?(query_lower) }
      return prefix if prefix

      # Contains match on display name
      contains = candidates.find { |c| get_display.call(c)&.downcase&.include?(query_lower) }
      return contains if contains

      # Also check known_name (full name the viewer knows) for known characters,
      # since display_name_for may abbreviate to shortest unambiguous form.
      viewer_char_id = viewer.respond_to?(:character_id) ? viewer.character_id : viewer.id
      candidates.find do |c|
        char = c.respond_to?(:character) ? c.character : c
        next unless char

        known = if char.respond_to?(:is_npc) && char.is_npc
                  char.full_name
                else
                  knowledge = CharacterKnowledge.first(
                    knower_character_id: viewer_char_id,
                    known_character_id: char.id
                  )
                  knowledge&.is_known ? knowledge.known_name : nil
                end
        next unless known

        known_lower = known.downcase
        known_lower == query_lower || known_lower.start_with?(query_lower) || known_lower.include?(query_lower)
      end
    end

    private

    # Resolve vehicle target for movement
    # @param target_lower [String] lowercase target string
    # @param character_instance [CharacterInstance] the character doing the movement
    # @return [Vehicle, Hash, nil] Vehicle if single match, Hash with :ambiguous if multiple, nil if none
    def resolve_vehicle_target(target_lower, character_instance)
      character = character_instance.character

      # Generic vehicle keywords
      vehicle_keywords = %w[car vehicle automobile]
      vehicle_keywords += ['my car', 'my vehicle']

      if vehicle_keywords.include?(target_lower)
        vehicles = Vehicle.where(owner_id: character.id).all

        case vehicles.length
        when 0
          return nil
        when 1
          return vehicles.first
        else
          # Multiple vehicles - return ambiguous
          return {
            ambiguous: true,
            type: :vehicle,
            matches: vehicles.map { |v| { id: v.id, name: v.name, room: v.current_room&.name } }
          }
        end
      end

      # Try matching specific vehicle name (case-insensitive contains match)
      vehicle = Vehicle.where(owner_id: character.id)
                       .where(Sequel.ilike(:name, "%#{target_lower}%"))
                       .first

      vehicle
    end

    # Calculate Damerau-Levenshtein distance between two strings
    # Returns the minimum number of single-character edits needed
    # Includes transposition (swapping adjacent characters) as a single operation
    # @param s1 [String] first string
    # @param s2 [String] second string
    # @return [Integer] edit distance
    def levenshtein_distance(s1, s2)
      return s2.length if s1.empty?
      return s1.length if s2.empty?

      m = s1.length
      n = s2.length

      # Full matrix for Damerau-Levenshtein (needs 2 previous rows for transposition)
      d = Array.new(m + 1) { Array.new(n + 1, 0) }

      # Initialize first column and row
      (0..m).each { |i| d[i][0] = i }
      (0..n).each { |j| d[0][j] = j }

      (1..m).each do |i|
        (1..n).each do |j|
          cost = s1[i - 1] == s2[j - 1] ? 0 : 1

          d[i][j] = [
            d[i - 1][j] + 1,      # deletion
            d[i][j - 1] + 1,      # insertion
            d[i - 1][j - 1] + cost # substitution
          ].min

          # Transposition: swap adjacent characters (Damerau extension)
          if i > 1 && j > 1 && s1[i - 1] == s2[j - 2] && s1[i - 2] == s2[j - 1]
            d[i][j] = [d[i][j], d[i - 2][j - 2] + cost].min
          end
        end
      end

      d[m][n]
    end

    # Check if query is within acceptable edit distance of text
    # Allows 1 edit for short strings, 2 for longer
    # @param query [String] query string (should be lowercase)
    # @param text [String] text to compare against
    # @param max_distance [Integer, nil] optional override for max edit distance
    # @return [Boolean] true if within acceptable edit distance
    def fuzzy_match?(query, text, max_distance: nil)
      return false if text.nil? || query.nil?

      text_lower = text.downcase
      query_lower = query.downcase

      # Default max distance based on query length
      # 1 edit for short strings (<=4 chars), 2 for longer
      max_distance ||= query_lower.length <= 4 ? 1 : 2

      distance = levenshtein_distance(query_lower, text_lower)
      distance <= max_distance
    end

    # Check if query matches word starts (initials)
    # "js" matches "John Smith", "jd" matches "Jane Doe"
    # @param query_lower [String] lowercase query string
    # @param text [String] text to check against
    # @return [Boolean] true if query matches initials or is a prefix of initials
    def matches_word_starts?(query_lower, text)
      return false if text.nil? || text.empty?

      words = text.downcase.split(/\s+/)
      initials = words.map { |w| w[0] }.join

      # Match if query equals initials or is a prefix of initials
      initials.start_with?(query_lower)
    end

    def normalize_direction(input)
      CanvasHelper.normalize_direction(input)
    end

    # Check for ambiguous movement targets (multiple matches)
    def check_ambiguous_movement_targets(target_lower, room, character_instance)
      matches = []

      # Check spatial exits (by destination room name)
      room.passable_spatial_exits.each do |exit_data|
        dest_name = exit_data[:room]&.name
        if dest_name&.downcase&.include?(target_lower)
          matches << { type: :exit, direction: exit_data[:direction].to_s, name: dest_name }
        end
      end

      # Check characters (use visible display name, not hidden real name)
      room.character_instances.reject { |ci| ci.id == character_instance.id }.each do |ci|
        name = ci.character&.display_name_for(character_instance)
        if name&.downcase&.include?(target_lower)
          matches << { type: :character, id: ci.id, name: name }
        end
      end

      # Check furniture
      if room.respond_to?(:places)
        room.places.each do |p|
          if p.name&.downcase&.include?(target_lower)
            matches << { type: :furniture, id: p.id, name: p.name }
          end
        end
      end

      return nil if matches.length <= 1

      { ambiguous: true, matches: matches, type: matches.first[:type] }
    end

    # Resolve event target for movement - finds active/upcoming events by name
    # @param target_lower [String] lowercase target string
    # @param character_instance [CharacterInstance] the character doing the movement
    # @return [MovementResult, nil] result if event found, nil otherwise
    def resolve_event_target(target_lower, character_instance)
      return nil unless defined?(Event)

      character = character_instance.character

      # Find active or upcoming (within 24 hours) events matching the name
      candidates = Event.where(status: %w[active scheduled])
                        .where { starts_at > Time.now - 86_400 }
                        .all

      # Filter by name match (exact, case-insensitive, or partial)
      matches = candidates.select do |event|
        name_lower = event.name&.downcase
        next false unless name_lower

        name_lower == target_lower ||
          name_lower.include?(target_lower) ||
          target_lower.include?(name_lower)
      end

      # Filter by visibility: public events, or private events where character is organizer/attendee
      visible_matches = matches.select do |event|
        if event.is_public
          true
        else
          # Private event: must be organizer or non-bounced attendee
          next true if event.organizer_id == character.id

          attendee = EventAttendee.first(event_id: event.id, character_id: character.id)
          next false unless attendee
          next false if attendee.bounced?

          attendee.status == 'yes'
        end
      end

      # Filter out completed/cancelled events
      visible_matches.reject! { |e| %w[completed cancelled].include?(e.status) }

      # Filter upcoming scheduled events to only those within 24 hours
      visible_matches.select! do |event|
        event.active? || (event.scheduled? && event.starts_at <= Time.now + 86_400)
      end

      return nil if visible_matches.empty?

      if visible_matches.length == 1
        event = visible_matches.first
        if event.room_id.nil?
          return MovementResult.new(type: :error, error: "'#{event.name}' has no location set.")
        end
        return MovementResult.new(type: :room, target: event.room)
      end

      # Multiple matches - return ambiguous
      MovementResult.new(type: :ambiguous, target: {
        ambiguous: true,
        type: :event,
        matches: visible_matches.map { |e| { id: e.id, name: e.name, room: e.room&.name } }
      })
    end

    def field_value(object, field)
      return nil unless object && field
      object.respond_to?(field) ? object.send(field) : object[field]
    end

    def identifier_for(object)
      if object.respond_to?(:id)
        object.id
      elsif object.respond_to?(:[])
        object[:id] || object['id']
      else
        object.object_id
      end
    end

    def find_exact_match(query_lower, candidates, name_field, description_field)
      # Exact match on name (strip HTML for consistency with find_all_matches)
      if name_field
        exact_matches = candidates.select { |c| strip_html(field_value(c, name_field))&.downcase == query_lower }
        return exact_matches.first if exact_matches.length == 1
        # Multiple exact matches → fall through to disambiguation
      end

      # Exact match on stripped description
      if description_field
        exact_desc = candidates.select { |c| strip_html(field_value(c, description_field))&.downcase == query_lower }
        return exact_desc.first if exact_desc.length == 1
      end

      nil
    end

    def find_all_matches(query_lower, candidates, name_field, description_field)
      matches = []

      candidates.each do |candidate|
        name = strip_html(field_value(candidate, name_field))&.downcase
        desc = strip_html(field_value(candidate, description_field))&.downcase

        # Check if it matches by name or description
        if (name && (name.start_with?(query_lower) || name.include?(query_lower))) ||
           (desc && (desc.start_with?(query_lower) || desc.include?(query_lower)))
          matches << candidate
        end
      end

      matches
    end

    def create_disambiguation_menu(matches:, query:, display_field:, character_instance:, context:)
      options = matches.map.with_index do |match, idx|
        raw_text = field_value(match, display_field).to_s
        plain = strip_html(raw_text)
        display_text = (plain.nil? || plain.empty?) ? "Option #{idx + 1}" : plain
        opt = {
          key: (idx + 1).to_s,
          label: display_text.length > 50 ? "#{display_text[0..47]}..." : display_text,
          description: nil,
          value: identifier_for(match)
        }
        # Pass raw HTML label if it differs from plain text (has markup)
        opt[:html_label] = raw_text if raw_text != display_text
        opt
      end

      # Include OutputHelper for quickmenu creation
      helper = Object.new
      helper.extend(OutputHelper)

      # Store context including the original candidates for resolution
      full_context = context.merge(
        disambiguation: true,
        match_ids: matches.map { |m| identifier_for(m) }
      )

      quickmenu_result = helper.create_quickmenu(
        character_instance,
        "Multiple matches for '#{query}'. Which one?",
        options,
        context: full_context
      )

      { quickmenu: quickmenu_result, disambiguation: true }
    end

    def build_forename_accessor(forename_field)
      if forename_field
        ->(c) { c.respond_to?(forename_field) ? c.send(forename_field) : nil }
      else
        ->(c) { c.respond_to?(:character) ? c.character&.forename : c.forename }
      end
    end

    def build_full_name_accessor(full_name_method)
      if full_name_method
        ->(c) { c.respond_to?(full_name_method) ? c.send(full_name_method) : nil }
      else
        ->(c) { c.respond_to?(:character) ? c.character&.full_name : c.full_name }
      end
    end

    # Build a lambda that returns the personalized display name for a candidate
    # as seen by the viewer. Returns nil if no viewer is provided.
    def build_display_name_accessor(viewer)
      return nil unless viewer

      ->(c) {
        char = c.respond_to?(:character) ? c.character : c
        return nil unless char&.respond_to?(:display_name_for)

        char.display_name_for(viewer)
      }
    end

    def find_all_character_matches(query_lower, candidates, get_forename, get_full_name, get_display_name = nil)
      matches = []

      candidates.each do |candidate|
        forename = get_forename.call(candidate)&.downcase
        full_name = get_full_name.call(candidate)&.downcase
        display_name = get_display_name&.call(candidate)&.downcase

        # Check if it matches by display name, forename, or full name
        if (display_name && (display_name.start_with?(query_lower) || display_name.include?(query_lower))) ||
           (forename && (forename.start_with?(query_lower) || forename.include?(query_lower))) ||
           (full_name && (full_name.start_with?(query_lower) || full_name.include?(query_lower)))
          matches << candidate
        end
      end

      matches
    end

    def create_character_disambiguation_menu(matches:, query:, get_full_name:, character_instance:, context:)
      options = matches.map.with_index do |match, idx|
        display_text = get_full_name.call(match) || "Character #{idx + 1}"
        {
          key: (idx + 1).to_s,
          label: display_text.length > 50 ? "#{display_text[0..47]}..." : display_text,
          description: nil,
          value: identifier_for(match)
        }
      end

      # Include OutputHelper for quickmenu creation
      helper = Object.new
      helper.extend(OutputHelper)

      # Store context including the original candidates for resolution
      full_context = context.merge(
        disambiguation: true,
        match_ids: matches.map { |m| identifier_for(m) }
      )

      quickmenu_result = helper.create_quickmenu(
        character_instance,
        "Multiple people match '#{query}'. Who do you mean?",
        options,
        context: full_context
      )

      { quickmenu: quickmenu_result, disambiguation: true }
    end
  end
end
