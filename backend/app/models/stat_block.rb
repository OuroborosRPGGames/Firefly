# frozen_string_literal: true

# StatBlock belongs to a Universe and defines a stat system.
# Can be 'single' (pool of stats) or 'paired' (stats + skills).
# A universe can have multiple stat blocks for different purposes (e.g., vehicle operation).
class StatBlock < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  one_to_many :stats

  BLOCK_TYPES = %w[single paired].freeze

  # Cost formulas determine how much each stat level costs
  # doubling_every_other: 1,1,2,2,3,3,4,4,5,5 (for single-type, max 10)
  # linear_increasing: 1,2,3,4,5 (for paired-type, max 5)
  COST_FORMULAS = %w[doubling_every_other linear_increasing].freeze

  def validate
    super
    validates_presence [:universe_id, :name, :block_type]
    validates_max_length 100, :name
    validates_unique [:universe_id, :name]
    validates_includes BLOCK_TYPES, :block_type
    validates_includes COST_FORMULAS, :cost_formula if cost_formula
  end

  def before_save
    super
    self.block_type ||= 'single'
    self.is_default ||= false
    self.total_points ||= single? ? 50 : 25
    self.secondary_points ||= 25
    self.min_stat_value ||= 1
    self.max_stat_value ||= single? ? 10 : 5
    self.cost_formula ||= single? ? 'doubling_every_other' : 'linear_increasing'
    self.primary_label ||= 'Stats'
    self.secondary_label ||= 'Skills'
  end

  def single?
    block_type == 'single'
  end

  def paired?
    block_type == 'paired'
  end

  def primary_stats
    stats_dataset.where(stat_category: 'primary').order(:display_order)
  end

  def secondary_stats
    stats_dataset.where(stat_category: 'secondary').order(:display_order)
  end

  def skills
    stats_dataset.where(stat_category: 'skill').order(:display_order)
  end

  def self.default_for(universe)
    first(universe_id: universe.id, is_default: true) || first(universe_id: universe.id)
  end

  # Calculate points needed to go from (level-1) to level
  # For doubling_every_other: 1,1,2,2,3,3,4,4,5,5
  # For linear_increasing: 1,2,3,4,5
  def point_cost_for_level(level)
    return 0 if level <= 0

    case cost_formula
    when 'doubling_every_other'
      # Level 1-2: 1pt each, Level 3-4: 2pt each, etc.
      ((level + 1) / 2.0).ceil
    when 'linear_increasing'
      # Level 1: 1pt, Level 2: 2pt, Level 3: 3pt, etc.
      level
    else
      level
    end
  end

  # Calculate total points needed to reach a specific level from 0
  def total_cost_for_level(level)
    return 0 if level <= 0

    (1..level).sum { |l| point_cost_for_level(l) }
  end

  # Calculate total points for a stat allocation hash
  # allocations: { stat_id => level, stat_id => level, ... }
  def calculate_allocation_cost(allocations, category: nil)
    target_stats = case category
                   when 'primary' then primary_stats.all
                   when 'secondary' then secondary_stats.all
                   else stats
                   end

    stat_ids = target_stats.map(&:id)
    allocations.sum do |stat_id, level|
      next 0 unless stat_ids.include?(stat_id.to_i)

      total_cost_for_level(level.to_i)
    end
  end

  # Validate that an allocation is within point limits
  # Returns { valid: true/false, errors: [], primary_spent: N, secondary_spent: N }
  def validate_allocation(allocations)
    errors = []
    allocations = allocations.transform_keys(&:to_i).transform_values(&:to_i)

    if paired?
      primary_spent = calculate_allocation_cost(allocations, category: 'primary')
      secondary_spent = calculate_allocation_cost(allocations, category: 'secondary')

      errors << "Primary stats exceed #{total_points} points (used #{primary_spent})" if primary_spent > total_points
      errors << "Secondary stats exceed #{secondary_points} points (used #{secondary_spent})" if secondary_spent > secondary_points

      # Check individual stat bounds
      all_stats = (primary_stats.all + secondary_stats.all)
      all_stats.each do |stat|
        level = allocations[stat.id] || 0
        errors << "#{stat.name} below minimum (#{min_stat_value})" if level < min_stat_value
        errors << "#{stat.name} exceeds maximum (#{max_stat_value})" if level > max_stat_value
      end

      {
        valid: errors.empty?,
        errors: errors,
        primary_spent: primary_spent,
        secondary_spent: secondary_spent,
        primary_remaining: total_points - primary_spent,
        secondary_remaining: secondary_points - secondary_spent
      }
    else
      total_spent = calculate_allocation_cost(allocations)
      errors << "Stats exceed #{total_points} points (used #{total_spent})" if total_spent > total_points

      # Check individual stat bounds
      stats.each do |stat|
        level = allocations[stat.id] || 0
        errors << "#{stat.name} below minimum (#{min_stat_value})" if level < min_stat_value
        errors << "#{stat.name} exceeds maximum (#{max_stat_value})" if level > max_stat_value
      end

      {
        valid: errors.empty?,
        errors: errors,
        total_spent: total_spent,
        total_remaining: total_points - total_spent
      }
    end
  end

  # Return configuration as JSON for frontend
  def to_allocation_config
    {
      id: id,
      name: name,
      block_type: block_type,
      total_points: total_points,
      secondary_points: secondary_points,
      min_stat_value: min_stat_value,
      max_stat_value: max_stat_value,
      cost_formula: cost_formula,
      primary_label: primary_label,
      secondary_label: secondary_label,
      stats: stats.map do |stat|
        {
          id: stat.id,
          name: stat.name,
          abbreviation: stat.abbreviation,
          category: stat.stat_category,
          description: stat.description,
          display_order: stat.display_order
        }
      end
    }
  end
end
