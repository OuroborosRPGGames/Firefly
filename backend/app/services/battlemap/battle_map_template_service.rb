# frozen_string_literal: true
require 'vips'

class BattleMapTemplateService
  DELVE_SHAPES = {
    'rect_vertical'   => { w: 12.0, h: 24.0, name: 'Dungeon Corridor',
                           desc: 'A narrow stone dungeon corridor running north to south, rough-hewn walls with flickering torches mounted in iron brackets, cracked flagstone floor with scattered gravel and dust, open stone archway entrances at both the north and south ends' },
    'rect_horizontal' => { w: 24.0, h: 12.0, name: 'Dungeon Passage',
                           desc: 'A narrow stone dungeon passage running east to west, ancient mortared walls with iron-bracketed torches every few feet, worn stone floor with scattered gravel, open stone archway entrances at both the east and west ends' },
    'small_chamber'   => { w: 18.0, h: 18.0, name: 'Dungeon Chamber',
                           desc: 'A small dungeon chamber with rough stone walls, torches flickering in wall sconces, scattered rubble and debris on the flagstone floor' },
    'large_chamber'   => { w: 26.0, h: 26.0, name: 'Dungeon Hall',
                           desc: 'A large dungeon hall with thick stone pillars supporting a vaulted ceiling, torches burning in iron brackets along the walls, a shallow underground stream cutting across the chamber floor, ominous atmosphere with ancient carvings on the walls' }
  }.freeze

  def self.generate_template!(category:, shape_key:, variant: 0)
    shape = DELVE_SHAPES[shape_key]
    raise "Unknown shape: #{shape_key}" unless shape

    room = find_or_create_generation_room(shape[:w], shape[:h], shape[:name], shape[:desc])

    # Clear any previous battlemap on this room
    room.clear_battle_map! if room.battle_map_ready?

    # Generate AI battlemap (handles landscape rotation internally)
    result = AIBattleMapGeneratorService.new(room).generate
    unless result[:success]
      warn "[BattleMapTemplateService] Generation failed for #{category}/#{shape_key}: #{result.inspect}"
      return nil
    end

    room.reload
    store_template_from_room(room, category: category, shape_key: shape_key, variant: variant, shape: shape)
  end

  def self.apply_to_room!(template, room)
    hex_data = template.hex_data
    hexes = hex_data.respond_to?(:to_a) ? hex_data.to_a : (hex_data.is_a?(Array) ? hex_data : [])
    return false if hexes.empty?

    now = Time.now
    room_hex_columns = RoomHex.columns
    rows = hexes.map do |h|
      hex_type = h['hex_type'] || 'normal'
      row = {
        room_id: room.id,
        hex_x: h['hex_x'], hex_y: h['hex_y'],
        hex_type: hex_type,
        traversable: h.fetch('traversable', true),
        danger_level: h['danger_level'] || 0,
        elevation_level: h['elevation_level'] || 0,
        has_cover: h.key?('has_cover') ? h['has_cover'] : (hex_type == 'cover'),
        cover_value: h['cover_value'] || 0,
        cover_object: h['cover_object'],
        surface_type: h['surface_type'],
        difficult_terrain: h['difficult_terrain'] || false,
        hazard_type: h['hazard_type'],
        water_type: h['water_type'],
        created_at: now, updated_at: now
      }
      row[:wall_feature] = h['wall_feature'] if room_hex_columns.include?(:wall_feature)
      row[:passable_edges] = h['passable_edges'] if room_hex_columns.include?(:passable_edges)
      row[:majority_floor] = h['majority_floor'] if room_hex_columns.include?(:majority_floor) && h.key?('majority_floor')
      row
    end

    DB.transaction do
      room.room_hexes_dataset.delete
      RoomHex.multi_insert(rows)
      light_sources = template.respond_to?(:light_sources) ? (template.light_sources || []) : []
      room_columns = Room.columns
      attrs = {}
      attrs[:has_battle_map] = true if room_columns.include?(:has_battle_map)
      attrs[:battle_map_image_url] = template.image_url if room_columns.include?(:battle_map_image_url)
      attrs[:battle_map_water_mask_url] = template.water_mask_url if room_columns.include?(:battle_map_water_mask_url)
      attrs[:battle_map_foliage_mask_url] = template.foliage_mask_url if room_columns.include?(:battle_map_foliage_mask_url)
      attrs[:battle_map_fire_mask_url] = template.fire_mask_url if room_columns.include?(:battle_map_fire_mask_url)
      attrs[:battle_map_wall_mask_url] = template.respond_to?(:wall_mask_url) ? template.wall_mask_url : nil if room_columns.include?(:battle_map_wall_mask_url)
      attrs[:battle_map_wall_mask_width] = nil if room_columns.include?(:battle_map_wall_mask_width)
      attrs[:battle_map_wall_mask_height] = nil if room_columns.include?(:battle_map_wall_mask_height)
      attrs[:depth_map_path] = nil if room_columns.include?(:depth_map_path)
      attrs[:detected_light_sources] = Sequel.pg_jsonb_wrap(JSON.parse(light_sources.to_json)) if room_columns.include?(:detected_light_sources)
      if room_columns.include?(:battle_map_object_metadata) && template.respond_to?(:ai_object_metadata)
        obj_meta = template.ai_object_metadata
        attrs[:battle_map_object_metadata] = Sequel.pg_jsonb_wrap(JSON.parse(obj_meta.to_json)) if obj_meta && !obj_meta.empty?
      end
      if room_columns.include?(:battle_map_object_map_url) && template.respond_to?(:object_map_url)
        attrs[:battle_map_object_map_url] = template.object_map_url
      end

      # Update room spatial bounds to match template dimensions so the Fight arena
      # calculated from room feet matches the template's hex grid exactly.
      if template.width_feet && template.height_feet
        room_min_x = room.min_x || 0.0
        room_min_y = room.min_y || 0.0
        attrs[:max_x] = room_min_x + template.width_feet
        attrs[:max_y] = room_min_y + template.height_feet
      end

      wall_mask_url = attrs[:battle_map_wall_mask_url]
      if wall_mask_url && wall_mask_url.start_with?('/')
        wall_mask_path = File.join('public', wall_mask_url.sub(%r{^/}, ''))
        if File.exist?(wall_mask_path)
          begin
            img = Vips::Image.new_from_file(wall_mask_path)
            attrs[:battle_map_wall_mask_width] = img.width
            attrs[:battle_map_wall_mask_height] = img.height
          rescue StandardError => e
            warn "[BattleMapTemplateService] Failed to read wall mask dimensions: #{e.message}"
          end
        end
      end

      room.update(attrs) unless attrs.empty?
    end

    template.touch!
    true
  end

  def self.apply_random!(category:, shape_key:, room:)
    template = BattleMapTemplate.random_for(category, shape_key)
    return false unless template

    apply_to_room!(template, room)
  end

  # When a template source room's hexes are edited (e.g. via the battlemap editor),
  # sync those changes back into the stored template JSONB so future fights use the update.
  def self.sync_from_room_if_template!(room)
    shape_entry = DELVE_SHAPES.find { |_key, shape| shape[:name] == room.name }
    return unless shape_entry

    shape_key, shape = shape_entry
    template = BattleMapTemplate.first(category: 'delve', shape_key: shape_key)
    return unless template

    store_template_from_room(room, category: 'delve', shape_key: shape_key, variant: template.variant, shape: shape)
  rescue StandardError => e
    warn "[BattleMapTemplateService] sync_from_room_if_template! failed for room #{room.id}: #{e.message}"
  end

  # Map delve room to shape_key
  def self.delve_shape_key(delve_room)
    return 'large_chamber' if delve_room.is_boss

    case delve_room.room_type.to_s
    when 'corridor'
      exits = delve_room.available_exits.reject { |d| d == 'down' }
      east_west = (exits & %w[east west]).any? && (exits & %w[north south]).empty?
      east_west ? 'rect_horizontal' : 'rect_vertical'
    else
      'small_chamber'
    end
  end

  # --- Private ---

  def self.find_or_create_generation_room(width, height, name, description)
    room = Room.first(name: name)
    unless room
      location = Location.first || Location.create(name: 'Template Generation', world_id: World.first&.id || 1)
      room = Room.create(
        name: name,
        location_id: location.id,
        room_type: 'dungeon',
        short_description: description,
        long_description: description,
        min_x: 0.0, max_x: width,
        min_y: 0.0, max_y: height,
        min_z: 0.0, max_z: 10.0
      )
    end

    room.update(
      name: name,
      min_x: 0.0, max_x: width,
      min_y: 0.0, max_y: height,
      short_description: description,
      long_description: description,
      room_type: 'dungeon'
    )
    room
  end

  # Extract hex data and store as template
  def self.store_template_from_room(room, category:, shape_key:, variant:, shape:)
    room_hex_columns = RoomHex.columns
    hex_data = room.room_hexes_dataset.all.map do |hex|
      row = {
        'hex_x' => hex.hex_x, 'hex_y' => hex.hex_y,
        'hex_type' => hex.hex_type, 'traversable' => hex.traversable,
        'danger_level' => hex.danger_level, 'elevation_level' => hex.elevation_level,
        'has_cover' => hex.has_cover, 'cover_value' => hex.cover_value, 'cover_object' => hex.cover_object,
        'surface_type' => hex.surface_type, 'difficult_terrain' => hex.difficult_terrain,
        'hazard_type' => hex.hazard_type, 'water_type' => hex.water_type
      }
      row['wall_feature'] = hex.wall_feature if room_hex_columns.include?(:wall_feature)
      row['passable_edges'] = hex.passable_edges if room_hex_columns.include?(:passable_edges)
      row['majority_floor'] = hex.majority_floor if room_hex_columns.include?(:majority_floor)
      row
    end

    light_sources = room.respond_to?(:detected_light_sources) ? (room.detected_light_sources || []) : []

    wall_mask_url = room.respond_to?(:battle_map_wall_mask_url) ? room.battle_map_wall_mask_url : nil

    BattleMapTemplate.where(category: category, shape_key: shape_key, variant: variant).delete
    template_columns = BattleMapTemplate.columns
    create_attrs = {
      category: category,
      shape_key: shape_key,
      variant: variant,
      width_feet: shape[:w],
      height_feet: shape[:h],
      hex_data: Sequel.pg_jsonb_wrap(hex_data),
      image_url: room.battle_map_image_url,
      water_mask_url: room.battle_map_water_mask_url,
      foliage_mask_url: room.battle_map_foliage_mask_url,
      fire_mask_url: room.battle_map_fire_mask_url,
      description_hint: shape[:desc],
      last_used_at: Time.now
    }
    create_attrs[:wall_mask_url] = wall_mask_url if template_columns.include?(:wall_mask_url)
    create_attrs[:light_sources] = Sequel.pg_jsonb_wrap(JSON.parse(light_sources.to_json)) if template_columns.include?(:light_sources)
    # Object metadata and mask from AI classification
    if template_columns.include?(:ai_object_metadata) && room.respond_to?(:battle_map_object_metadata)
      obj_meta = room.battle_map_object_metadata
      create_attrs[:ai_object_metadata] = Sequel.pg_jsonb_wrap(JSON.parse(obj_meta.to_json)) if obj_meta && !obj_meta.empty?
    end
    if template_columns.include?(:object_map_url) && room.respond_to?(:battle_map_object_map_url)
      create_attrs[:object_map_url] = room.battle_map_object_map_url
    end
    BattleMapTemplate.create(create_attrs)
  end

  private_class_method :find_or_create_generation_room, :store_template_from_room
end
