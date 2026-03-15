# frozen_string_literal: true

# Shared service answering "which rooms should appear on a map for this room?"
# Used by SpatialMinimapService (and future map types like area maps).
#
# Returns an array of hashes describing each visible room and its relationship
# to the current room.
#
# Usage:
#   MapVisibilityService.visible_rooms(room)
#   # => [{ room: <Room>, relationship: :current, direction: nil, passable: true }, ...]
class MapVisibilityService
  Z_LEVEL_TOLERANCE = 2.0 # feet - overlap tolerance for z-range checks

  class << self
    # Get all rooms that should be visible on a map centered on the given room.
    #
    # @param room [Room] the current room
    # @param radius [Float, nil] max center-to-center distance (nil = no limit)
    # @param include_adjacent [Boolean] include adjacent passable rooms
    # @return [Array<Hash>] each with { room:, relationship:, direction:, passable: }
    def visible_rooms(room, radius: nil, include_adjacent: true)
      results = []

      # 1. Always include current room
      results << { room: room, relationship: :current, direction: nil, passable: true }

      seen_ids = Set.new([room.id])

      # 2. Adjacent passable rooms from navigable_exits
      if include_adjacent
        navigable = RoomAdjacencyService.navigable_exits(room)
        navigable.each do |direction, rooms|
          rooms.each do |adj_room|
            next if seen_ids.include?(adj_room.id)
            next unless passes_filters?(room, adj_room, radius: radius)

            seen_ids << adj_room.id

            # Tag based on actual relationship, not just adjacency
            relationship = if room.inside_room_id && adj_room.id == room.inside_room_id
                             :container
                           elsif adj_room.inside_room_id == room.id
                             :contained
                           else
                             :adjacent
                           end

            results << {
              room: adj_room,
              relationship: relationship,
              direction: direction.to_s,
              passable: relationship != :contained # contained rooms use "walk <name>", not directional movement
            }
          end
        end
      end

      # 3. Sibling rooms (same inside_room_id)
      if room.inside_room_id
        siblings = Room.where(inside_room_id: room.inside_room_id)
                       .exclude(id: room.id)
                       .all
        siblings.each do |sibling|
          next if seen_ids.include?(sibling.id)
          next unless passes_filters?(room, sibling, radius: radius)

          seen_ids << sibling.id
          direction = RoomAdjacencyService.direction_from_room_to_room(room, sibling)
          passable = navigable_to?(room, sibling, direction)
          results << {
            room: sibling,
            relationship: :sibling,
            direction: direction.to_s,
            passable: passable
          }
        end
      end

      # 4. Contained rooms (direct children)
      contained = RoomAdjacencyService.contained_rooms(room)
      contained.each do |child|
        next if seen_ids.include?(child.id)
        next unless passes_filters?(room, child, radius: radius)

        seen_ids << child.id
        direction = RoomAdjacencyService.direction_from_room_to_room(room, child)
        results << {
          room: child,
          relationship: :contained,
          direction: direction.to_s,
          passable: false # contained rooms are entered, not navigated to directionally
        }
      end

      # 5. Container room (parent via inside_room_id)
      if room.inside_room_id
        container = Room[room.inside_room_id]
        if container && !seen_ids.include?(container.id)
          if passes_filters?(room, container, radius: radius)
            seen_ids << container.id
            results << {
              room: container,
              relationship: :container,
              direction: nil,
              passable: false
            }
          end
        end
      end

      results
    end

    private

    # Check if a candidate room passes all visibility filters.
    #
    # @param current_room [Room] the room we're centered on
    # @param candidate [Room] the room to check
    # @param radius [Float, nil] max distance
    # @return [Boolean]
    def passes_filters?(current_room, candidate, radius: nil)
      # Must be navigable (inside zone polygon and active)
      return false unless candidate.navigable?

      # Must be on same z-level (or z data missing)
      return false unless same_level?(current_room, candidate)

      # Must not be nested inside a different room (unless it's our container or our child)
      if candidate.inside_room_id
        unless candidate.inside_room_id == current_room.id ||
               candidate.inside_room_id == current_room.inside_room_id
          return false
        end
      end

      # Must be within radius if specified
      if radius
        distance = RoomAdjacencyService.distance_between(current_room, candidate)
        return false if distance > radius
      end

      true
    end

    # Check if two rooms are on the same z-level.
    # Returns true if either room lacks z data (backward compatibility).
    #
    # @param room_a [Room]
    # @param room_b [Room]
    # @param tolerance [Float] overlap tolerance in feet
    # @return [Boolean]
    def same_level?(room_a, room_b, tolerance: Z_LEVEL_TOLERANCE)
      a_min = room_a.min_z
      a_max = room_a.max_z
      b_min = room_b.min_z
      b_max = room_b.max_z

      # If either room lacks z data, assume same level
      return true if a_min.nil? || a_max.nil? || b_min.nil? || b_max.nil?

      # Check z-range overlap with tolerance
      a_min.to_f - tolerance <= b_max.to_f && b_min.to_f - tolerance <= a_max.to_f
    end

    # Check if a room is navigable-to from the current room in a given direction.
    #
    # @param from_room [Room]
    # @param to_room [Room]
    # @param direction [Symbol]
    # @return [Boolean]
    def navigable_to?(from_room, to_room, direction)
      RoomPassabilityService.can_pass?(from_room, to_room, direction)
    rescue StandardError => e
      warn "[MapVisibilityService] navigable_to? failed: #{e.message}"
      false
    end
  end
end
