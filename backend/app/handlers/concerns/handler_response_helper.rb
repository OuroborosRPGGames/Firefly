# frozen_string_literal: true

# Shared response helper for handlers that need to return hash-based responses.
#
# Usage:
#   class MyHandler
#     class << self
#       extend HandlerResponseHelper
#
#       def process_response(...)
#         return error_response("Something went wrong") if bad
#         success_response("It worked!", data: { key: 'value' })
#       end
#     end
#   end
#
# This standardizes the response format across all handlers:
# - success: { success: true, message: "...", data: { ... } }
# - error:   { success: false, message: "...", error: "..." }
#
module HandlerResponseHelper
  # Create a success response hash
  #
  # @param message [String] Success message
  # @param data [Hash] Additional data to include
  # @return [Hash] Response hash with success: true
  def success_response(message, **data)
    {
      success: true,
      message: message,
      data: data
    }
  end

  # Create an error response hash
  #
  # @param message [String] Error message
  # @return [Hash] Response hash with success: false
  def error_response(message)
    {
      success: false,
      message: message,
      error: message
    }
  end

  # Convert a service result (from ResultHandler) to a response hash
  #
  # @param result [ResultHandler::Result, Hash, Object] Service result
  # @param data [Hash] Additional data to merge on success
  # @return [Hash] Response hash
  def result_to_response(result, **data)
    # Handle ResultHandler::Result structs (prefer .success? method)
    # Handle plain objects with .success attribute
    # Handle hashes with :success key
    success = if result.respond_to?(:success?)
                result.success?
              elsif result.respond_to?(:success)
                result.success
              elsif result.is_a?(Hash)
                result[:success]
              else
                false
              end

    message = if result.respond_to?(:message)
                result.message
              elsif result.is_a?(Hash)
                result[:message] || result[:error]
              else
                nil
              end

    if success
      success_response(message, **data)
    else
      error_response(message || 'Unknown error')
    end
  end

  # Find a record by ID with standard error handling
  #
  # @param model_class [Class] The Sequel model class
  # @param id [Integer] Record ID
  # @param error_message [String] Error message if not found
  # @yield [record] Block to execute if record found
  # @return [Hash] Result from block or error response
  def with_record(model_class, id, error_message: nil)
    record = model_class[id]
    return error_response(error_message || "#{model_class.name.split('::').last} not found") unless record

    yield record
  end
end
