# frozen_string_literal: true

# ContentImportService handles importing character and property data from JSON.
# Matches or creates patterns, descriptions, items, outfits, places, etc.
class ContentImportService
  SUPPORTED_VERSIONS = ['1.0.0'].freeze

  class << self
    # Import character content from JSON data
    # @param character [Character] The character to import to
    # @param json_data [Hash] The parsed JSON export data
    # @param url_mapping [Hash] Mapping of export filenames to uploaded URLs
    # @return [Hash] { success: Boolean, imported: Hash, errors: Array }
    def import_character(character, json_data, url_mapping = {})
      errors = []
      imported = { descriptions: 0, items: 0, outfits: 0, patterns: 0 }

      # Validate version
      unless SUPPORTED_VERSIONS.include?(json_data['version'])
        return { success: false, imported: imported, errors: ["Unsupported export version: #{json_data['version']}"] }
      end

      unless json_data['export_type'] == 'character'
        return { success: false, imported: imported, errors: ['Invalid export type: expected character'] }
      end

      # Get or create the primary instance
      instance = character.primary_instance
      unless instance
        return { success: false, imported: imported, errors: ['Character has no instance to import to'] }
      end

      # Remap image URLs in the data
      remap_urls!(json_data, url_mapping)

      DB.transaction do
        # Import character base data (optional - don't overwrite names)
        if json_data['character']
          import_character_base(character, json_data['character'])
        end

        # Import descriptions
        if json_data['descriptions']
          count, desc_errors = import_descriptions(character, json_data['descriptions'])
          imported[:descriptions] = count
          errors.concat(desc_errors)
        end

        # Import items with patterns
        if json_data['items']
          item_count, pattern_count, item_errors = import_items(instance, json_data['items'])
          imported[:items] = item_count
          imported[:patterns] = pattern_count
          errors.concat(item_errors)
        end

        # Import outfits
        if json_data['outfits']
          count, outfit_errors = import_outfits(instance, json_data['outfits'])
          imported[:outfits] = count
          errors.concat(outfit_errors)
        end
      end

      { success: errors.empty?, imported: imported, errors: errors }
    rescue StandardError => e
      warn "[ContentImportService] import_character failed: #{e.message}"
      { success: false, imported: imported, errors: ["Import failed: #{e.message}"] }
    end

    # Import only descriptions to a character (useful for draft characters without instances)
    # @param character [Character] The character to import descriptions to
    # @param descriptions [Array<Hash>] Array of description data from export
    # @param url_mapping [Hash] Mapping of export filenames to uploaded URLs
    # @return [Hash] { success: Boolean, count: Integer, errors: Array }
    def import_descriptions_to_character(character, descriptions, url_mapping = {})
      return { success: true, count: 0, errors: [] } if descriptions.nil? || descriptions.empty?

      # Remap image URLs in descriptions
      descriptions.each do |desc|
        remap_description_urls!(desc, url_mapping)
      end

      count, errors = import_descriptions(character, descriptions)
      { success: errors.empty?, count: count, errors: errors }
    end

    # Import property blueprint from JSON data
    # @param room [Room] The room to apply the blueprint to
    # @param json_data [Hash] The parsed JSON export data
    # @param url_mapping [Hash] Mapping of export filenames to uploaded URLs
    # @return [Hash] { success: Boolean, imported: Hash, errors: Array }
    def import_property(room, json_data, url_mapping = {}, options = {})
      errors = []
      imported = { room_updated: false, places: 0, decorations: 0, features: 0, hexes: 0 }
      opts = {
        replace_existing: false,
        scale_places: false,
        import_battle_map: true,
        preserve_exits: false
      }.merge(options)

      # Validate version
      unless SUPPORTED_VERSIONS.include?(json_data['version'])
        return { success: false, imported: imported, errors: ["Unsupported export version: #{json_data['version']}"] }
      end

      unless json_data['export_type'] == 'property'
        return { success: false, imported: imported, errors: ['Invalid export type: expected property'] }
      end

      # Remap image URLs in the data
      remap_urls!(json_data, url_mapping)

      DB.transaction do
        if opts[:replace_existing]
          room.places_dataset.delete
          room.decorations_dataset.delete

          if opts[:preserve_exits]
            room.room_features_dataset.where(connected_room_id: nil).delete
          else
            room.room_features_dataset.delete
          end

          room.room_hexes_dataset.delete if opts[:import_battle_map]
        end

        # Update room base data
        if json_data['room']
          import_room_base(room, json_data['room'], opts)
          imported[:room_updated] = true
        end

        # Import places (furniture)
        if json_data['places']
          count, place_errors = import_places(room, json_data['places'], json_data['room'], opts)
          imported[:places] = count
          errors.concat(place_errors)
        end

        # Import decorations
        if json_data['decorations']
          count, dec_errors = import_decorations(room, json_data['decorations'])
          imported[:decorations] = count
          errors.concat(dec_errors)
        end

        # Import room features
        if json_data['room_features']
          count, feature_errors = import_room_features(room, json_data['room_features'], opts)
          imported[:features] = count
          errors.concat(feature_errors)
        end

        # Import room hexes
        if json_data['room_hexes'] && opts[:import_battle_map]
          count, hex_errors = import_room_hexes(room, json_data['room_hexes'])
          imported[:hexes] = count
          errors.concat(hex_errors)
        end
      end

      { success: errors.empty?, imported: imported, errors: errors }
    rescue StandardError => e
      warn "[ContentImportService] import_property failed: #{e.message}"
      { success: false, imported: imported, errors: ["Import failed: #{e.message}"] }
    end

    private

    # ========================================
    # URL Remapping
    # ========================================

    def remap_urls!(data, url_mapping)
      return if url_mapping.empty?

      case data
      when Hash
        data.each do |key, value|
          if value.is_a?(String) && value.start_with?('images/')
            # Extract filename from images/filename.jpg
            filename = value.sub(/\Aimages\//, '').split('?').first.to_s.split('#').first.to_s
            filename = File.basename(filename)
            data[key] = url_mapping[filename] if url_mapping[filename]
          else
            remap_urls!(value, url_mapping)
          end
        end
      when Array
        data.each { |item| remap_urls!(item, url_mapping) }
      end
    end

    # Remap image URLs in a single description hash
    def remap_description_urls!(desc, url_mapping)
      return if url_mapping.empty? || desc['image_url'].nil?

      if desc['image_url'].start_with?('images/')
        filename = desc['image_url'].sub(/\Aimages\//, '').split('?').first.to_s.split('#').first.to_s
        filename = File.basename(filename)
        desc['image_url'] = url_mapping[filename] if url_mapping[filename]
      end
    end

    # ========================================
    # Character Import Helpers
    # ========================================

    def import_character_base(character, char_data)
      # Only update optional fields, don't overwrite names
      updates = {}
      updates[:short_desc] = char_data['short_desc'] if char_data['short_desc']
      updates[:picture_url] = char_data['picture_url'] if char_data['picture_url']
      updates[:handle_display] = char_data['handle_display'] if char_data['handle_display']
      updates[:voice_type] = char_data['voice_type'] if char_data['voice_type']
      updates[:voice_pitch] = char_data['voice_pitch'] if char_data['voice_pitch']
      updates[:voice_speed] = char_data['voice_speed'] if char_data['voice_speed']
      updates[:height_cm] = char_data['height_cm'] if char_data['height_cm']

      character.update(updates) unless updates.empty?
    end

    def import_descriptions(character, descriptions)
      count = 0
      errors = []

      descriptions.each do |desc_data|
        labels = []
        if desc_data['body_positions'].is_a?(Array) && !desc_data['body_positions'].empty?
          labels = desc_data['body_positions']
        elsif desc_data['body_position']
          labels = [desc_data['body_position']]
        end

        labels = labels.map { |label| label.to_s.strip.downcase }.reject(&:empty?).uniq
        if labels.empty?
          errors << 'Description missing body position(s)'
          next
        end

        body_positions = BodyPosition.where(label: labels).all
        missing_labels = labels - body_positions.map(&:label)
        missing_labels.each { |label| errors << "Body position not found: #{label}" }
        next if body_positions.empty?

        desc_type = desc_data['description_type'] || 'natural'
        if defined?(CharacterDefaultDescription::DESCRIPTION_TYPES) &&
           !CharacterDefaultDescription::DESCRIPTION_TYPES.include?(desc_type)
          desc_type = 'natural'
        end
        content = desc_data['content']
        if content.nil? || content.to_s.strip.empty?
          errors << "Description content missing for positions: #{labels.join(', ')}"
          next
        end

        # Natural descriptions are still one-per-primary-position for compatibility.
        existing = if desc_type == 'natural' && body_positions.length == 1
                     CharacterDefaultDescription.first(
                       character_id: character.id,
                       body_position_id: body_positions.first.id
                     )
                   else
                     CharacterDefaultDescription.where(
                       character_id: character.id,
                       description_type: desc_type,
                       content: content
                     ).eager(:body_positions, :body_position).all.find do |candidate|
                       candidate_ids = candidate.respond_to?(:all_positions) ? candidate.all_positions.map(&:id).sort : [candidate.body_position_id].compact.sort
                       candidate_ids == body_positions.map(&:id).sort
                     end
                   end

        if existing
          # Update existing
          existing.update(
            body_position_id: body_positions.first.id,
            content: content,
            image_url: desc_data['image_url'],
            description_type: desc_type,
            suffix: desc_data['suffix'] || desc_data['separator'] || 'period',
            prefix: desc_data['prefix'] || 'none',
            concealed_by_clothing: desc_data['concealed_by_clothing'] || false,
            display_order: desc_data['display_order'] || 0,
            active: desc_data['active'] != false
          )
        else
          # Create new
          existing = CharacterDefaultDescription.create(
            character_id: character.id,
            body_position_id: body_positions.first.id,
            content: content,
            image_url: desc_data['image_url'],
            description_type: desc_type,
            suffix: desc_data['suffix'] || desc_data['separator'] || 'period',
            prefix: desc_data['prefix'] || 'none',
            concealed_by_clothing: desc_data['concealed_by_clothing'] || false,
            display_order: desc_data['display_order'] || 0,
            active: desc_data['active'] != false
          )
        end

        # Keep join table synchronized for multi-position descriptions.
        CharacterDescriptionPosition.where(character_default_description_id: existing.id).delete
        body_positions.each do |bp|
          CharacterDescriptionPosition.create(
            character_default_description_id: existing.id,
            body_position_id: bp.id
          )
        end

        count += 1
      end

      [count, errors]
    end

    def import_items(instance, items)
      item_count = 0
      pattern_count = 0
      errors = []

      items.each do |item_data|
        pattern_data = item_data['pattern']
        next unless pattern_data

        # Find or create pattern
        pattern, created = find_or_create_pattern(pattern_data)
        unless pattern
          errors << "Failed to create pattern for: #{item_data['name']}"
          next
        end
        pattern_count += 1 if created

        # Set image_url on pattern if provided (images now live on patterns, not items)
        pattern_image_url = item_data['image_url'] || pattern_data['image_url']
        if pattern_image_url && !pattern.has_image?
          pattern.update(image_url: pattern_image_url)
        end

        # Create item (no longer storing image_url directly on items)
        Item.create(
          pattern_id: pattern.id,
          character_instance_id: instance.id,
          name: item_data['name'],
          description: item_data['description'],
          quantity: item_data['quantity'] || 1,
          condition: item_data['condition'] || 'good',
          equipped: item_data['equipped'] || false,
          equipment_slot: item_data['equipment_slot'],
          worn: item_data['worn'] || false,
          worn_layer: item_data['worn_layer'],
          held: item_data['held'] || false,
          stored: item_data['stored'] || false,
          concealed: item_data['concealed'] || false,
          zipped: item_data['zipped'] || false,
          torn: item_data['torn'] || 0,
          display_order: item_data['display_order'] || 0,
          is_clothing: pattern.clothing?,
          is_jewelry: pattern.jewelry?,
          is_tattoo: pattern.respond_to?(:tattoo?) ? pattern.tattoo? : false
        )
        item_count += 1
      end

      [item_count, pattern_count, errors]
    end

    def find_or_create_pattern(pattern_data)
      # Try to find existing pattern by description + name + category for better uniqueness
      filter = { description: pattern_data['description'] }
      filter[:unified_object_type_id] = UnifiedObjectType.where(
        name: pattern_data['name'],
        category: pattern_data['category']
      ).select(:id) if pattern_data['name'] && pattern_data['category']
      existing = Pattern.first(filter)
      # Fall back to description-only match if composite lookup misses
      existing ||= Pattern.first(description: pattern_data['description'])
      return [existing, false] if existing

      # Need to create pattern - first find or create UnifiedObjectType
      uot = find_or_create_unified_object_type(pattern_data)
      return [nil, false] unless uot

      pattern_attrs = {
        description: pattern_data['description'],
        unified_object_type_id: uot.id,
        image_url: pattern_data['image_url'],
        price: pattern_data['price'],
        desc_desc: pattern_data['desc_desc'],
        consume_type: pattern_data['consume_type'],
        consume_time: pattern_data['consume_time'],
        taste: pattern_data['taste'],
        effect: pattern_data['effect'],
        is_melee: pattern_data['is_melee'],
        is_ranged: pattern_data['is_ranged'],
        weapon_range: pattern_data['weapon_range'],
        attack_speed: pattern_data['attack_speed'],
        damage_dice: pattern_data['damage_dice'],
        damage_type: pattern_data['damage_type'],
        min_year: pattern_data['min_year'],
        max_year: pattern_data['max_year']
      }
      pattern = Pattern.create(pattern_attrs.select { |key, _| Pattern.columns.include?(key) })

      [pattern, true]
    end

    def find_or_create_unified_object_type(pattern_data)
      type_name = pattern_data['name'] || pattern_data['description']
      category = pattern_data['category'] || 'Top'

      # Try to find existing by name
      existing = UnifiedObjectType.first(name: type_name)
      return existing if existing

      # Create new UOT
      uot = UnifiedObjectType.create(
        name: type_name,
        category: category,
        subcategory: pattern_data['subcategory'],
        layer: pattern_data['layer'] || 0
      )

      # Set covered positions if provided
      if pattern_data['covered_positions'].is_a?(Array)
        uot.covered_positions = pattern_data['covered_positions']
      end
      if pattern_data['zippable_positions'].is_a?(Array)
        uot.zippable_positions = pattern_data['zippable_positions']
      end
      uot.save

      uot
    end

    def import_outfits(instance, outfits)
      count = 0
      errors = []

      outfits.each do |outfit_data|
        # Check if outfit already exists
        existing = Outfit.first(character_instance_id: instance.id, name: outfit_data['name'])
        if existing
          # Delete and recreate
          existing.outfit_items_dataset.delete
          existing.destroy
        end

        outfit = Outfit.create(
          character_instance_id: instance.id,
          name: outfit_data['name']
        )

        (outfit_data['items'] || []).each do |item_data|
          pattern_data = item_data['pattern']
          next unless pattern_data

          pattern, _created = find_or_create_pattern(pattern_data)
          next unless pattern

          OutfitItem.create(
            outfit_id: outfit.id,
            pattern_id: pattern.id,
            display_order: item_data['display_order'] || 0
          )
        end

        count += 1
      end

      [count, errors]
    end

    # ========================================
    # Property Import Helpers
    # ========================================

    def import_room_base(room, room_data, options = {})
      updates = {}
      updates[:short_description] = room_data['short_description'] if room_data.key?('short_description')
      updates[:long_description] = room_data['long_description'] if room_data.key?('long_description')
      updates[:room_type] = room_data['room_type'] if room_data.key?('room_type') && !room_data['room_type'].nil?
      updates[:curtains] = room_data['curtains'] == true if room_data.key?('curtains')
      updates[:is_outdoor] = room_data['is_outdoor'] == true if room_data.key?('is_outdoor')
      updates[:weather_visible] = room_data['weather_visible'] == true if room_data.key?('weather_visible')
      updates[:is_vault] = room_data['is_vault'] == true if room_data.key?('is_vault')
      updates[:safe_room] = room_data['safe_room'] == true if room_data.key?('safe_room')
      updates[:private_mode] = room_data['private_mode'] == true if room_data.key?('private_mode')
      updates[:has_battle_map] = room_data['has_battle_map'] == true if options[:import_battle_map] && room_data.key?('has_battle_map')

      # Update background URL if provided
      updates[:default_background_url] = room_data['default_background_url'] if room_data['default_background_url']
      if options[:import_battle_map]
        updates[:battle_map_image_url] = room_data['battle_map_image_url'] if room_data['battle_map_image_url']
      end

      # Update seasonal data if provided
      if room_data['seasonal_descriptions']
        updates[:seasonal_descriptions] = Sequel.pg_jsonb_wrap(room_data['seasonal_descriptions'])
      end
      if room_data['seasonal_backgrounds']
        updates[:seasonal_backgrounds] = Sequel.pg_jsonb_wrap(room_data['seasonal_backgrounds'])
      end
      if options[:import_battle_map] && room_data['battle_map_config']
        updates[:battle_map_config] = Sequel.pg_jsonb_wrap(room_data['battle_map_config'])
      end

      room.update(updates) unless updates.empty?
    end

    def import_places(room, places, source_room_data = nil, options = {})
      count = 0
      errors = []

      places.each do |place_data|
        x = place_data['x']
        y = place_data['y']
        z = place_data['z']

        if options[:scale_places] && source_room_data
          x = scaled_coordinate(x, source_room_data['min_x'], source_room_data['max_x'], room.min_x, room.max_x)
          y = scaled_coordinate(y, source_room_data['min_y'], source_room_data['max_y'], room.min_y, room.max_y)
          z = scaled_coordinate(z, source_room_data['min_z'], source_room_data['max_z'], room.min_z, room.max_z)
        end

        Place.create(
          room_id: room.id,
          name: place_data['name'],
          description: place_data['description'],
          capacity: place_data['capacity'],
          x: x,
          y: y,
          z: z,
          is_furniture: place_data['is_furniture'] || false,
          invisible: place_data['invisible'] || false,
          image_url: place_data['image_url'],
          default_sit_action: place_data['default_sit_action']
        )
        count += 1
      end

      [count, errors]
    end

    def import_decorations(room, decorations)
      count = 0
      errors = []

      decorations.each do |dec_data|
        Decoration.create(
          room_id: room.id,
          name: dec_data['name'],
          description: dec_data['description'],
          image_url: dec_data['image_url'],
          display_order: dec_data['display_order'] || 0
        )
        count += 1
      end

      [count, errors]
    end

    def import_room_features(room, features, _options = {})
      count = 0
      errors = []

      features.each do |feature_data|
        feature_attrs = {
          room_id: room.id,
          name: feature_data['name'],
          feature_type: feature_data['feature_type'],
          description: feature_data['description'],
          x: feature_data['x'],
          y: feature_data['y'],
          z: feature_data['z'],
          width: feature_data['width'],
          height: feature_data['height'],
          orientation: feature_data['orientation'],
          open_state: feature_data['open_state'] || 'closed',
          transparency_state: feature_data['transparency_state'] || 'opaque',
          visibility_state: feature_data['visibility_state'],
          allows_sight: feature_data['allows_sight'],
          allows_movement: feature_data['allows_movement'],
          has_curtains: feature_data['has_curtains'] || false,
          curtain_state: feature_data['curtain_state'],
          has_lock: feature_data['has_lock'] || false,
          sight_reduction: feature_data['sight_reduction']
        }

        RoomFeature.create(feature_attrs.select { |key, _| RoomFeature.columns.include?(key) })
        count += 1
      end

      [count, errors]
    end

    def import_room_hexes(room, hexes)
      count = 0
      errors = []

      hexes.each do |hex_data|
        RoomHex.create(
          room_id: room.id,
          hex_x: hex_data['hex_x'],
          hex_y: hex_data['hex_y'],
          hex_type: hex_data['hex_type'] || 'normal',
          surface_type: hex_data['surface_type'],
          traversable: hex_data['traversable'] != false,
          danger_level: hex_data['danger_level'] || 0,
          hazard_type: hex_data['hazard_type'],
          damage_potential: hex_data['damage_potential'] || 0,
          water_type: hex_data['water_type'],
          cover_value: hex_data['cover_value'] || 0,
          cover_object: hex_data['cover_object'],
          elevation_level: hex_data['elevation_level'] || 0,
          potential_trigger: hex_data['potential_trigger'],
          explosion_trigger: hex_data['explosion_trigger']
        )
        count += 1
      end

      # Mark room as having a battle map if hexes were imported
      room.update(has_battle_map: true) if count > 0

      [count, errors]
    end

    def scaled_coordinate(value, source_min, source_max, target_min, target_max)
      return value if value.nil?
      return value if source_min.nil? || source_max.nil? || target_min.nil? || target_max.nil?

      source_span = source_max.to_f - source_min.to_f
      target_span = target_max.to_f - target_min.to_f
      return value if source_span <= 0 || target_span <= 0

      scaled = target_min.to_f + ((value.to_f - source_min.to_f) * target_span / source_span)
      scaled.round
    end
  end
end
