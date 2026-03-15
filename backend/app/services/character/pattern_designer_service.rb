# frozen_string_literal: true

# Service for creating and managing item patterns
# Handles clothing, jewelry, weapons, and consumables
class PatternDesignerService
  class << self
    def create(params)
      pattern_params = extract_pattern_params(params)

      # Get the unified object type
      type = UnifiedObjectType[pattern_params[:unified_object_type_id]]
      return { success: false, error: 'Invalid type selected' } unless type

      # Create the pattern
      pattern = Pattern.new(pattern_params)

      if pattern.valid?
        pattern.save
        { success: true, pattern: pattern }
      else
        { success: false, error: pattern.errors.full_messages.join(', ') }
      end
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    rescue StandardError => e
      warn "[PatternDesignerService] create failed: #{e.message}"
      { success: false, error: "Failed to create pattern: #{e.message}" }
    end

    def update(pattern, params)
      pattern_params = extract_pattern_params(params)

      pattern.update(pattern_params)
      { success: true, pattern: pattern }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    rescue StandardError => e
      warn "[PatternDesignerService] update failed: #{e.message}"
      { success: false, error: "Failed to update pattern: #{e.message}" }
    end

    def delete(pattern)
      # Check if any items reference this pattern
      if pattern.objects.any?
        return { success: false, error: 'Cannot delete pattern with existing items' }
      end

      pattern.destroy
      { success: true }
    rescue StandardError => e
      warn "[PatternDesignerService] delete failed: #{e.message}"
      { success: false, error: "Failed to delete pattern: #{e.message}" }
    end

    # Create a pattern for a player (with restrictions)
    def create_player_pattern(user, params)
      pattern_params = extract_pattern_params(params)

      # Set created_by to the user
      pattern_params[:created_by] = user.id

      # Call regular create
      create(pattern_params)
    end

    private

    def extract_pattern_params(params)
      pattern = params['pattern'] || params

      {
        unified_object_type_id: pattern['unified_object_type_id']&.to_i,
        description: pattern['description']&.strip,
        desc_desc:   pattern['desc_desc'],
        image_url:   pattern['image_url'],
        price:       pattern['price'].to_s.empty? ? nil : pattern['price'].to_f,

        # Clothing-specific
        sheer:     pattern['sheer'] == 'true' || pattern['sheer'] == '1',
        container: pattern['container'] == 'true' || pattern['container'] == '1',
        extra_covered_1:   presence(pattern['extra_covered_1']),
        extra_covered_2:   presence(pattern['extra_covered_2']),
        extra_uncovered_1: presence(pattern['extra_uncovered_1']),
        extra_uncovered_2: presence(pattern['extra_uncovered_2']),

        # Jewelry-specific
        metal: pattern['metal'],
        stone: pattern['stone'],

        # Weapon-specific
        weapon_type: presence(pattern['weapon_type']),

        # Consumable-specific
        consume_type: pattern['consume_type'],
        consume_time: pattern['consume_time'].to_s.empty? ? nil : pattern['consume_time'].to_i,
        taste:  pattern['taste'],
        effect: pattern['effect'],

        # Other-specific (dimensions)
        dim_length: to_float_or_nil(pattern['dim_length']),
        dim_width:  to_float_or_nil(pattern['dim_width']),
        dim_height: to_float_or_nil(pattern['dim_height']),
        dim_weight: to_float_or_nil(pattern['dim_weight']),

        # Metadata
        created_by: pattern['created_by']
      }.compact
    end

    def presence(value)
      str = value.to_s.strip
      str.empty? ? nil : str
    end

    def to_float_or_nil(value)
      str = value.to_s.strip
      str.empty? ? nil : str.to_f
    end
  end
end
