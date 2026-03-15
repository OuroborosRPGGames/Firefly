# frozen_string_literal: true

# Shared result handling for services
#
# Usage:
#   class MyService
#     extend ResultHandler
#
#     def self.do_something
#       return error('Something went wrong') if bad_condition
#       success('It worked!', data: { key: 'value' })
#     end
#   end
#
# Or for instance methods:
#   class MyService
#     include ResultHandler
#
#     def do_something
#       return error('Failed') if bad
#       success('Done')
#     end
#   end
#
module ResultHandler
  # Standard result struct used across all services
  # Defined outside the module methods so it's accessible when extended
  # Supports both method access (result.success) and hash access (result[:success])
  Result = Struct.new(:success, :message, :data, keyword_init: true) do
    def success?
      success == true
    end

    def failure?
      !success?
    end

    # Hash-like access for backward compatibility with existing callers
    # Allows result[:success] alongside result.success
    def [](key)
      key_sym = key.to_sym
      case key_sym
      when :success then success
      when :message then message
      when :data then data
      when :error then message unless success # Compatibility with error: key pattern
      else
        # Check data hash for custom keys (e.g., :emote, :fare, :delivery_id)
        data.is_a?(Hash) ? data[key_sym] : nil
      end
    end

    def to_h
      { success: success, message: message, data: data }
    end

    def to_api_hash
      hash = { success: success, message: message }
      hash[:data] = data if data
      hash
    end
  end

  # When extended, make Result constant available in the class
  def self.extended(base)
    base.const_set(:Result, Result) unless base.const_defined?(:Result)
  end

  # When included, make Result constant available in the class
  def self.included(base)
    base.const_set(:Result, Result) unless base.const_defined?(:Result)
  end

  # Create a success result
  #
  # @param message [String] Success message
  # @param data [Hash, nil] Optional data payload
  # @return [Result]
  def success(message, data: nil)
    Result.new(success: true, message: message, data: data)
  end

  # Create an error result
  #
  # @param message [String] Error message
  # @param data [Hash, nil] Optional data payload (e.g., for error details)
  # @return [Result]
  def error(message, data: nil)
    Result.new(success: false, message: message, data: data)
  end
end
