# frozen_string_literal: true

# Redis-backed cache for room exit calculations.
#
# Wraps RoomAdjacencyService.compute_* methods with Redis caching using a
# version-counter invalidation strategy:
#   - Each location has a version counter; incrementing it stales all cached
#     entries for rooms in that location (geometry changes, feature CRUD, etc.)
#   - Each room has a door-version counter for methods sensitive to door state
#     (navigable_exits); incrementing it stales only that room's door-sensitive cache.
#
# Cache keys:
#   room_adj:loc_version:{location_id}                          → integer
#   room_adj:door_version:{room_id}                             → integer
#   room_adj:navigable_exits:{room_id}:{loc_v}:{door_v}        → JSON
#   room_adj:adjacent_rooms:{room_id}:{loc_v}                   → JSON
#   room_adj:contained_rooms:{room_id}:{loc_v}                  → JSON
#   room_adj:containing_room:{room_id}:{loc_v}                  → JSON
#
# All methods gracefully degrade: on any Redis error they fall through to
# uncached computation so the game never breaks due to cache issues.
#
class RoomExitCacheService
  CACHE_TTL = 86_400 # 24 hours - geometry rarely changes; version counters handle invalidation
  KEY_PREFIX = 'room_adj'

  class << self
    # =========================================================================
    # Cached wrappers
    # =========================================================================

    # Cached navigable_exits — sensitive to both location geometry AND door state
    # @param room [Room]
    # @return [Hash<Symbol, Array<Room>>]
    def navigable_exits(room)
      return RoomAdjacencyService.compute_navigable_exits(room) unless cache_enabled?

      loc_v = location_version(room.location_id)
      door_v = door_version(room.id)
      key = "#{KEY_PREFIX}:navigable_exits:#{room.id}:#{loc_v}:#{door_v}"

      cached = redis_get(key)
      if cached
        deserialize_exits(cached)
      else
        result = RoomAdjacencyService.compute_navigable_exits(room)
        redis_set(key, serialize_exits(result))
        result
      end
    rescue StandardError => e
      warn "[RoomExitCacheService] navigable_exits cache error: #{e.message}"
      RoomAdjacencyService.compute_navigable_exits(room)
    end

    # Cached adjacent_rooms — sensitive to location geometry only
    # @param room [Room]
    # @return [Hash<Symbol, Array<Room>>]
    def adjacent_rooms(room)
      return RoomAdjacencyService.compute_adjacent_rooms(room) unless cache_enabled?

      loc_v = location_version(room.location_id)
      key = "#{KEY_PREFIX}:adjacent_rooms:#{room.id}:#{loc_v}"

      cached = redis_get(key)
      if cached
        deserialize_exits(cached)
      else
        result = RoomAdjacencyService.compute_adjacent_rooms(room)
        redis_set(key, serialize_exits(result))
        result
      end
    rescue StandardError => e
      warn "[RoomExitCacheService] adjacent_rooms cache error: #{e.message}"
      RoomAdjacencyService.compute_adjacent_rooms(room)
    end

    # Cached contained_rooms — sensitive to location geometry only
    # @param room [Room]
    # @return [Array<Room>]
    def contained_rooms(room)
      return RoomAdjacencyService.compute_contained_rooms(room) unless cache_enabled?

      loc_v = location_version(room.location_id)
      key = "#{KEY_PREFIX}:contained_rooms:#{room.id}:#{loc_v}"

      cached = redis_get(key)
      if cached
        deserialize_room_list(cached)
      else
        result = RoomAdjacencyService.compute_contained_rooms(room)
        redis_set(key, serialize_room_list(result))
        result
      end
    rescue StandardError => e
      warn "[RoomExitCacheService] contained_rooms cache error: #{e.message}"
      RoomAdjacencyService.compute_contained_rooms(room)
    end

    # Cached containing_room — sensitive to location geometry only
    # @param room [Room]
    # @return [Room, nil]
    def containing_room(room)
      return RoomAdjacencyService.compute_containing_room(room) unless cache_enabled?

      loc_v = location_version(room.location_id)
      key = "#{KEY_PREFIX}:containing_room:#{room.id}:#{loc_v}"

      cached = redis_get(key)
      if cached
        deserialize_single_room(cached)
      else
        result = RoomAdjacencyService.compute_containing_room(room)
        redis_set(key, serialize_single_room(result))
        result
      end
    rescue StandardError => e
      warn "[RoomExitCacheService] containing_room cache error: #{e.message}"
      RoomAdjacencyService.compute_containing_room(room)
    end

    # =========================================================================
    # Invalidation
    # =========================================================================

    # Invalidate all cached exits for a location (geometry change, feature CRUD, etc.)
    # Increments the location version counter so all existing keys become stale.
    # @param location_id [Integer]
    def invalidate_location!(location_id)
      return unless cache_enabled?

      REDIS_POOL.with { |r| r.incr("#{KEY_PREFIX}:loc_version:#{location_id}") }
    rescue StandardError => e
      warn "[RoomExitCacheService] invalidate_location! error: #{e.message}"
    end

    # Invalidate door-state-sensitive cache for a specific room.
    # Increments the room's door version counter.
    # @param room_id [Integer]
    def invalidate_door_state!(room_id)
      return unless cache_enabled?

      REDIS_POOL.with { |r| r.incr("#{KEY_PREFIX}:door_version:#{room_id}") }
    rescue StandardError => e
      warn "[RoomExitCacheService] invalidate_door_state! error: #{e.message}"
    end

    private

    # =========================================================================
    # Version counters
    # =========================================================================

    def location_version(location_id)
      REDIS_POOL.with { |r| r.get("#{KEY_PREFIX}:loc_version:#{location_id}") || '0' }
    rescue StandardError => e
      warn "[RoomExitCacheService] location_version lookup failed for location #{location_id}: #{e.message}"
      '0'
    end

    def door_version(room_id)
      REDIS_POOL.with { |r| r.get("#{KEY_PREFIX}:door_version:#{room_id}") || '0' }
    rescue StandardError => e
      warn "[RoomExitCacheService] door_version lookup failed for room #{room_id}: #{e.message}"
      '0'
    end

    # =========================================================================
    # Redis helpers
    # =========================================================================

    def cache_enabled?
      defined?(REDIS_POOL) && REDIS_POOL
    end

    def redis_get(key)
      REDIS_POOL.with { |r| r.get(key) }
    rescue StandardError => e
      warn "[RoomExitCacheService] redis_get failed for #{key}: #{e.message}"
      nil
    end

    def redis_set(key, value)
      REDIS_POOL.with { |r| r.setex(key, CACHE_TTL, value) }
    rescue StandardError => e
      warn "[RoomExitCacheService] redis_set failed for #{key}: #{e.message}"
      nil
    end

    # =========================================================================
    # Serialization — store room IDs as JSON, rehydrate with single query
    # =========================================================================

    # Serialize Hash<Symbol, Array<Room>> → JSON string
    def serialize_exits(exits_hash)
      data = {}
      exits_hash.each do |direction, rooms|
        data[direction.to_s] = rooms.map(&:id)
      end
      JSON.generate(data)
    end

    # Deserialize JSON string → Hash<Symbol, Array<Room>>
    def deserialize_exits(json_str)
      data = JSON.parse(json_str)
      all_ids = data.values.flatten.uniq
      return Hash.new { |h, k| h[k] = [] } if all_ids.empty?

      rooms_by_id = Room.where(id: all_ids).all.each_with_object({}) { |r, h| h[r.id] = r }

      result = Hash.new { |h, k| h[k] = [] }
      data.each do |direction, ids|
        rooms = ids.filter_map { |id| rooms_by_id[id] }
        result[direction.to_sym] = rooms if rooms.any?
      end
      result
    end

    # Serialize Array<Room> → JSON string
    def serialize_room_list(rooms)
      JSON.generate(rooms.map(&:id))
    end

    # Deserialize JSON string → Array<Room>
    def deserialize_room_list(json_str)
      ids = JSON.parse(json_str)
      return [] if ids.empty?

      rooms_by_id = Room.where(id: ids).all.each_with_object({}) { |r, h| h[r.id] = r }
      ids.filter_map { |id| rooms_by_id[id] }
    end

    # Serialize Room|nil → JSON string
    def serialize_single_room(room)
      JSON.generate(room&.id)
    end

    # Deserialize JSON string → Room|nil
    def deserialize_single_room(json_str)
      id = JSON.parse(json_str)
      return nil if id.nil?

      Room[id]
    end
  end
end
