# frozen_string_literal: true

# CharacterDefaultDescription stores persistent descriptions on the Character model.
# These are copied to CharacterDescription (on CharacterInstance) when the character logs in.
# This allows descriptions to persist across sessions while allowing session-specific modifications.
#
# Supports multiple description types:
# - natural: Default body part descriptions
# - tattoo: Tattoos (can span multiple body positions)
# - makeup: Face makeup (restricted to face positions)
# - hairstyle: Hair styling (restricted to scalp)
class CharacterDefaultDescription < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  include DescriptionFormatting

  DESCRIPTION_TYPES = %w[natural tattoo makeup hairstyle].freeze

  # Face positions for makeup (by label)
  MAKEUP_POSITIONS = %w[forehead eyes nose cheeks chin mouth].freeze

  # Scalp position for hairstyle (by label)
  HAIRSTYLE_POSITIONS = %w[scalp].freeze

  many_to_one :character

  # Legacy single position (for backwards compatibility)
  many_to_one :body_position

  # New multi-position support via join table
  many_to_many :body_positions,
               join_table: :character_description_positions,
               left_key: :character_default_description_id,
               right_key: :body_position_id

  # Set default values before validation
  def before_validation
    super
    self.description_type ||= 'natural'
    self.suffix ||= 'period'
    self.prefix ||= 'none'
  end

  def validate
    super
    validates_presence [:character_id, :content]
    validates_includes DESCRIPTION_TYPES, :description_type, message: 'must be a valid description type'
    validates_includes SUFFIX_TYPES, :suffix, message: 'must be a valid suffix type'
    validates_includes PREFIX_TYPES, :prefix, message: 'must be a valid prefix type'

    # Validate positions based on type
    validate_positions_for_type if body_positions.any?
  end

  # Get the body region (head, torso, arms, hands, legs, feet)
  # Returns first position's region for multi-position descriptions
  def region
    all_positions.first&.region
  end

  # Get all regions covered by this description
  def regions
    all_positions.map(&:region).uniq
  end

  # Get all body positions (from join table or legacy column)
  def all_positions
    positions = body_positions.to_a
    positions << body_position if body_position && positions.empty?
    positions.compact.uniq
  end

  # Get all position labels
  def position_labels
    all_positions.map { |bp| humanize_label(bp.label) }
  end

  # Get the human-readable position label (for single position display)
  def position_label
    position_labels.first
  end

  # Check if this description should be hidden based on clothing
  def hidden_by_clothing?
    concealed_by_clothing && active
  end

  # Check if any position is visible (not covered by clothing)
  # Description is visible if at least one position is uncovered
  def visible?(clothing_coverage = [])
    return true if all_positions.empty?

    all_positions.any? do |pos|
      !clothing_coverage.include?(pos.id)
    end
  end

  # Type helpers
  def natural?
    description_type == 'natural'
  end

  def tattoo?
    description_type == 'tattoo'
  end

  def makeup?
    description_type == 'makeup'
  end

  def hairstyle?
    description_type == 'hairstyle'
  end

  # Compatibility aliases for CharacterDisplayService (which uses CharacterDescription interface)
  # CharacterDescription uses aesthetic_type, CharacterDefaultDescription uses description_type
  def aesthetic_type
    description_type
  end

  # suffix_text and prefix_text provided by DescriptionFormatting

  # Get valid position IDs for a given description type
  def self.valid_position_ids_for_type(type)
    case type
    when 'makeup'
      BodyPosition.where(label: MAKEUP_POSITIONS).select_map(:id)
    when 'hairstyle'
      BodyPosition.where(label: HAIRSTYLE_POSITIONS).select_map(:id)
    else
      # tattoo and natural can use any position
      BodyPosition.select_map(:id)
    end
  end

  # Get valid positions as objects for a given description type
  def self.valid_positions_for_type(type)
    case type
    when 'makeup'
      BodyPosition.where(label: MAKEUP_POSITIONS).order(:id).all
    when 'hairstyle'
      BodyPosition.where(label: HAIRSTYLE_POSITIONS).order(:id).all
    else
      BodyPosition.order(:region, :label).all
    end
  end

  # Dataset method to get descriptions ordered by display_order
  dataset_module do
    def ordered
      order(:display_order, :id)
    end

    def active_only
      where(active: true)
    end

    def by_type(type)
      where(description_type: type)
    end

    def by_region(region)
      eager(:body_positions).all.select { |d| d.regions.include?(region) }
    end

    def tattoos
      by_type('tattoo')
    end

    def makeup
      by_type('makeup')
    end

    def hairstyles
      by_type('hairstyle')
    end

    def natural
      by_type('natural')
    end
  end

  private

  def humanize_label(label)
    return nil unless label

    label.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')
  end

  def validate_positions_for_type
    valid_ids = self.class.valid_position_ids_for_type(description_type)
    invalid_positions = body_positions.reject { |bp| valid_ids.include?(bp.id) }

    return if invalid_positions.empty?

    invalid_labels = invalid_positions.map { |bp| humanize_label(bp.label) }.join(', ')

    case description_type
    when 'makeup'
      errors.add(:body_positions, "for makeup must be face positions (#{MAKEUP_POSITIONS.join(', ')}). Invalid: #{invalid_labels}")
    when 'hairstyle'
      errors.add(:body_positions, "for hairstyle must be scalp only. Invalid: #{invalid_labels}")
    end
  end
end
