# frozen_string_literal: true

# Service for handling stat point allocation during character creation.
# Validates allocations and creates CharacterStat records.
class StatAllocationService
  extend ResultHandler

  class AllocationError < StandardError; end

  # Create CharacterStats for a character instance based on allocations
  # @param character_instance [CharacterInstance] The character instance to create stats for
  # @param allocations [Hash] Hash of { stat_block_id => { stat_id => level, ... }, ... }
  # @return [Array<CharacterStat>] Created character stats
  def self.create_stats_for_character(character_instance, allocations)
    created_stats = []

    allocations.each do |stat_block_id, stat_allocations|
      stat_block = StatBlock[stat_block_id.to_i]
      next unless stat_block

      # Validate the allocation
      validation = stat_block.validate_allocation(stat_allocations)
      unless validation[:valid]
        raise AllocationError, "Invalid allocation for #{stat_block.name}: #{validation[:errors].join(', ')}"
      end

      # Create CharacterStat records
      stat_allocations.each do |stat_id, level|
        stat = Stat[stat_id.to_i]
        next unless stat && stat.stat_block_id == stat_block.id

        char_stat = CharacterStat.create(
          character_instance_id: character_instance.id,
          stat_id: stat.id,
          base_value: level.to_i
        )
        created_stats << char_stat
      end
    end

    created_stats
  end

  # Initialize stats for a character with default values (min_stat_value)
  # Used when no allocations provided or for auto-setup
  def self.initialize_default_stats(character_instance, stat_blocks: nil)
    stat_blocks ||= StatBlock.where(is_active: true).all
    created_stats = []

    stat_blocks.each do |stat_block|
      stat_block.stats.each do |stat|
        # Check if stat already exists for this character
        existing = CharacterStat.first(
          character_instance_id: character_instance.id,
          stat_id: stat.id
        )
        next if existing

        char_stat = CharacterStat.create(
          character_instance_id: character_instance.id,
          stat_id: stat.id,
          base_value: stat_block.min_stat_value
        )
        created_stats << char_stat
      end
    end

    created_stats
  end

  # Parse form data into allocation hash
  # Form data comes as: stat_allocations[block_id][stat_id] = level
  def self.parse_form_allocations(params)
    allocations = {}

    return allocations unless params['stat_allocations'].is_a?(Hash)

    params['stat_allocations'].each do |block_id, stats|
      next unless stats.is_a?(Hash)

      allocations[block_id.to_i] = {}
      stats.each do |stat_id, level|
        allocations[block_id.to_i][stat_id.to_i] = level.to_i
      end
    end

    allocations
  end

  # Validate all allocations across multiple stat blocks
  # @return [Hash] { valid: bool, errors: { block_id => [errors], ... } }
  def self.validate_all_allocations(allocations)
    all_errors = {}
    all_valid = true

    allocations.each do |stat_block_id, stat_allocations|
      stat_block = StatBlock[stat_block_id.to_i]
      next unless stat_block

      validation = stat_block.validate_allocation(stat_allocations)
      unless validation[:valid]
        all_valid = false
        all_errors[stat_block_id] = validation[:errors]
      end
    end

    { valid: all_valid, errors: all_errors }
  end

  # Get current stat values for a character instance
  # Returns hash of { stat_id => current_value }
  def self.get_character_stat_values(character_instance)
    values = {}

    character_instance.character_stats.each do |char_stat|
      values[char_stat.stat_id] = char_stat.current_value
    end

    values
  end

  # Get stat value by name or abbreviation for a character
  # @return [Integer, nil] The stat value or nil if not found
  def self.get_stat_value(character_instance, stat_identifier)
    identifier = stat_identifier.to_s.strip.downcase

    character_instance.character_stats.each do |char_stat|
      stat = char_stat.stat
      next unless stat

      if stat.name.downcase == identifier || stat.abbreviation&.downcase == identifier
        return char_stat.current_value
      end
    end

    nil
  end

  # Get multiple stat values by name/abbreviation
  # @return [Array<Hash>] Array of { name:, abbreviation:, value:, stat: }
  def self.get_stat_values(character_instance, stat_identifiers)
    results = []
    identifiers = stat_identifiers.map { |s| s.to_s.strip.downcase }

    character_instance.character_stats.each do |char_stat|
      stat = char_stat.stat
      next unless stat

      name_match = identifiers.include?(stat.name.downcase)
      abbrev_match = stat.abbreviation && identifiers.include?(stat.abbreviation.downcase)

      if name_match || abbrev_match
        results << {
          name: stat.name,
          abbreviation: stat.abbreviation,
          value: char_stat.current_value,
          stat: stat,
          category: stat.stat_category
        }
      end
    end

    results
  end

  # Calculate roll modifier for a character based on stat names
  # @param character_instance [CharacterInstance] The character instance
  # @param stat_names [Array<String>] Stat names or abbreviations to use
  # @return [Hash] { success: bool, modifier: Float, stats_used: Array, stat_block_type: String, error: String }
  def self.calculate_roll_modifier(character_instance, stat_names)
    # Auto-initialize stats if character has none yet
    if character_instance.character_stats.empty?
      initialize_default_stats(character_instance)
      character_instance.reload
      if character_instance.character_stats.empty?
        return error("No stat blocks are configured. Contact an admin.")
      end
    end

    # Look up the requested stats
    stat_values = get_stat_values(character_instance, stat_names)

    # Check if all requested stats were found
    found_identifiers = stat_values.map { |s| [s[:name].downcase, s[:abbreviation]&.downcase] }.flatten.compact
    missing = stat_names.map(&:downcase) - found_identifiers

    if missing.any?
      return error("Unknown stats: #{missing.join(', ')}. Use stat abbreviations like STR, DEX, etc.")
    end

    # Calculate the modifier using averaging rules
    modifier = calculate_modifier_from_values(stat_values)

    # Determine stat block type based on category mix
    categories = stat_values.map { |s| s[:category] }.uniq
    stat_block_type = categories.length > 1 ? 'paired' : 'single'

    success(
      'Modifier calculated',
      data: {
        modifier: modifier,
        stats_used: stat_values.map { |s| { name: s[:name], abbreviation: s[:abbreviation], value: s[:value] } },
        stat_block_type: stat_block_type
      }
    )
  end

  # Internal method to calculate modifier from stat values array
  # Single-type: average + 0.5 per extra stat
  # Double-type: average each category + 0.25 per extra
  def self.calculate_modifier_from_values(stat_values)
    return 0.0 if stat_values.empty?
    return stat_values.first[:value].to_f if stat_values.length == 1

    # Group by category (primary vs secondary)
    by_category = stat_values.group_by { |s| s[:category] }

    # Check if we have a mix of categories (double-type scenario)
    if by_category.keys.length > 1
      # Double-type: average each category, then sum with bonuses
      total = 0.0
      by_category.each do |_category, stats|
        avg = stats.sum { |s| s[:value] } / stats.length.to_f
        bonus = 0.25 * [stats.length - 1, 0].max
        total += avg + bonus
      end
      total
    else
      # Single-type: simple average + 0.5 per extra
      avg = stat_values.sum { |s| s[:value] } / stat_values.length.to_f
      bonus = 0.5 * (stat_values.length - 1)
      avg + bonus
    end
  end
end
