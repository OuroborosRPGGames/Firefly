# frozen_string_literal: true

# Simple feature flag module with opt-in pattern (disabled by default)
# Features must be explicitly enabled via environment variables
module FeatureFlags
  class << self
    # Check if a feature is enabled (opt-in: disabled by default)
    # Accepts 'true', '1', 'yes', 'on' (case-insensitive) as enabled values
    def enabled?(flag_name)
      value = ENV.fetch("FEATURE_#{flag_name.upcase}", 'false')
      %w[true 1 yes on].include?(value.to_s.downcase)
    end

    # Check if a feature is disabled
    def disabled?(flag_name)
      !enabled?(flag_name)
    end

    # List all feature flags and their status (for debugging/admin)
    def status
      feature_envs = ENV.keys.select { |k| k.start_with?('FEATURE_') }
      feature_envs.each_with_object({}) do |key, hash|
        flag_name = key.sub('FEATURE_', '').downcase
        hash[flag_name] = enabled?(flag_name)
      end
    end
  end
end
