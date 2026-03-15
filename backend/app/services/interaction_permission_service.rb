# frozen_string_literal: true

# InteractionPermissionService - Unified permission system for character interactions
#
# Provides a three-tier permission system:
# 1. Permanent database permissions (via Relationship model)
# 2. Temporary Redis permissions (session-scoped)
# 3. One-time consent requests (quickmenu)
#
# Usage:
#   InteractionPermissionService.has_permission?(actor, target, 'dress', room_scoped: true)
#   InteractionPermissionService.grant_temporary_permission(granter, grantee, 'dress', room_id: 123)
#   InteractionPermissionService.grant_permanent_permission(granter_char, grantee_char, 'dress')
#
class InteractionPermissionService
  PERMISSION_TYPES = %w[follow dress undress interact].freeze
  DEFAULT_TTL = 3600 # 1 hour for temporary permissions

  class << self
    # Check if actor has permission to perform action on target
    #
    # @param actor [CharacterInstance] The character performing the action
    # @param target [CharacterInstance] The target character
    # @param permission_type [String] Type of permission (follow, dress, undress, interact)
    # @param room_scoped [Boolean] Whether permission is scoped to current room
    # @return [Boolean]
    def has_permission?(actor, target, permission_type, room_scoped: false)
      return false unless valid_permission_type?(permission_type)
      return false if actor.id == target.id # Can't need permission for self

      # 1. Check permanent database permission
      return true if has_permanent_permission?(actor, target, permission_type)

      # 2. Check temporary Redis permission
      has_temporary_permission?(actor, target, permission_type, room_scoped: room_scoped, room_id: actor.current_room_id)
    end

    # Grant temporary permission via Redis
    #
    # @param granter [CharacterInstance] Who is granting permission
    # @param grantee [CharacterInstance] Who receives permission
    # @param permission_type [String] Type of permission
    # @param room_id [Integer, nil] Optional room scope
    # @param ttl [Integer] Time to live in seconds
    def grant_temporary_permission(granter, grantee, permission_type, room_id: nil, ttl: DEFAULT_TTL)
      return false unless valid_permission_type?(permission_type)

      key = redis_key(grantee, granter, permission_type, room_id)
      REDIS_POOL.with { |redis| redis.setex(key, ttl, 'granted') }
      true
    rescue StandardError => e
      warn "[InteractionPermissionService] Failed to grant temporary permission: #{e.message}"
      false
    end

    # Revoke temporary permission
    #
    # @param granter [CharacterInstance] Who granted the permission
    # @param grantee [CharacterInstance] Who had the permission
    # @param permission_type [String] Type of permission
    # @param room_id [Integer, nil] Optional room scope
    def revoke_temporary_permission(granter, grantee, permission_type, room_id: nil)
      return false unless valid_permission_type?(permission_type)

      key = redis_key(grantee, granter, permission_type, room_id)
      REDIS_POOL.with { |redis| redis.del(key) }
      true
    rescue StandardError => e
      warn "[InteractionPermissionService] Failed to revoke temporary permission: #{e.message}"
      false
    end

    # Clear all temporary permissions for a character (e.g., when they move rooms)
    #
    # @param character_instance [CharacterInstance] Character whose permissions to clear
    # @param permission_type [String, nil] Specific type to clear, or nil for all types
    # @param room_id [Integer, nil] Specific room scope to clear
    def clear_temporary_permissions(character_instance, permission_type: nil, room_id: nil)
      types = permission_type ? [permission_type] : PERMISSION_TYPES

      REDIS_POOL.with do |redis|
        types.each do |type|
          pattern = "permission:#{type}:#{character_instance.id}:*"
          pattern += ":#{room_id}" if room_id

          cursor = "0"
          loop do
            cursor, keys = redis.scan(cursor, match: pattern, count: 100)
            redis.del(*keys) if keys.any?
            break if cursor == "0"
          end
        end
      end
      true
    rescue StandardError => e
      warn "[InteractionPermissionService] Failed to clear temporary permissions: #{e.message}"
      false
    end

    # Grant permanent permission via Relationship
    #
    # @param granter_character [Character] Who is granting (the target)
    # @param grantee_character [Character] Who receives permission (the actor)
    # @param permission_type [String] Type of permission
    def grant_permanent_permission(granter_character, grantee_character, permission_type)
      return false unless valid_permission_type?(permission_type)

      # Relationship is from grantee's perspective: "I (grantee) have permission from granter"
      rel = Relationship.find_or_create_between(grantee_character, granter_character)
      field = permission_field(permission_type)
      return false unless field

      rel.update(status: 'accepted', field => true)
      true
    rescue StandardError => e
      warn "[InteractionPermissionService] Failed to grant permanent permission: #{e.message}"
      false
    end

    # Revoke permanent permission
    #
    # @param granter_character [Character] Who granted the permission
    # @param grantee_character [Character] Who had the permission
    # @param permission_type [String] Type of permission
    def revoke_permanent_permission(granter_character, grantee_character, permission_type)
      return false unless valid_permission_type?(permission_type)

      rel = Relationship.between(grantee_character, granter_character)
      return false unless rel

      field = permission_field(permission_type)
      return false unless field

      rel.update(field => false)
      true
    rescue StandardError => e
      warn "[InteractionPermissionService] Failed to revoke permanent permission: #{e.message}"
      false
    end

    # Check both permanent and temporary permission existence (for UI display)
    #
    # @return [Hash] { permanent: Boolean, temporary: Boolean }
    def permission_status(actor, target, permission_type, room_scoped: false)
      {
        permanent: has_permanent_permission?(actor, target, permission_type),
        temporary: has_temporary_permission?(actor, target, permission_type, room_scoped: room_scoped, room_id: actor.current_room_id)
      }
    end

    private

    def valid_permission_type?(permission_type)
      PERMISSION_TYPES.include?(permission_type.to_s)
    end

    def has_permanent_permission?(actor, target, permission_type)
      rel = Relationship.between(actor.character, target.character)
      return false unless rel&.accepted?

      case permission_type.to_s
      when 'follow' then rel.can_follow
      when 'dress' then rel.can_dress
      when 'undress' then rel.can_undress
      when 'interact' then rel.can_interact
      else false
      end
    rescue StandardError => e
      warn "[InteractionPermissionService] Failed to check permanent permission: #{e.message}"
      false
    end

    def has_temporary_permission?(actor, target, permission_type, room_scoped:, room_id:)
      REDIS_POOL.with do |redis|
        # Check room-scoped key first if applicable
        if room_scoped && room_id
          result = redis.get(redis_key(actor, target, permission_type, room_id))
          return true if result == 'granted'
        end

        # Fall back to global (non-room-scoped) key
        result = redis.get(redis_key(actor, target, permission_type, nil))
        result == 'granted'
      end
    rescue StandardError => e
      warn "[InteractionPermissionService] Failed to check temporary permission: #{e.message}"
      false
    end

    def redis_key(actor, target, permission_type, room_id)
      base = "permission:#{permission_type}:#{actor.id}:#{target.id}"
      room_id ? "#{base}:#{room_id}" : base
    end

    def permission_field(permission_type)
      case permission_type.to_s
      when 'follow' then :can_follow
      when 'dress' then :can_dress
      when 'undress' then :can_undress
      when 'interact' then :can_interact
      else nil
      end
    end
  end
end
