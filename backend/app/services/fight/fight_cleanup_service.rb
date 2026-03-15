# frozen_string_literal: true

# Cleans up stale and ended fights.
#
# Runs periodically via the scheduler to:
# - End fights with only one side remaining (0 or 1 active participants)
# - End fights that haven't progressed in 15+ minutes
# - End fights where all human participants are offline
# - End fights where all human participants have left the room
#
# @example
#   FightCleanupService.cleanup_all!
#   # => { cleaned: 2, stale: 1, ended: 1 }
#
class FightCleanupService
  class << self
    # Clean up all fights that need it
    # @return [Hash] summary of cleanup actions
    def cleanup_all!
      results = { cleaned: 0, stale: 0, ended: 0, very_stale: 0, errors: [] }

      # Track which fights we already cleaned so the second loop skips them
      cleaned_ids = Set.new

      # Clean up fights that have been inactive for 15+ minutes or have <=1 participants
      Fight.needing_cleanup.each do |fight|
        cleanup_fight!(fight, results)
        cleaned_ids << fight.id
      rescue StandardError => e
        results[:errors] << { fight_id: fight.id, error: e.message }
      end

      # Check all ongoing fights for participant-state reasons (all offline / all left room)
      Fight.where(status: %w[input resolving narrative]).all.each do |fight|
        next if cleaned_ids.include?(fight.id)

        cleanup_fight_participant_state!(fight, results)
      rescue StandardError => e
        results[:errors] << { fight_id: fight.id, error: e.message }
      end

      # Also clean up very stale fights (24+ hours old)
      very_stale_count = Fight.cleanup_stale_fights!
      results[:very_stale] = very_stale_count
      results[:cleaned] += very_stale_count

      results
    end

    private

    def cleanup_fight!(fight, results)
      reason = determine_reason(fight)
      return unless reason

      end_fight!(fight, reason, results)
    end

    def cleanup_fight_participant_state!(fight, results)
      reason = determine_participant_reason(fight)
      return unless reason

      end_fight!(fight, reason, results)
    end

    def end_fight!(fight, reason, results)
      # Notify participants before ending
      notify_fight_ending(fight, reason)

      # Complete the fight (also resets wake timers for knocked-out participants)
      fight.complete!

      # Update stats
      results[:cleaned] += 1
      case reason
      when :stale
        results[:stale] += 1
      when :no_opponents, :last_standing, :all_offline, :all_left_room
        results[:ended] += 1
      end
    end

    def determine_reason(fight)
      active_count = fight.active_participants.count

      if active_count == 0
        :no_opponents
      elsif active_count == 1
        :last_standing
      elsif fight.stale?
        :stale
      end
    end

    # Check participant-state reasons: all humans offline or all humans left the room.
    # Returns nil for NPC-only fights (no humans to check).
    def determine_participant_reason(fight)
      human_participants = fight.active_participants.reject(&:is_npc)
      return nil if human_participants.empty?

      return :all_offline if human_participants.all? { |p| !p.character_instance&.online }

      # Grace period before cleaning up fights where everyone left the room
      last_activity = fight.last_action_at || fight.started_at || fight.created_at
      if (Time.now - last_activity) > GameConfig::Cleanup::FIGHT_ALL_LEFT_ROOM_SECONDS
        return :all_left_room if human_participants.all? { |p|
          ci = p.character_instance
          ci.nil? || ci.current_room_id != fight.room_id
        }
      end

      nil
    end

    def notify_fight_ending(fight, reason)
      message = case reason
                when :stale
                  'The fight has ended due to inactivity.'
                when :no_opponents
                  'The fight has ended - no combatants remain.'
                when :last_standing
                  winner = fight.active_participants.first
                  winner_name = winner&.character_instance&.character&.name || 'Unknown'
                  "The fight has ended. #{winner_name} is victorious!"
                when :all_offline
                  'The fight has ended - all combatants have gone offline.'
                when :all_left_room
                  'The fight has ended - all combatants have left the area.'
                else
                  'The fight has ended.'
                end

      # Broadcast to the room
      room = fight.room
      return unless room

      BroadcastService.to_room(
        room.id,
        {
          type: 'combat_ended',
          fight_id: fight.id,
          reason: reason.to_s,
          message: message
        },
        type: :combat
      )
    end
  end
end
