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

        # Complete ready actions
        TimedAction.ready_to_complete.each do |action|
          next unless action.finish!

          count += 1
          notify_completion(action)
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
