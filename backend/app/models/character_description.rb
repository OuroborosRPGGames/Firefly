# frozen_string_literal: true

# CharacterDescription stores session-specific descriptions on CharacterInstance.
# There are two types of descriptions:
# 1. Profile descriptions (via description_type_id) - personality, background, etc.
# 2. Body position descriptions (via body_position_id/body_positions) - physical appearance
#
# For body position descriptions, supports aesthetic types:
# - natural: Default body part descriptions
# - tattoo: Tattoos (can span multiple body positions)
# - makeup: Face makeup (restricted to face positions)
# - hairstyle: Hair styling (restricted to scalp)
class CharacterDescription < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  include DescriptionFormatting

  # Reuse constants from CharacterDefaultDescription
  AESTHETIC_TYPES = CharacterDefaultDescription::DESCRIPTION_TYPES
  MAKEUP_POSITIONS = CharacterDefaultDescription::MAKEUP_POSITIONS
  HAIRSTYLE_POSITIONS = CharacterDefaultDescription::HAIRSTYLE_POSITIONS

  many_to_one :character_instance
  many_to_one :description_type  # For profile descriptions (personality, background, etc.)

  # Legacy single position (for backwards compatibility)
  many_to_one :body_position

  # New multi-position support via join table
  many_to_many :body_positions,
               join_table: :character_instance_description_positions,
               left_key: :character_description_id,
               right_key: :body_position_id

  # Set default values before validation
  def before_validation
    super
    self.aesthetic_type ||= 'natural' if body_position_id || body_positions.any?
    # Set default suffix and prefix
    self.suffix ||= 'period' if respond_to?(:suffix=)
    self.prefix ||= 'none' if respond_to?(:prefix=)
  end

  def validate
    super
    validates_presence [:character_instance_id, :content]

    # Must have either description_type_id OR body position(s)
    if description_type_id.nil? && body_position_id.nil? && body_positions.empty?
      errors.add(:base, 'Must have either description_type_id or body_position(s)')
    end

    # Validate aesthetic_type if it's a body position description
    if body_position_id || body_positions.any?
      validates_includes AESTHETIC_TYPES, :aesthetic_type, message: 'must be a valid aesthetic type'
      validate_positions_for_aesthetic_type if body_positions.any?
    end

    # Prevent duplicate natural/hairstyle/makeup descriptions per body position
    # (tattoos can have multiples on the same position)
    validate_no_duplicate_body_description if new? && body_position_id && aesthetic_type != 'tattoo'

    # Validate suffix type
    if respond_to?(:suffix) && suffix
      validates_includes SUFFIX_TYPES, :suffix, message: 'must be a valid suffix type'
    end

    # Validate prefix type
    if respond_to?(:prefix) && prefix
      validates_includes PREFIX_TYPES, :prefix, message: 'must be a valid prefix type'
    end
  end

  def type_name
    description_type&.name
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
  def visible?(clothing_coverage = [])
    return true if all_positions.empty?

    all_positions.any? do |pos|
      !clothing_coverage.include?(pos.id)
    end
  end

  # Aesthetic type helpers (for body position descriptions)
  def natural?
    aesthetic_type == 'natural'
  end

  def tattoo?
    aesthetic_type == 'tattoo'
  end

  def makeup?
    aesthetic_type == 'makeup'
  end

  def hairstyle?
    aesthetic_type == 'hairstyle'
  end

  # Check if this is a body position description (vs profile description)
  def body_description?
    body_position_id || body_positions.any?
  end

  # Check if this is a profile description (personality, background, etc.)
  def profile_description?
    !description_type_id.nil?
  end

  # suffix_text and prefix_text provided by DescriptionFormatting

  # Dataset methods for querying
  dataset_module do
    def ordered
      order(:display_order, :id)
    end

    def active_only
      where(active: true)
    end

    def by_body_position
      exclude(body_position_id: nil)
    end

    def by_description_type
      exclude(description_type_id: nil)
    end

    def by_aesthetic_type(type)
      where(aesthetic_type: type)
    end

    def tattoos
      by_aesthetic_type('tattoo')
    end

    def makeup
      by_aesthetic_type('makeup')
    end

    def hairstyles
      by_aesthetic_type('hairstyle')
    end

    def natural
      by_aesthetic_type('natural')
    end
  end

  private

  def humanize_label(label)
    return nil unless label

    label.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')
  end

  def validate_positions_for_aesthetic_type
    valid_ids = CharacterDefaultDescription.valid_position_ids_for_type(aesthetic_type)
    invalid_positions = body_positions.reject { |bp| valid_ids.include?(bp.id) }

    return if invalid_positions.empty?

    invalid_labels = invalid_positions.map { |bp| humanize_label(bp.label) }.join(', ')

    case aesthetic_type
    when 'makeup'
      errors.add(:body_positions, "for makeup must be face positions. Invalid: #{invalid_labels}")
    when 'hairstyle'
      errors.add(:body_positions, "for hairstyle must be scalp only. Invalid: #{invalid_labels}")
    end
  end

  def validate_no_duplicate_body_description
    existing = self.class.where(
      character_instance_id: character_instance_id,
      body_position_id: body_position_id,
      aesthetic_type: aesthetic_type
    ).first
    return unless existing

    errors.add(:body_position_id, "already has a #{aesthetic_type} description for this position")
  end
end
