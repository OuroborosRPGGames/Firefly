# frozen_string_literal: true

# FabricationCompletionHandler processes completed fabrication orders.
#
# Called by the scheduler every minute to check for orders that have
# completed fabrication and need to be marked ready or delivered.
#
# This handler is registered as a scheduled task and called via:
#   FabricationCompletionHandler.call(task)
#
# It can also be called directly for testing:
#   FabricationCompletionHandler.call
#
class FabricationCompletionHandler
  class << self
    # Process all completed fabrication orders
    # @param _task [ScheduledTask, nil] the scheduled task (optional)
    # @return [Hash] result with processed count
    def call(_task = nil)
      processed = FabricationService.process_completed_orders

      {
        success: true,
        processed_count: processed.size,
        orders: processed.map(&:id)
      }
    rescue StandardError => e
      warn "[FabricationCompletionHandler] Error: #{e.message}"
      { success: false, error: e.message }
    end

    # Register this handler as a scheduled task
    # Called during application initialization
    def register!
      ScheduledTask.register(
        'fabrication_completion',
        'interval',
        handler_class: 'FabricationCompletionHandler',
        interval_seconds: 60,  # Check every minute
        enabled: true,
        description: 'Process completed fabrication orders'
      )
    end
  end
end
