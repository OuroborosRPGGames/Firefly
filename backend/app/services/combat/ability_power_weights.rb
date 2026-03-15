# frozen_string_literal: true

require 'yaml'

# Loads and manages ability power calculation weights from YAML.
# Weights are loaded once at startup and cached for performance.
# The auto-tuning simulator can modify and save weights.
#
# The YAML file contains both:
# - coefficients: Raw formula coefficients for the balance simulator
# - weights: Computed values for AbilityPowerCalculator
#
# @example Access a weight
#   AbilityPowerWeights.get('global', 'power_per_damage')  # => 6.67
#   AbilityPowerWeights.status('stunned')                   # => 75
#
# @example Access a coefficient
#   AbilityPowerWeights.coefficient('cc_skip_mult')         # => 1.0
#
# @example Modify and save weights (for auto-tuning)
#   AbilityPowerWeights.set('status', 'stunned', 80)
#   AbilityPowerWeights.save!
#
class AbilityPowerWeights
  YAML_PATH = File.join(__dir__, '../../../config/ability_power_weights.yml')

  MUTEX = Mutex.new

  class << self
    # Load weights from YAML
    def load!
      @weights = {}
      @coefficients = {}
      @baseline = {}
      @metadata = {}
      @locked_coefficients = []
      @locked_weights = []
      @last_run = {}

      load_from_yaml! if File.exist?(YAML_PATH)

      @loaded = true
    end

    # Check if weights are loaded
    def loaded?
      @loaded == true
    end

    # Reload weights from file
    def reload!
      MUTEX.synchronize do
        @weights = nil
        @coefficients = nil
        @baseline = nil
        @metadata = nil
        @locked_coefficients = nil
        @locked_weights = nil
        @last_run = nil
        @loaded = false
        load!
      end
    end

    # Get a weight value
    # @param category [String] Category name (global, status, aoe_circle, etc.)
    # @param key [String] Weight key
    # @param default [Numeric] Default value if not found
    # @return [Numeric] The weight value
    def get(category, key, default: nil)
      ensure_loaded!
      @weights.dig(category.to_s, key.to_s) || default
    end

    # Set a weight value (for auto-tuning)
    # @param category [String] Category name
    # @param key [String] Weight key
    # @param value [Numeric] New value
    def set(category, key, value)
      ensure_loaded!
      @weights[category.to_s] ||= {}
      @weights[category.to_s][key.to_s] = value
    end

    # Get a raw coefficient value (used by balance simulator)
    # @param key [String] Coefficient key (e.g., 'cc_skip_mult')
    # @param default [Numeric] Default value if not found
    # @return [Numeric] The coefficient value
    def coefficient(key, default: nil)
      ensure_loaded!
      @coefficients[key.to_s] || default
    end

    # Set a coefficient value (for auto-tuning)
    # @param key [String] Coefficient key
    # @param value [Numeric] New value
    def set_coefficient(key, value)
      ensure_loaded!
      @coefficients[key.to_s] = value
    end

    # Get baseline game assumptions
    # @param key [String] Baseline key (e.g., 'damage', 'hp')
    # @return [Numeric] The baseline value
    def baseline(key)
      ensure_loaded!
      @baseline[key.to_s]
    end

    # Convenience method for status effect power
    # @param effect_name [String] Status effect name
    # @param default [Numeric] Default value if not found
    # @return [Numeric] Power value for the effect
    def status(effect_name, default: 15)
      get('status', effect_name.to_s, default: default)
    end

    # Convenience method for global weights
    # @param key [String] Weight key
    # @return [Numeric] Weight value
    def global(key)
      get('global', key)
    end

    # Get a weight value by dot-notation path
    # @param path [String] Dot-separated path like "status.stunned" or "aoe_circle.radius_1"
    # @param default [Numeric] Default value if not found
    # @return [Numeric] The weight value
    def weight(path, default: nil)
      ensure_loaded!
      parts = path.to_s.split('.')
      return default if parts.empty?

      if parts.size == 1
        # Just category, return nil
        default
      else
        category = parts[0]
        key = parts[1..-1].join('.')
        @weights.dig(category, key) || default
      end
    end

    # Set a weight value by dot-notation path
    # @param path [String] Dot-separated path like "status.stunned"
    # @param value [Numeric] New value
    def set_weight(path, value)
      ensure_loaded!
      parts = path.to_s.split('.')
      return if parts.size < 2

      category = parts[0]
      key = parts[1..-1].join('.')
      @weights[category] ||= {}
      @weights[category][key] = value
    end

    # Convenience method for AoE circle target estimates
    # @param radius [Integer] Circle radius
    # @return [Float] Estimated targets
    def aoe_circle_targets(radius)
      key = "radius_#{radius}"
      result = get('aoe_circle', key)
      result || [radius * 2, get('aoe_circle', 'radius_max', default: 8)].min.to_f
    end

    # Get all weights as a hash (for debugging/export)
    # @return [Hash] All weights organized by category
    def all
      ensure_loaded!
      @weights.dup
    end

    # Get all coefficients as a hash
    # @return [Hash] All coefficients
    def all_coefficients
      ensure_loaded!
      @coefficients.dup
    end

    # Check if a coefficient is locked from auto-tuning
    # @param key [String] Coefficient key
    # @return [Boolean] true if locked
    def locked?(key)
      ensure_loaded!
      (@locked_coefficients || []).include?(key.to_s)
    end

    # Set the locked status for a coefficient
    # @param key [String] Coefficient key
    # @param locked [Boolean] Whether to lock the coefficient
    def set_locked(key, locked)
      ensure_loaded!
      @locked_coefficients ||= []
      if locked
        @locked_coefficients << key.to_s unless @locked_coefficients.include?(key.to_s)
      else
        @locked_coefficients.delete(key.to_s)
      end
    end

    # Get all locked coefficient keys
    # @return [Array<String>] List of locked coefficient keys
    def locked_coefficients
      ensure_loaded!
      @locked_coefficients || []
    end

    # Check if a weight is locked
    # @param path [String] Weight path (e.g., "status.stunned")
    # @return [Boolean] true if locked
    def locked_weight?(path)
      ensure_loaded!
      (@locked_weights || []).include?(path.to_s)
    end

    # Set the locked status for a weight
    # @param path [String] Weight path
    # @param locked [Boolean] Whether to lock the weight
    def set_weight_locked(path, locked)
      ensure_loaded!
      @locked_weights ||= []
      if locked
        @locked_weights << path.to_s unless @locked_weights.include?(path.to_s)
      else
        @locked_weights.delete(path.to_s)
      end
    end

    # Get all locked weight paths
    # @return [Array<String>] List of locked weight paths
    def locked_weights
      ensure_loaded!
      @locked_weights || []
    end

    # Store results from last auto-tune run
    # @param timestamp [String] When the run was performed
    # @param mode [Symbol] :fresh or :refine
    # @param iterations [Integer] Number of iterations run
    # @param results [Hash] Per-coefficient results { key => { win_rate:, original:, final:, balanced: } }
    def set_last_run(timestamp:, mode:, iterations:, results:)
      ensure_loaded!
      @last_run = {
        'timestamp' => timestamp,
        'mode' => mode.to_s,
        'iterations' => iterations,
        'results' => results
      }
    end

    # Get results from last auto-tune run
    # @return [Hash] { timestamp:, mode:, iterations:, results: }
    def last_run
      ensure_loaded!
      @last_run || {}
    end

    # Get all status effect weights
    # @return [Hash] Status effect name => power value
    def status_effects
      ensure_loaded!
      @weights['status']&.dup || {}
    end

    # Get all entries for a category
    # @param category [String] Category name
    # @return [Hash] key => value pairs for the category
    def entries_for_category(category)
      ensure_loaded!
      @weights[category.to_s]&.dup || {}
    end

    # Save weights back to YAML
    def save!
      MUTEX.synchronize do
        ensure_loaded_unlocked!

        data = {
          'version' => @metadata['version'] || 1,
          'mode' => @metadata['mode'] || 'tuned',
          'last_tuned' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
          'baseline' => @baseline,
          'coefficients' => @coefficients,
          'weights' => @weights,
          'locked_coefficients' => @locked_coefficients || [],
          'locked_weights' => @locked_weights || [],
          'last_run' => @last_run || {}
        }

        # Write YAML with nice formatting
        yaml_content = generate_yaml_with_comments(data)
        File.write(YAML_PATH, yaml_content)
      end
    end

    # Get the YAML path (for testing)
    def yaml_path
      YAML_PATH
    end

    private

    def ensure_loaded!
      return if loaded?

      MUTEX.synchronize do
        load! unless loaded?
      end
    end

    # Called from within a MUTEX.synchronize block to avoid deadlock
    def ensure_loaded_unlocked!
      load! unless loaded?
    end

    def load_from_yaml!
      data = YAML.load_file(YAML_PATH)
      return unless data.is_a?(Hash)

      @metadata = {
        'version' => data['version'],
        'mode' => data['mode']
      }

      @baseline = stringify_keys(data['baseline'] || {})
      @coefficients = stringify_keys(data['coefficients'] || {})

      # Load weights - convert nested hash to string keys
      weights_data = data['weights'] || {}
      @weights = {}
      weights_data.each do |category, values|
        @weights[category.to_s] = stringify_keys(values || {})
      end

      # Load locked coefficients, locked weights, and last run results
      @locked_coefficients = Array(data['locked_coefficients']).map(&:to_s)
      @locked_weights = Array(data['locked_weights']).map(&:to_s)
      @last_run = stringify_keys(data['last_run'] || {})
      @last_run['results'] = stringify_keys(@last_run['results'] || {}) if @last_run['results']
    end


    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash)

      hash.transform_keys(&:to_s)
    end

    def generate_yaml_with_comments(data)
      lines = []
      lines << "# Ability Power Calculation Weights"
      lines << "# Used by AbilityPowerCalculator for real ability power rating."
      lines << "# Run the auto-tuning simulator to adjust these values:"
      lines << "#   ruby scripts/ability_balance_simulator.rb --synthetic-tune"
      lines << "#"
      lines << "# Last tuned: #{data['last_tuned']}"
      lines << ""
      lines << "version: #{data['version']}"
      lines << "mode: #{data['mode']}"
      lines << ""

      # Baseline
      lines << "baseline:"
      data['baseline'].each do |key, value|
        lines << "  #{key}: #{format_yaml_value(value)}"
      end
      lines << ""

      # Coefficients
      lines << "coefficients:"
      data['coefficients'].each do |key, value|
        lines << "  #{key}: #{format_yaml_value(value)}"
      end
      lines << ""

      # Weights
      lines << "weights:"
      data['weights'].each do |category, values|
        lines << "  #{category}:"
        values.each do |key, value|
          lines << "    #{key}: #{format_yaml_value(value)}"
        end
      end
      lines << ""

      # Locked coefficients (for auto-tuning)
      locked = data['locked_coefficients'] || []
      lines << "locked_coefficients:"
      if locked.empty?
        lines << "  []"
      else
        locked.each do |key|
          lines << "  - #{key}"
        end
      end
      lines << ""

      # Locked weights (UI protection)
      locked_w = data['locked_weights'] || []
      lines << "locked_weights:"
      if locked_w.empty?
        lines << "  []"
      else
        locked_w.each do |path|
          lines << "  - #{path}"
        end
      end
      lines << ""

      # Last run results
      last_run = data['last_run'] || {}
      lines << "last_run:"
      if last_run.empty?
        lines << "  {}"
      else
        lines << "  timestamp: \"#{last_run['timestamp']}\""
        lines << "  mode: #{last_run['mode']}"
        lines << "  iterations: #{last_run['iterations']}"
        lines << "  results:"
        (last_run['results'] || {}).each do |coef_key, result|
          if result.is_a?(Hash)
            lines << "    #{coef_key}:"
            lines << "      win_rate: #{format_yaml_value(result['win_rate'])}"
            lines << "      original: #{format_yaml_value(result['original'])}"
            lines << "      final: #{format_yaml_value(result['final'])}"
            lines << "      balanced: #{result['balanced']}"
          end
        end
      end

      lines.join("\n") + "\n"
    end

    def format_yaml_value(value)
      case value
      when Float
        # Format with up to 2 decimal places, removing trailing zeros
        formatted = format('%.2f', value)
        formatted.sub(/\.?0+$/, '')
      else
        value.to_s
      end
    end
  end
end
