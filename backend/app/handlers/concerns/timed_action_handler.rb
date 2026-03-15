# frozen_string_literal: true

# Shared behavior for handlers that process timed actions
#
# Provides consistent result storage and common utilities
#
# Usage:
#   class MyHandler
#     extend TimedActionHandler
#
#     def self.call(timed_action)
#       # ... processing ...
#       store_success(timed_action, { key: 'value' })
#       # or
#       store_error(timed_action, 'Something went wrong')
#     end
#   end
#
module TimedActionHandler
  # Store a successful result on the timed action
  #
  # @param timed_action [TimedAction] the action to update
  # @param data [Hash] additional data to store
  def store_success(timed_action, data = {})
    timed_action.update(result_data: data.merge(success: true).to_json)
  end

  # Store an error result on the timed action
  #
  # @param timed_action [TimedAction] the action to update
  # @param message [String] the error message
  def store_error(timed_action, message)
    timed_action.update(result_data: { success: false, error: message }.to_json)
  end

  # Store a raw result hash on the timed action
  # (For handlers that need full control over the data)
  #
  # @param timed_action [TimedAction] the action to update
  # @param data [Hash] the result data
  def store_result(timed_action, data)
    timed_action.update(result_data: data.to_json)
  end
end
