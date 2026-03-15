# frozen_string_literal: true

# Cleans up stuck and abandoned activity instances.
#
# Runs periodically via GameCleanupService.sweep! to end activities where:
# - All participants are offline
# - All participants have left the room
# - The activity is stuck in setup
# - No round progress for 30+ minutes
# - The activity has been running for 24+ hours
#
# @example
#   ActivityCleanupService.cleanup_all!
#   # => { cleaned: 3, reasons: { all_offline: 1, inactive: 1, too_long: 1 }, errors: [] }
#
class ActivityCleanupService
  class << self
    def cleanup_all!
      results = { cleaned: 0, reasons: Hash.new(0), errors: [] }

      return results unless defined?(ActivityInstance)

      ActivityInstance.where(running: true).each do |instance|
        reason = determine_reason(instance)
        next unless reason

        cleanup_instance!(instance, reason, results)
      rescue StandardError => e
        results[:errors] << { instance_id: instance.id, error: e.message }
      end

      results
    end

    private

    def determine_reason(instance)
      participants = instance.active_participants.all
      return nil if participants.empty? # No active participants means activity is winding down naturally

      # Check if stuck in setup too long
      if instance.in_setup? && age_seconds(instance.created_at) > GameConfig::Cleanup::ACTIVITY_STUCK_SETUP_SECONDS
        return :stuck_setup
      end

      # Check if running too long overall
      if age_seconds(instance.created_at) > GameConfig::Cleanup::ACTIVITY_MAX_DURATION_SECONDS
        return :too_long
      end

      # Check if all participants are offline (character_instance returns nil when offline)
      online_instances = participants.filter_map(&:character_instance)
      return :all_offline if online_instances.empty?

      # Check if all online participants have left the room
      if online_instances.all? { |ci| ci.current_room_id != instance.room_id }
        last_activity = instance.round_started_at || instance.created_at
        if age_seconds(last_activity) > GameConfig::Cleanup::ACTIVITY_ALL_LEFT_ROOM_SECONDS
          return :left_room
        end
      end

      # Check inactivity (skip if paused for combat - they're waiting for a fight)
      unless instance.paused_for_combat?
        last_activity = instance.round_started_at || instance.created_at
        if age_seconds(last_activity) > GameConfig::Cleanup::ACTIVITY_INACTIVITY_SECONDS
          return :inactive
        end
      end

      nil
    end

    def cleanup_instance!(instance, reason, results)
      # Notify the room
      notify_cleanup(instance, reason)

      # End the activity using the centralized completion path so side effects
      # (media shutdown, mission triggers, etc.) remain consistent.
      finish_activity!(instance)

      results[:cleaned] += 1
      results[:reasons][reason] += 1
    end

    def notify_cleanup(instance, reason)
      message = case reason
                when :all_offline
                  'The activity has ended - all participants have gone offline.'
                when :left_room
                  'The activity has ended - all participants have left the area.'
                when :stuck_setup
                  'The activity has ended - setup was not completed in time.'
                when :inactive
                  'The activity has ended due to inactivity.'
                when :too_long
                  'The activity has ended - maximum duration reached.'
                else
                  'The activity has ended.'
                end

      BroadcastService.to_room(
        instance.room_id,
        {
          content: message,
          type: 'activity_ended'
        },
        type: :activity
      )
    rescue StandardError => e
      warn "[ActivityCleanup] Failed to notify room #{instance.room_id}: #{e.message}"
    end

    def age_seconds(timestamp)
      return Float::INFINITY unless timestamp

      Time.now - timestamp
    end

    def finish_activity!(instance)
      ActivityService.complete_activity(instance, success: false, broadcast: false)
    end
  end
end
