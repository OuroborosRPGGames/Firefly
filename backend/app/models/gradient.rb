# frozen_string_literal: true

# Gradient model for storing reusable color gradients
# Used by the description editor for applying gradient text effects
class Gradient < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :user

  # Override setters to ensure arrays are properly wrapped for PostgreSQL
  def colors=(value)
    if value.is_a?(Array) && !value.is_a?(Sequel::Postgres::PGArray)
      super(Sequel.pg_array(value))
    else
      super(value)
    end
  end

  def easings=(value)
    if value.is_a?(Array) && !value.is_a?(Sequel::Postgres::PGArray)
      super(Sequel.pg_array(value, :integer))
    else
      super(value)
    end
  end

  def validate
    super
    validates_presence [:name, :colors]
    validates_max_length 100, :name
    validates_max_length 50, :interpolation if interpolation

    # Validate colors is an array with at least 2 hex colors
    if colors
      errors.add(:colors, 'must have at least 2 colors') if colors.length < 2
      errors.add(:colors, 'cannot have more than 10 colors') if colors.length > 10

      colors.each_with_index do |color, i|
        unless color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{6}\z/)
          errors.add(:colors, "color #{i + 1} must be a valid hex color (e.g., #FF0000)")
        end
      end
    end

    # Validate easings are integers in valid range
    if easings&.any?
      easings.each_with_index do |easing, i|
        unless easing.is_a?(Integer) && easing >= 50 && easing <= 200
          errors.add(:easings, "easing #{i + 1} must be an integer between 50 and 200")
        end
      end
    end
  end

  # Record usage of this gradient
  def record_use!
    update(
      use_count: use_count + 1,
      last_used_at: Time.now
    )
  end

  # Serialize for API response
  def to_api_hash
    {
      id: id,
      name: name,
      colors: colors || [],
      easings: easings || [],
      interpolation: interpolation || 'ciede2000',
      use_count: use_count,
      last_used_at: last_used_at&.iso8601,
      created_at: created_at&.iso8601
    }
  end

  # Class methods for finding gradients
  class << self
    # Get recent gradients for a user
    def recent_for_user(user_id, limit: 10)
      where(user_id: user_id)
        .exclude(last_used_at: nil)
        .order(Sequel.desc(:last_used_at))
        .limit(limit)
        .all
    end

    # Get all gradients for a user
    def for_user(user_id)
      where(user_id: user_id)
        .order(:name)
        .all
    end

    # Get global/shared gradients (no user)
    def shared
      where(user_id: nil)
        .order(:name)
        .all
    end
  end
end
