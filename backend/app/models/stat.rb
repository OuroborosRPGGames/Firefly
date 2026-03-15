# frozen_string_literal: true

# Stat belongs to a StatBlock and defines an individual stat or skill.
# For paired systems, stats can be linked to parent stats.
class Stat < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :stat_block
  many_to_one :parent_stat, class: :Stat
  one_to_many :child_stats, class: :Stat, key: :parent_stat_id
  one_to_many :character_stats

  CATEGORIES = %w[primary secondary skill derived].freeze

  def validate
    super
    validates_presence [:stat_block_id, :name, :abbreviation]
    validates_max_length 50, :name
    validates_max_length 10, :abbreviation
    validates_unique [:stat_block_id, :name]
    validates_unique [:stat_block_id, :abbreviation]
    validates_includes CATEGORIES, :stat_category if stat_category
  end

  def before_save
    super
    self.stat_category ||= 'primary'
    self.min_value ||= 1
    self.max_value ||= 20
    self.default_value ||= 10
    self.display_order ||= 0
  end

  def skill?
    stat_category == 'skill'
  end

  def derived?
    stat_category == 'derived'
  end

  def has_parent?
    !parent_stat_id.nil?
  end
  alias parent? has_parent?

  # Calculate derived value based on formula
  # @param character_instance [CharacterInstance] the character to calculate for
  # @return [Integer] the calculated value or default_value on error
  def calculate_derived(character_instance)
    return default_value unless derived? && formula && !formula.strip.empty?

    stat_values = build_stat_values(character_instance)
    result = StatFormulaService.evaluate(formula, stat_values)
    result || default_value
  end

  private

  # Build a hash of stat abbreviation => value for formula evaluation
  # @param character_instance [CharacterInstance]
  # @return [Hash<String, Numeric>]
  def build_stat_values(character_instance)
    return {} unless character_instance

    character_instance.character_stats.each_with_object({}) do |cs, hash|
      next unless cs.stat&.abbreviation

      hash[cs.stat.abbreviation.upcase] = cs.current_value
    end
  end
end
