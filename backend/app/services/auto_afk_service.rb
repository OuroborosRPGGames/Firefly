# frozen_string_literal: true

# Service for automatically managing AFK status and disconnecting inactive players.
#
# Timeout Configuration (based on Ravencroft):
# - Players alone in room: 60 minutes -> Auto-AFK
# - Players with others: 17 minutes -> Auto-AFK
# - No WebSocket ping: 5 minutes -> Mark disconnected
# - Agents (API token users): 120 minutes -> Auto-logout (longer for test agents)
# - Hard disconnect timeout: 180 minutes (3 hours) -> Force logout
#
# Usage:
#   AutoAfkService.process_idle_characters!  # Called by scheduler every 5 minutes
#
class AutoAfkService
  # Timeout constants - now from GameConfig::Timeouts (in minutes)
  PLAYER_ALONE_TIMEOUT = GameConfig::Timeouts::PLAYER_ALONE
  PLAYER_WITH_OTHERS_TIMEOUT = GameConfig::Timeouts::PLAYER_WITH_OTHERS
  AGENT_TIMEOUT = GameConfig::Timeouts::AGENT_LOGOUT
  HARD_DISCONNECT_TIMEOUT = GameConfig::Timeouts::HARD_DISCONNECT
  WEBSOCKET_TIMEOUT = GameConfig::Timeouts::WEBSOCKET_STALE

  class << self
    # Main entry point - process all idle characters
    # Called by the scheduler every 5 minutes
    def process_idle_characters!
      processed = { afk: 0, disconnected: 0, skipped: 0 }

      # Process online characters using dataset scope
      CharacterInstance.online.each do |ci|
        result = process_character(ci)
        processed[result] += 1
      end

      log_processing_results(processed) if processed[:afk] > 0 || processed[:disconnected] > 0
      processed
    end

    private

    # Process a single character instance
    def process_character(char_instance)
      # Skip NPCs - they are controlled by the game system, not player activity
      return :skipped if char_instance.character&.npc?

      # Skip exempt characters (staff, etc.)
      return :skipped if char_instance.auto_afk_exempt?

      user = char_instance.character&.user
      is_agent = user&.agent?
      inactive_mins = char_instance.inactive_minutes

      # Check for hard disconnect (180 minutes for players, 120 for agents)
      if should_force_logout?(char_instance, is_agent, inactive_mins)
        reason = is_agent ? 'agent_timeout' : 'hard_timeout'
        char_instance.auto_logout!(reason)
        return :disconnected
      end

      # Check for WebSocket disconnect (5 minutes without ping)
      # Skip for agents - they use API tokens, not WebSocket
      if !is_agent && char_instance.websocket_stale?(WEBSOCKET_TIMEOUT)
        char_instance.auto_logout!('websocket_timeout')
        return :disconnected
      end

      # Check for auto-AFK (only if not already in a presence state)
      # Skip if already AFK, semi-AFK (player said they're partially here),
      # or GTG (player already flagged departure)
      unless char_instance.afk? || char_instance.semiafk? || char_instance.gtg?
        if should_auto_afk?(char_instance, inactive_mins)
          set_auto_afk!(char_instance)
          return :afk
        end
      end

      :skipped
    end

    # Determine if character should be force logged out
    # Agents get 2 hours (based on last command execution)
    # Players get 3 hours (based on last activity)
    def should_force_logout?(char_instance, is_agent, inactive_mins)
      if is_agent
        inactive_mins >= AGENT_TIMEOUT
      else
        inactive_mins >= HARD_DISCONNECT_TIMEOUT
      end
    end

    # Determine if character should be auto-set to AFK
    def should_auto_afk?(char_instance, inactive_mins)
      # Different timeout based on room occupancy
      timeout = if char_instance.alone_in_room?
                  PLAYER_ALONE_TIMEOUT
                else
                  PLAYER_WITH_OTHERS_TIMEOUT
                end

      inactive_mins >= timeout
    end

    # Set character to AFK status
    def set_auto_afk!(char_instance)
      char_instance.set_afk!

      # Notify the character
      BroadcastService.to_character(
        char_instance,
        "You have been marked AFK due to inactivity."
      )

      # Notify the room (personalized per viewer)
      if char_instance.current_room_id
        message = "#{char_instance.character.full_name} has gone AFK."

        room_chars = CharacterInstance.where(
          current_room_id: char_instance.current_room_id,
          online: true
        ).exclude(id: char_instance.id).eager(:character).all

        room_chars.each do |viewer|
          personalized = MessagePersonalizationService.personalize(
            message: message,
            viewer: viewer,
            room_characters: room_chars + [char_instance]
          )
          BroadcastService.to_character(viewer, personalized)
        end
      end

      warn "[AutoAFK] Marked #{char_instance.character.full_name} as AFK (#{char_instance.inactive_minutes} min inactive)" if ENV['LOG_AFK']
    end

    # Log processing results
    def log_processing_results(results)
      warn "[AutoAFK] Processed: #{results[:afk]} marked AFK, #{results[:disconnected]} disconnected, #{results[:skipped]} skipped" if ENV['LOG_AFK']
    end
  end
end
