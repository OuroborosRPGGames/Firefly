# frozen_string_literal: true

module Firefly
  # Processes timed actions on each game tick
  #
  # Integrates with the Scheduler to:
  # - Complete delayed actions when their time is up
  # - Update progress for active actions
  # - Clean up expired cooldowns periodically
  #
  class TimedActionProcessor
    class << self
      # Process all ready timed actions
      # Called on each game tick
      # @param tick_event [TickEvent] the current tick
      # @return [Integer] number of actions processed
      def process_tick(tick_event)
        count = 0

        # Complete ready actions (each action isolated so one failure can't block others)
        TimedAction.ready_to_complete.each do |action|
          begin
            next unless action.finish!

            count += 1
            notify_completion(action)
          rescue StandardError => e
            # If finish! itself raises (e.g. error-handling update also fails),
            # force-complete the action to prevent it from blocking all subsequent
            # actions on every future tick.
            log("Action #{action.id} (#{action.action_name}) failed: #{e.message}")
            force_complete_stuck_action(action)
          end
        end

        # Clean up expired cooldowns every 60 ticks (~5 minutes)
        cleanup_cooldowns if (tick_event.tick_number % 60).zero?

        count
      end

      # Register with the global scheduler
      def register!
        return unless defined?(Firefly::Scheduler)

        Firefly::Scheduler.on_tick(1) do |tick_event|
          process_tick(tick_event)
        end

        log('TimedActionProcessor registered with scheduler')
      end

      # Get summary of active actions
      # @return [Hash]
      def status
        {
          active_actions: TimedAction.where(status: 'active').count,
          active_cooldowns: ActionCooldown.where { expires_at > Time.now }.count,
          ready_to_complete: TimedAction.ready_to_complete.count
        }
      end

      private

      def notify_completion(action)
        # This is where we'd notify the character via WebSocket
        # For now, just log it
        log("Action completed: #{action.action_name} for character #{action.character_instance_id}")
      end

      # Force-complete a stuck action that keeps raising errors.
      # Uses a raw SQL update to bypass any model-level issues.
      def force_complete_stuck_action(action)
        DB[:timed_actions]
          .where(id: action.id, status: 'active')
          .update(status: 'completed', completed_at: Time.now)
        reset_character_movement_state(action)
      rescue StandardError => e
        log("Force-complete also failed for action #{action.id}: #{e.message}")
      end

      # Reset movement state for a character whose movement action errored out.
      def reset_character_movement_state(action)
        return unless action.action_name == 'movement'

        DB[:character_instances]
          .where(id: action.character_instance_id, movement_state: 'moving')
          .update(
            movement_state: 'idle',
            final_destination_id: nil,
            movement_direction: nil
          )
      rescue StandardError => e
        log("Movement state reset failed for character #{action.character_instance_id}: #{e.message}")
      end

      def cleanup_cooldowns
        cleaned = ActionCooldown.cleanup_expired!
        log("Cleaned up #{cleaned} expired cooldowns") if cleaned.positive?
      rescue StandardError => e
        log("Cooldown cleanup error: #{e.message}")
      end

      def log(message)
        puts "[TimedActionProcessor] #{message}"
      end
    end
  end
end
