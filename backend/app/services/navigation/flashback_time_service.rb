# frozen_string_literal: true

require_relative '../../lib/time_format_helper'

# FlashbackTimeService handles tracking and managing flashback time for characters.
# Flashback time accumulates while a character isn't actively RPing and can be
# used to reduce or eliminate world travel time.
#
# Usage:
#   FlashbackTimeService.touch_room_activity(room_id)
#   FlashbackTimeService.available_time(character_instance)
#   FlashbackTimeService.calculate_flashback_coverage(character_instance, journey_seconds, mode: :basic)
#
class FlashbackTimeService
  extend TimeFormatHelper

  FLASHBACK_MAX_SECONDS = GameConfig::Journey::FLASHBACK_MAX_SECONDS

  class << self
    # Update last_rp_activity_at for all characters in a room when RP occurs.
    # Called by BroadcastService for IC message types.
    #
    # @param room_id [Integer] The room where RP occurred
    # @param exclude [Array<Integer>] Character instance IDs to exclude
    def touch_room_activity(room_id, exclude: [])
      return if room_id.nil?

      exclude_ids = Array(exclude)
      query = CharacterInstance.where(current_room_id: room_id, online: true)
      query = query.exclude(id: exclude_ids) if exclude_ids.any?
      query.update(last_rp_activity_at: Time.now)
    end

    # Get available flashback time for a character
    #
    # @param character_instance [CharacterInstance]
    # @return [Integer] seconds available
    def available_time(character_instance)
      character_instance.flashback_time_available
    end

    # Calculate if flashback time can cover a journey
    #
    # @param character_instance [CharacterInstance]
    # @param journey_seconds [Integer] total journey time
    # @param mode [Symbol] :basic, :return, or :backloaded
    # @return [Hash] { can_instant: bool, time_remaining: int, flashback_used: int, ... }
    def calculate_flashback_coverage(character_instance, journey_seconds, mode: :basic)
      available = available_time(character_instance)

      case mode
      when :basic
        calculate_basic_coverage(available, journey_seconds)
      when :return
        calculate_return_coverage(available, journey_seconds)
      when :backloaded
        calculate_backloaded_coverage(journey_seconds)
      else
        { success: false, error: "Unknown flashback mode: #{mode}" }
      end
    end

    # Format journey time estimate for display
    #
    # @param seconds [Integer]
    # @return [String]
    def format_journey_time(seconds)
      return 'instant' if seconds <= 0

      format_duration(seconds, style: :flashback)
    end

    alias format_time format_journey_time

    # Calculate flashback coverage with a provided flashback time
    # Used for party calculations where we use the minimum across all members
    #
    # @param available [Integer] available flashback seconds (e.g., party minimum)
    # @param journey_seconds [Integer] total journey time
    # @param mode [Symbol] :basic, :return, or :backloaded
    # @return [Hash]
    def calculate_flashback_coverage_with_available(available, journey_seconds, mode: :basic)
      case mode
      when :basic
        calculate_basic_coverage(available, journey_seconds)
      when :return
        calculate_return_coverage(available, journey_seconds)
      when :backloaded
        calculate_backloaded_coverage(journey_seconds)
      else
        { success: false, error: "Unknown flashback mode: #{mode}" }
      end
    end
    private

    # Calculate coverage for basic flashback travel
    # Uses all available flashback time to reduce journey
    #
    # @param available [Integer] available flashback seconds
    # @param journey_seconds [Integer] total journey time
    # @return [Hash]
    def calculate_basic_coverage(available, journey_seconds)
      flashback_used = [available, journey_seconds].min
      remaining = journey_seconds - flashback_used

      {
        success: true,
        can_instant: remaining == 0,
        time_remaining: remaining,
        flashback_used: flashback_used,
        reserved_for_return: 0,
        mode: :basic
      }
    end

    # Calculate coverage for return flashback travel
    # Reserves half of available time for return trip
    #
    # @param available [Integer] available flashback seconds
    # @param journey_seconds [Integer] total journey time
    # @return [Hash]
    def calculate_return_coverage(available, journey_seconds)
      # Reserve half for return trip
      usable = available / 2
      flashback_used = [usable, journey_seconds].min
      remaining = journey_seconds - flashback_used

      {
        success: true,
        can_instant: remaining == 0,
        time_remaining: remaining,
        flashback_used: flashback_used,
        reserved_for_return: usable,
        mode: :return
      }
    end

    # Calculate coverage for backloaded flashback travel
    # Instant arrival, but return takes 2x the travel time
    #
    # @param journey_seconds [Integer] total journey time
    # @return [Hash]
    def calculate_backloaded_coverage(journey_seconds)
      # Journey must be <= 12 hours for backloaded travel
      if journey_seconds > FLASHBACK_MAX_SECONDS
        return {
          success: false,
          error: 'Journey too long for backloaded travel (max 12 hours)',
          can_instant: false,
          mode: :backloaded
        }
      end

      {
        success: true,
        can_instant: true,
        time_remaining: 0,
        flashback_used: journey_seconds,
        return_debt: journey_seconds * GameConfig::Journey::BACKLOADED_DEBT_MULTIPLIER,
        reserved_for_return: 0,
        mode: :backloaded
      }
    end
  end
end
