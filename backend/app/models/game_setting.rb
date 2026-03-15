# frozen_string_literal: true

# GameSetting stores key/value configuration pairs for the game.
# Supports multiple value types and categorization.
#
# Uses Redis caching to avoid repeated database queries for frequently
# accessed settings. Cache is automatically invalidated on updates.
class GameSetting < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  VALUE_TYPES = %w[string integer boolean json].freeze
  CATEGORIES = %w[general weather time ai system delve].freeze
  CACHE_TTL = GameConfig::Cache::GAME_SETTING_TTL
  CACHE_PREFIX = 'game_setting:'

  def validate
    super
    validates_presence [:key]
    validates_unique :key
    validates_includes VALUE_TYPES, :value_type if value_type
  end

  class << self
    # Get a setting value with automatic type casting
    # Uses Redis cache to avoid repeated database queries
    # @param key [String, Symbol] the setting key
    # @return [Object] the casted value
    def get(key)
      key_str = key.to_s

      # Try Redis cache first
      cached = cached_fetch(key_str)
      return cached unless cached.nil?

      # Fetch from database
      setting = first(key: key_str)
      return nil unless setting

      value = cast_value(setting.value, setting.value_type)

      # Cache the result (including nil-like values)
      set_cached(key_str, value, setting.value_type)

      value
    end

    # Get a setting as boolean
    # @param key [String, Symbol] the setting key
    # @return [Boolean]
    def boolean(key)
      value = get(key)
      value == true || value == 'true' || value == '1'
    end

    # Backward-compatible alias used by older callers/templates.
    # @param key [String, Symbol] the setting key
    # @return [Boolean]
    def get_boolean(key)
      boolean(key)
    end

    # Get a setting as integer
    # @param key [String, Symbol] the setting key
    # @return [Integer, nil]
    def integer(key)
      value = get(key)
      return nil if value.nil?

      value.is_a?(Integer) ? value : value.to_i
    end

    # Backward-compatible alias used by older callers/templates.
    # @param key [String, Symbol] the setting key
    # @return [Integer]
    def get_integer(key)
      value = get(key)
      value.nil? ? 0 : (value.is_a?(Integer) ? value : value.to_i)
    end

    # Get a setting as float
    # @param key [String, Symbol] the setting key
    # @return [Float, nil]
    def float_setting(key)
      value = get(key)
      return nil if value.nil?

      value.to_f
    end

    # Backward-compatible alias used by older callers/templates.
    # @param key [String, Symbol] the setting key
    # @return [Float, nil]
    def get_float(key)
      float_setting(key)
    end

    # Set a setting value
    # Automatically invalidates the Redis cache for this key
    # @param key [String, Symbol] the setting key
    # @param value [Object] the value to store
    # @param type [String, nil] optional value type override
    # @return [GameSetting] the updated or created setting
    def set(key, value, type: nil)
      key_str = key.to_s
      setting = first(key: key_str)

      # Invalidate cache before update
      invalidate_cache(key_str)

      if setting
        setting.update(
          value: serialize_value(value),
          value_type: type || setting.value_type,
          updated_at: Time.now
        )
        setting
      else
        create(
          key: key_str,
          value: serialize_value(value),
          value_type: type || 'string',
          created_at: Time.now,
          updated_at: Time.now
        )
      end
    end

    # Get all settings in a category
    # @param category [String] the category name
    # @return [Hash] key => value hash
    def for_category(category)
      where(category: category).each_with_object({}) do |setting, hash|
        hash[setting.key] = cast_value(setting.value, setting.value_type)
      end
    end

    # Clear all cached settings
    # @return [Boolean] success
    def clear_cache!
      return true unless defined?(REDIS_POOL)

      REDIS_POOL.with do |redis|
        keys = redis.keys("#{CACHE_PREFIX}*")
        redis.del(*keys) if keys.any?
      end
      true
    rescue StandardError => e
      warn "[GameSetting] Failed to clear cache: #{e.message}"
      false
    end

    # Invalidate cache for a specific key
    # @param key [String] the setting key
    def invalidate_cache(key)
      return unless defined?(REDIS_POOL)

      REDIS_POOL.with { |redis| redis.del("#{CACHE_PREFIX}#{key}") }
    rescue StandardError => e
      warn "[GameSetting] Failed to invalidate cache for '#{key}': #{e.message}"
    end

    private

    # Get a cached value from Redis
    # Returns nil if not cached (caller should check database)
    # Uses a wrapper hash to distinguish "cached nil" from "not cached"
    def cached_fetch(key)
      return nil unless defined?(REDIS_POOL)

      json = REDIS_POOL.with { |redis| redis.get("#{CACHE_PREFIX}#{key}") }
      return nil unless json

      data = JSON.parse(json, symbolize_names: true)
      data[:value]
    rescue StandardError => e
      warn "[GameSetting] Failed to get cached value for '#{key}': #{e.message}"
      nil
    end

    # Store a value in Redis cache
    # Wraps value in hash to handle nil values correctly
    def set_cached(key, value, value_type)
      return unless defined?(REDIS_POOL)

      cache_data = { value: value, type: value_type, cached_at: Time.now.to_i }
      REDIS_POOL.with do |redis|
        redis.setex("#{CACHE_PREFIX}#{key}", CACHE_TTL, cache_data.to_json)
      end
    rescue StandardError => e
      warn "[GameSetting] Failed to set cached value for '#{key}': #{e.message}"
    end

    def cast_value(value, type)
      return nil if value.nil?

      case type
      when 'integer'
        value.to_i
      when 'boolean'
        %w[true 1 yes].include?(value.to_s.downcase)
      when 'json'
        JSON.parse(value)
      else
        value
      end
    rescue JSON::ParserError
      {}
    end

    def serialize_value(value)
      case value
      when Hash, Array
        value.to_json
      else
        value.to_s
      end
    end
  end
end
