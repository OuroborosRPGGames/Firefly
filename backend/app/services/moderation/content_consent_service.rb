# frozen_string_literal: true

# ContentConsentService handles content consent calculations and management.
# Provides methods for:
# - Getting allowed content for a room (intersection of all consents)
# - Checking if specific content is allowed between two characters
# - Managing the 10-minute room stability timer
module ContentConsentService
  # Display timer threshold for showing consent timer (10 minutes in seconds)
  DISPLAY_TIMER_SECONDS = 600

  class << self
    # Get allowed content codes for a room based on all present characters
    # Returns intersection of all characters' consented content types
    #
    # @param room [Room] The room to check
    # @return [Array<String>] Array of allowed content codes
    def allowed_for_room(room)
      char_instances = room.characters_here.where(online: true).all
      return [] if char_instances.empty?

      users = char_instances.map { |ci| ci.character&.user }.compact.uniq
      return [] if users.empty?

      codes = ContentRestriction.where(is_active: true).select_map(:code)
      return [] if codes.empty?

      if users.length == 1
        user = users.first
        return codes.select { |code| UserPermission.content_consent_allowed?(user, nil, code, default: 'no') }
      end

      codes.select do |code|
        users.combination(2).all? do |user1, user2|
          UserPermission.content_consent_allowed?(user1, user2, code, default: 'no') &&
            UserPermission.content_consent_allowed?(user2, user1, code, default: 'no')
        end
      end
    end

    # Check if specific content is allowed between two characters
    # Considers both base consents and per-player overrides
    #
    # @param char1 [Character] First character
    # @param char2 [Character] Second character
    # @param restriction [ContentRestriction] The content type to check
    # @return [Boolean]
    def content_allowed_between?(char1, char2, restriction)
      user1 = char1&.user
      user2 = char2&.user
      return false unless user1 && user2 && restriction

      UserPermission.content_consent_allowed?(user1, user2, restriction.code, default: 'no') &&
        UserPermission.content_consent_allowed?(user2, user1, restriction.code, default: 'no')
    end

    # Check if a character consents to a content type
    #
    # @param character [Character]
    # @param restriction [ContentRestriction]
    # @return [Boolean]
    def char_consents_to?(character, restriction)
      user = character&.user
      return false unless user && restriction

      UserPermission.content_consent_allowed?(user, nil, restriction.code, default: 'no')
    end

    # Handle room entry - reset timer for the room
    #
    # @param character_instance [CharacterInstance]
    # @param room [Room]
    def on_room_entry(character_instance, room)
      character_instance.record_room_entry!
      reset_room_timer(room)
    end

    # Handle room exit - reset timer for the room
    #
    # @param room [Room]
    def on_room_exit(room)
      reset_room_timer(room)
    end

    # Reset the consent display timer for a room
    # Called when room occupancy changes
    #
    # @param room [Room]
    def reset_room_timer(room)
      cache = RoomConsentCache.for_room(room)
      char_count = room.characters_here.where(online: true).count

      cache.update(
        occupancy_changed_at: Time.now,
        character_count: char_count,
        allowed_codes: Sequel.pg_jsonb([])
      )

      # Reset display trigger for all characters in room
      CharacterInstance
        .where(current_room_id: room.id, online: true)
        .update(consent_display_triggered: false)
    end

    # Check if room is ready to display consent info
    #
    # @param room [Room]
    # @return [Boolean]
    def display_ready?(room)
      cache = RoomConsentCache.for_room(room)
      current_count = room.characters_here.where(online: true).count

      return false if cache.character_count != current_count
      cache.display_ready?
    end

    # Get time remaining until display ready (in seconds)
    #
    # @param room [Room]
    # @return [Integer]
    def time_until_display(room)
      cache = RoomConsentCache.for_room(room)
      cache.time_until_display
    end

    # Get consent display info for a room
    # Only returns data if 10-minute timer has elapsed
    #
    # @param room [Room]
    # @return [Hash, nil]
    def consent_display_for_room(room)
      return nil unless display_ready?(room)

      cache = RoomConsentCache.for_room(room)
      current_count = room.characters_here.where(online: true).count

      # Recalculate if stale
      if cache.stale?(current_count)
        allowed = allowed_for_room(room)
        cache.update(
          allowed_codes: Sequel.pg_jsonb(allowed),
          character_count: current_count
        )
      end

      {
        allowed_content: cache.allowed_content_codes,
        stable_since: cache.occupancy_changed_at,
        character_count: cache.character_count
      }
    end

    # Process scheduled consent notifications
    # Called by scheduler every minute
    #
    # @return [Hash] Statistics
    def process_consent_notifications!
      notified = 0

      # Find rooms where timer has elapsed
      RoomConsentCache.where { occupancy_changed_at <= Time.now - GameConfig::Moderation::CONSENT_DISPLAY_TIMER_SECONDS }.each do |cache|
        room = cache.room
        next unless room

        # Find characters who haven't been notified
        instances = CharacterInstance.where(
          current_room_id: room.id,
          online: true,
          consent_display_triggered: false
        ).all

        next if instances.empty?

        # Skip rooms with only one player — consent notices only matter with 2+
        next if instances.length < 2

        # Calculate allowed content — only notify if there are actual consented types
        allowed = allowed_for_room(room)
        next if allowed.empty?

        message = build_consent_notification(allowed)

        instances.each do |ci|
          BroadcastService.to_character(ci, message)
          ci.mark_consent_displayed!
          notified += 1
        end
      end

      { notified: notified }
    end

    # Get all content restriction types available for configuration
    #
    # @return [Array<ContentRestriction>]
    def available_restrictions
      ContentRestriction.where(is_active: true).order(:name).all
    end

    # Get a character's current consent settings
    #
    # @param character [Character]
    # @return [Hash] code => consented boolean
    def consent_settings_for(character)
      restrictions = available_restrictions
      settings = {}
      user = character&.user
      generic_perm = user ? UserPermission.generic_for(user) : nil

      restrictions.each do |r|
        settings[r.code] = {
          name: r.name,
          description: r.description,
          severity: r.severity,
          consented: generic_perm ? generic_perm.content_consent_for(r.code) == 'yes' : false
        }
      end

      settings
    end

    # Set consent for a character
    #
    # @param character [Character]
    # @param restriction [ContentRestriction]
    # @param consented [Boolean]
    # @return [ContentConsent]
    def set_consent!(character, restriction, consented)
      user = character&.user
      return nil unless user && restriction

      perm = UserPermission.generic_for(user)
      perm.set_content_consent!(restriction.code, consented ? 'yes' : 'no')
      perm
    end

    private

    def build_consent_notification(allowed_codes)
      restrictions = ContentRestriction.where(code: allowed_codes, is_active: true).all
      names = restrictions.map(&:name).sort.join(', ')

      "Content Notice: All players in this room consent to: #{names}. " \
        "Use 'consent' to manage your settings."
    end
  end
end
