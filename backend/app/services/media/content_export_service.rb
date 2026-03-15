# frozen_string_literal: true

# ContentExportService handles exporting character and property data to JSON format.
# Collects all related data (descriptions, items, patterns, outfits) for portable export.
class ContentExportService
  EXPORT_VERSION = '1.0.0'
  ALLOWED_IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .webp].freeze

  class << self
    # Export a character's content (descriptions, items with patterns, outfits)
    # @param character [Character] The character to export
    # @return [Hash] { json: Hash, images: Array<{original_url:, filename:}> }
    def export_character(character)
      register_image, images = build_image_registrar

      # Get the primary instance for items/outfits
      instance = character.primary_instance

      json_data = {
        version: EXPORT_VERSION,
        export_type: 'character',
        exported_at: Time.now.iso8601,
        character: export_character_base(character, register_image),
        descriptions: export_descriptions(character, register_image),
        items: instance ? export_items(instance, register_image) : [],
        outfits: instance ? export_outfits(instance, register_image) : []
      }

      { json: json_data, images: images }
    end

    # Export a room/property blueprint
    # @param room [Room] The room to export
    # @return [Hash] { json: Hash, images: Array<{original_url:, filename:}> }
    def export_property(room)
      register_image, images = build_image_registrar

      json_data = {
        version: EXPORT_VERSION,
        export_type: 'property',
        exported_at: Time.now.iso8601,
        room: export_room_base(room, register_image),
        places: export_places(room, register_image),
        decorations: export_decorations(room, register_image),
        room_features: export_room_features(room),
        room_hexes: export_room_hexes(room)
      }

      { json: json_data, images: images }
    end

    private

    # Build an image registrar lambda and its backing array.
    # @return [Array(Proc, Array)] [register_image, images]
    def build_image_registrar
      images = []
      counter = 0
      registrar = lambda do |url, prefix|
        return nil if url.nil? || url.to_s.empty?

        ext = normalized_image_extension(url)
        counter += 1
        filename = "#{prefix}_#{counter}#{ext}"
        images << { original_url: url, filename: filename }
        "images/#{filename}"
      end
      [registrar, images]
    end

    # ========================================
    # Character Export Helpers
    # ========================================

    def export_character_base(character, register_image)
      {
        forename: character.forename,
        surname: character.surname,
        nickname: character.nickname,
        short_desc: character.short_desc,
        picture_url: register_image.call(character.picture_url, 'profile'),
        handle_display: character.handle_display,
        speech_color: character.speech_color,
        voice_type: character.voice_type,
        voice_pitch: character.voice_pitch,
        voice_speed: character.voice_speed,
        height_cm: character.height_cm
      }
    end

    def export_descriptions(character, register_image)
      character.default_descriptions_dataset.eager(:body_position, :body_positions).order(:display_order, :id).map do |desc|
        positions = desc.respond_to?(:all_positions) ? desc.all_positions : [desc.body_position].compact

        {
          body_position: positions.first&.label,
          body_positions: positions.map(&:label),
          body_region: positions.first&.region,
          description_type: desc.description_type || 'natural',
          content: desc.content,
          image_url: register_image.call(desc.image_url, 'desc'),
          suffix: desc.suffix || 'period',
          prefix: desc.prefix || 'none',
          concealed_by_clothing: desc.concealed_by_clothing || false,
          display_order: desc.display_order || 0,
          active: desc.active != false
        }
      end
    end

    def export_items(instance, register_image)
      instance.objects_dataset.eager(:pattern).map do |item|
        next unless item.pattern  # Skip items without patterns

        {
          name: item.name,
          description: item.description,
          image_url: register_image.call(item.image_url, 'item'),
          thumbnail_url: register_image.call(item.thumbnail_url, 'item_thumb'),
          quantity: item.quantity || 1,
          condition: item.condition || 'good',
          equipped: item.equipped || false,
          equipment_slot: item.equipment_slot,
          worn: item.worn || false,
          worn_layer: item.worn_layer,
          held: item.held || false,
          stored: item.stored || false,
          concealed: item.concealed || false,
          zipped: item.zipped || false,
          torn: item.torn || 0,
          display_order: item.display_order || 0,
          pattern: export_pattern(item.pattern, register_image)
        }
      end.compact
    end

    def export_pattern(pattern, register_image)
      return nil unless pattern

      {
        description: pattern.description,
        # Get UnifiedObjectType data
        name: pattern.name,
        category: pattern.category,
        subcategory: pattern.subcategory,
        layer: pattern.layer,
        covered_positions: pattern.covered_positions,
        zippable_positions: pattern.zippable_positions,
        # Pattern-specific fields
        price: pattern.price,
        image_url: register_image.call(pattern.image_url, 'pattern'),
        desc_desc: pattern.desc_desc,
        # Consumable fields
        consume_type: pattern.consume_type,
        consume_time: pattern.respond_to?(:consume_time) ? pattern.consume_time : nil,
        taste: pattern.taste,
        effect: pattern.effect,
        # Weapon fields
        is_melee: pattern.is_melee,
        is_ranged: pattern.is_ranged,
        weapon_range: pattern.weapon_range,
        attack_speed: pattern.attack_speed,
        damage_dice: pattern.respond_to?(:damage_dice) ? pattern.damage_dice : nil,
        damage_type: pattern.damage_type,
        # Year restrictions
        min_year: pattern.min_year,
        max_year: pattern.max_year
      }
    end

    def export_outfits(instance, register_image)
      instance.outfits_dataset.eager(outfit_items: :pattern).map do |outfit|
        {
          name: outfit.name,
          items: outfit.outfit_items.map do |oi|
            next unless oi.pattern

            {
              pattern_description: oi.pattern.description,
              display_order: oi.display_order || 0,
              pattern: export_pattern(oi.pattern, register_image)
            }
          end.compact
        }
      end
    end

    # ========================================
    # Property Export Helpers
    # ========================================

    def export_room_base(room, register_image)
      {
        name: room.name,
        room_type: room.room_type,
        short_description: room.short_description,
        long_description: room.long_description,
        default_background_url: register_image.call(room.default_background_url, 'room_bg'),
        curtains: room.curtains || false,
        is_outdoor: room.is_outdoor || false,
        weather_visible: room.weather_visible || false,
        is_vault: room.is_vault || false,
        safe_room: room.safe_room || false,
        private_mode: room.private_mode || false,
        seasonal_descriptions: export_seasonal_with_images(room.seasonal_descriptions, register_image, 'seasonal_desc'),
        seasonal_backgrounds: export_seasonal_with_images(room.seasonal_backgrounds, register_image, 'seasonal_bg'),
        time_descriptions: room.time_descriptions,
        weather_descriptions: room.weather_descriptions,
        has_battle_map: room.has_battle_map || false,
        battle_map_config: room.parsed_battle_map_config,
        battle_map_image_url: register_image.call(room.battle_map_image_url, 'battle_map'),
        # Room bounds
        min_x: room.min_x,
        max_x: room.max_x,
        min_y: room.min_y,
        max_y: room.max_y,
        min_z: room.min_z,
        max_z: room.max_z
      }
    end

    def export_seasonal_with_images(seasonal_data, register_image, prefix)
      return nil if seasonal_data.nil?

      # Handle both Hash and JSON string formats
      seasonal_hash = if seasonal_data.is_a?(String)
                        begin
                          JSON.parse(seasonal_data)
                        rescue JSON::ParserError
                          return nil
                        end
                      else
                        seasonal_data
                      end

      return nil unless seasonal_hash.is_a?(Hash) && seasonal_hash.any?

      # Check if values are URLs (backgrounds) or text (descriptions)
      seasonal_hash.transform_values do |value|
        if value.to_s.start_with?('/') || value.to_s.start_with?('http')
          register_image.call(value, prefix)
        else
          value
        end
      end
    end

    def export_places(room, register_image)
      room.places_dataset.order(:id).map do |place|
        {
          name: place.name,
          description: place.description,
          capacity: place.capacity,
          x: place.x,
          y: place.y,
          z: place.z,
          is_furniture: place.is_furniture || false,
          invisible: place.invisible || false,
          image_url: register_image.call(place.image_url, 'place'),
          default_sit_action: place.default_sit_action
        }
      end
    end

    def export_decorations(room, register_image)
      room.decorations_dataset.order(:display_order, :id).map do |dec|
        {
          name: dec.name,
          description: dec.description,
          image_url: register_image.call(dec.image_url, 'decoration'),
          display_order: dec.display_order || 0
        }
      end
    rescue StandardError => e
      warn "[ContentExportService] Failed to export decorations for room #{room.id}: #{e.message}"
      []
    end

    def export_room_features(room)
      room.room_features_dataset.order(:id).map do |feature|
        {
          name: feature.name,
          feature_type: feature.feature_type,
          description: feature.description,
          x: feature.x,
          y: feature.y,
          z: feature.z,
          width: feature.width,
          height: feature.height,
          orientation: feature.orientation,
          open_state: feature.open_state,
          transparency_state: feature.transparency_state,
          visibility_state: feature.visibility_state,
          allows_sight: feature.allows_sight,
          allows_movement: feature.allows_movement,
          has_curtains: feature.has_curtains,
          curtain_state: feature.curtain_state,
          has_lock: feature.has_lock,
          sight_reduction: feature.sight_reduction
        }
      end
    rescue StandardError => e
      warn "[ContentExportService] Failed to export room features for room #{room.id}: #{e.message}"
      []
    end

    def export_room_hexes(room)
      room.room_hexes_dataset.order(:hex_y, :hex_x).map do |hex|
        {
          hex_x: hex.hex_x,
          hex_y: hex.hex_y,
          hex_type: hex.hex_type,
          surface_type: hex.surface_type,
          traversable: hex.traversable,
          danger_level: hex.danger_level,
          hazard_type: hex.hazard_type,
          damage_potential: hex.damage_potential,
          water_type: hex.water_type,
          cover_value: hex.cover_value,
          cover_object: hex.cover_object,
          elevation_level: hex.elevation_level,
          potential_trigger: hex.potential_trigger,
          explosion_trigger: hex.explosion_trigger
        }
      end
    rescue StandardError => e
      warn "[ContentExportService] Failed to export room hexes for room #{room.id}: #{e.message}"
      []
    end

    def normalized_image_extension(url)
      base_path = url.to_s.split('?').first.to_s.split('#').first.to_s
      ext = File.extname(base_path).downcase
      return ext if ALLOWED_IMAGE_EXTENSIONS.include?(ext)

      '.jpg'
    end
  end
end
