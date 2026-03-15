# frozen_string_literal: true

module NameGeneration
  # WeightingTracker prevents repetitive name generation by tracking
  # recently used names and applying weight penalties.
  #
  # Names used recently have reduced probability of being selected again.
  # The penalty decays over time, allowing names to return to normal weight.
  #
  # Usage:
  #   tracker = WeightingTracker.new
  #   tracker.record_use(:forename, "James")
  #   weighted = tracker.apply_weights(names_array)
  #   selected = tracker.weighted_select(weighted)
  #
  class WeightingTracker
    MAX_HISTORY_SIZE = 100
    DEFAULT_DECAY_RATE = 0.1  # Decay per hour
    BASE_PENALTY = 3.0        # Max penalty for very recent use

    def initialize(decay_rate: DEFAULT_DECAY_RATE)
      @history = Hash.new { |h, k| h[k] = [] }
      @decay_rate = decay_rate
    end

    # Record that a name was used
    # @param category [Symbol] the name category (:forename, :surname, :city, :street, :shop)
    # @param name [String] the name that was used
    # @return [void]
    def record_use(category, name)
      @history[category] << { name: name.to_s.downcase, timestamp: Time.now }
      trim_history(category)
    end

    # Apply weight penalties to an array of names based on recent use
    # @param names [Array<Hash, String>] array of name hashes with :name and :weight keys, or simple strings
    # @param category [Symbol, nil] specific category to check, or nil for all
    # @return [Array<Hash>] names with :effective_weight added
    def apply_weights(names, category: nil)
      names.map do |entry|
        if entry.is_a?(Hash)
          name = entry[:name] || entry[:value]
          base_weight = entry[:weight] || 1.0
          penalty = calculate_penalty(name, category: category)
          effective_weight = [base_weight - penalty, 0.1].max
          entry.merge(effective_weight: effective_weight)
        else
          # Simple string entry
          name = entry.to_s
          penalty = calculate_penalty(name, category: category)
          effective_weight = [1.0 - penalty, 0.1].max
          { name: name, weight: 1.0, effective_weight: effective_weight }
        end
      end
    end

    # Select a name using weighted random selection
    # @param weighted_names [Array<Hash>] names with :effective_weight
    # @return [String] the selected name
    def weighted_select(weighted_names)
      return nil if weighted_names.empty?

      total_weight = weighted_names.sum { |n| n[:effective_weight] || n[:weight] || 1.0 }
      return weighted_names.sample[:name] if total_weight <= 0

      random_point = rand * total_weight
      cumulative = 0.0

      weighted_names.each do |entry|
        cumulative += entry[:effective_weight] || entry[:weight] || 1.0
        return entry[:name] if cumulative >= random_point
      end

      # Fallback
      weighted_names.last[:name]
    end

    # Calculate penalty for a specific name based on recent use
    # @param name [String] the name to check
    # @param category [Symbol, nil] specific category or nil for all
    # @return [Float] penalty value (0 = no penalty, higher = more penalty)
    def calculate_penalty(name, category: nil)
      name_lower = name.to_s.downcase
      categories = category ? [category] : @history.keys

      max_penalty = 0.0

      categories.each do |cat|
        history = @history[cat]
        history_length = history.length
        next if history_length == 0

        history.each_with_index do |entry, idx|
          next unless entry[:name] == name_lower

          # More recent = higher penalty (higher idx = more recent in our append-based history)
          recency_factor = (idx + 1).to_f / history_length

          # Time decay: penalty decreases over time
          age_hours = (Time.now - entry[:timestamp]) / 3600.0
          time_decay = Math.exp(-@decay_rate * age_hours)

          penalty = BASE_PENALTY * recency_factor * time_decay
          max_penalty = [max_penalty, penalty].max
        end
      end

      max_penalty
    end

    # Check if a name was recently used
    # @param name [String] the name to check
    # @param category [Symbol, nil] specific category or nil for all
    # @return [Boolean]
    def recently_used?(name, category: nil)
      calculate_penalty(name, category: category) > 0.5
    end

    # Get history size for a category
    # @param category [Symbol] the category
    # @return [Integer]
    def history_size(category)
      @history[category].length
    end

    # Clear all history (for testing)
    # @return [void]
    def clear!
      @history.clear
    end

    # Clear history for a specific category
    # @param category [Symbol] the category to clear
    # @return [void]
    def clear_category!(category)
      @history[category] = []
    end

    private

    # Trim history to max size
    def trim_history(category)
      return if @history[category].length <= MAX_HISTORY_SIZE

      @history[category] = @history[category].last(MAX_HISTORY_SIZE)
    end
  end
end
