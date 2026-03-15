# frozen_string_literal: true

# RoomBuilderService provides business logic for the Room Builder GUI.
#
# Handles CRUD operations for room elements: places, decorations,
# features, spatial exits (read-only), and sub-rooms.
#
class RoomBuilderService
  class << self
    # === ROOM ===

    # Build a complete API hash for a single room. Designed for single-room
    # detail views; not suitable for batch usage due to multiple lazy loads.
    def room_to_api_hash(room)
      spatial_exits = room.passable_spatial_exits.map { |e| spatial_exit_to_api_hash(e) }

      room_identity_hash(room)
        .merge(room_geometry_hash(room))
        .merge(room_flags_hash(room))
        .merge(room_contents_hash(room, spatial_exits))
    end

    private

    def room_identity_hash(room)
      {
        id: room.id,
        name: room.name,
        room_type: room.room_type,
        short_description: room.short_description,
        long_description: room.long_description,
        location_id: room.location_id,
        location_name: room.location&.name,
        owner_id: room.owner_id,
        owner_name: room.owner&.name,
        inside_room_id: room.inside_room_id,
        inside_room_name: room.inside_room&.name
      }
    end

    def room_geometry_hash(room)
      {
        min_x: room.min_x || 0,
        max_x: room.max_x || 100,
        min_y: room.min_y || 0,
        max_y: room.max_y || 100,
        min_z: room.min_z || 0,
        max_z: room.max_z || 10,
        zone_polygon: (room.location&.zone_polygon_in_feet || []),
        room_polygon: room.room_polygon
      }
    end

    def room_flags_hash(room)
      {
        background_picture_url: room.background_picture_url,
        default_background_url: room.default_background_url,
        curtains: room.curtains || false,
        private_mode: room.private_mode || false,
        publicity: room.publicity || 'public',
        indoors: room.indoors.nil? ? true : room.indoors,
        safe_room: !!room.safe_room,
        no_attack: !!room.no_attack,
        tutorial_room: !!room.tutorial_room,
        is_vault: !!room.is_vault,
        seasonal_descriptions: room.seasonal_descriptions
      }
    end

    def room_contents_hash(room, spatial_exits)
      {
        places: room.places.map { |p| place_to_api_hash(p) },
        decorations: room.decorations.map { |d| decoration_to_api_hash(d) },
        features: RoomFeature.visible_from(room).map { |f| feature_to_api_hash(f) },
        # Keep both keys for backward compatibility. Exits are spatial/read-only.
        exits: spatial_exits,
        spatial_exits: spatial_exits,
        subrooms: room.contained_rooms.map { |sr| subroom_to_api_hash(sr) }
      }
    end

    public

    def update_room(room, data)
      allowed = %w[name short_description long_description min_x max_x min_y max_y min_z max_z default_background_url curtains private_mode room_type publicity indoors seasonal_descriptions safe_room no_attack tutorial_room is_vault]
      updates = data.slice(*allowed)

      # Map legacy field name to current column name
      if data.key?('background_picture_url') && !data.key?('default_background_url')
        updates['default_background_url'] = data['background_picture_url']
      end

      # Convert string keys and types
      updates.transform_keys!(&:to_sym)
      %i[min_x max_x min_y max_y min_z max_z].each do |key|
        updates[key] = updates[key].to_i if updates.key?(key)
      end
      updates[:curtains] = !!updates[:curtains] if updates.key?(:curtains)
      updates[:private_mode] = !!updates[:private_mode] if updates.key?(:private_mode)
      updates[:indoors] = !!updates[:indoors] if updates.key?(:indoors)
      %i[safe_room no_attack tutorial_room is_vault].each do |flag|
        updates[flag] = !!updates[flag] if updates.key?(flag)
      end

      # Wrap seasonal_descriptions in JSONB
      if updates.key?(:seasonal_descriptions) && updates[:seasonal_descriptions].is_a?(Hash)
        updates[:seasonal_descriptions] = Sequel.pg_jsonb_wrap(updates[:seasonal_descriptions])
      end

      room.update(updates)

      # Invalidate exit cache if geometry or structural fields changed
      geometry_keys = %i[min_x max_x min_y max_y min_z max_z indoors room_type]
      if geometry_keys.any? { |k| updates.key?(k) }
        RoomExitCacheService.invalidate_location!(room.location_id)
      end

      { success: true, room: room_to_api_hash(room) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end

    # === PLACES (Furniture) ===

    def place_to_api_hash(place)
      {
        id: place.id,
        name: place.name,
        description: place.description,
        x: place.x || 0,
        y: place.y || 0,
        z: place.z || 0,
        capacity: place.capacity || 1,
        is_furniture: place.is_furniture,
        invisible: place.invisible,
        default_sit_action: place.default_sit_action || 'on',
        icon: place.respond_to?(:icon) ? place.icon : nil
      }
    end

    def create_place(room, data)
      place = Place.create(
        room_id: room.id,
        name: data['name'] || 'New Furniture',
        description: data['description'],
        x: data['x']&.to_i || 50,
        y: data['y']&.to_i || 50,
        z: data['z']&.to_i || 0,
        capacity: data['capacity']&.to_i || 1,
        is_furniture: data['is_furniture'] != false,
        invisible: data['invisible'] == true,
        default_sit_action: data['default_sit_action'] || 'on',
        icon: data['icon']
      )
      { success: true, place: place_to_api_hash(place) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end

    def update_place(place, data)
      allowed = %w[name description x y z capacity is_furniture invisible default_sit_action icon]
      updates = data.slice(*allowed)
      updates.transform_keys!(&:to_sym)

      %i[x y z capacity].each do |key|
        updates[key] = updates[key].to_i if updates.key?(key)
      end
      updates[:is_furniture] = !!updates[:is_furniture] if updates.key?(:is_furniture)
      updates[:invisible] = !!updates[:invisible] if updates.key?(:invisible)

      place.update(updates)
      { success: true, place: place_to_api_hash(place) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end

    # === DECORATIONS ===

    def decoration_to_api_hash(decoration)
      {
        id: decoration.id,
        name: decoration.name,
        description: decoration.description,
        image_url: decoration.image_url,
        display_order: decoration.display_order || 0,
        x: decoration.respond_to?(:x) ? (decoration.x || 0) : 0,
        y: decoration.respond_to?(:y) ? (decoration.y || 0) : 0,
        icon: decoration.respond_to?(:icon) ? decoration.icon : nil
      }
    end

    def create_decoration(room, data)
      max_order = room.decorations_dataset.max(:display_order) || 0
      decoration = Decoration.create(
        room_id: room.id,
        name: data['name'] || 'New Decoration',
        description: data['description'],
        image_url: data['image_url'],
        display_order: data['display_order']&.to_i || (max_order + 1),
        x: data['x']&.to_f || 0,
        y: data['y']&.to_f || 0,
        icon: data['icon']
      )
      { success: true, decoration: decoration_to_api_hash(decoration) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end

    def update_decoration(decoration, data)
      allowed = %w[name description image_url display_order x y icon]
      updates = data.slice(*allowed)
      updates.transform_keys!(&:to_sym)
      updates[:display_order] = updates[:display_order].to_i if updates.key?(:display_order)
      updates[:x] = updates[:x].to_f if updates.key?(:x)
      updates[:y] = updates[:y].to_f if updates.key?(:y)

      decoration.update(updates)
      { success: true, decoration: decoration_to_api_hash(decoration) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end

    # === ROOM FEATURES (Doors/Windows) ===

    def feature_to_api_hash(feature)
      {
        id: feature.id,
        name: feature.name,
        feature_type: feature.feature_type,
        x: feature.x,
        y: feature.y,
        z: feature.z,
        width: feature.width,
        height: feature.height,
        orientation: feature.orientation,
        open_state: feature.open_state,
        transparency_state: feature.transparency_state,
        allows_movement: feature.allows_movement,
        allows_sight: feature.allows_sight,
        has_lock: feature[:has_lock],
        has_curtains: feature[:has_curtains],
        curtain_state: feature.curtain_state,
        connected_room_id: feature.connected_room_id,
        connected_room_name: feature.connected_room&.name
      }
    end

    def create_feature(room, data)
      feature = RoomFeature.create(
        room_id: room.id,
        name: data['name'] || 'New Feature',
        feature_type: data['feature_type'] || 'door',
        x: data['x']&.to_f || 0,
        y: data['y']&.to_f || 0,
        z: data['z']&.to_f || 0,
        width: data['width']&.to_f || 3.0,
        height: data['height']&.to_f || 7.0,
        orientation: data['orientation'] || 'north',
        open_state: data['open_state'] || 'closed',
        transparency_state: data['transparency_state'] || 'opaque',
        visibility_state: data['visibility_state'] || 'both_ways',
        allows_movement: data['allows_movement'] != false,
        allows_sight: data['allows_sight'] != false,
        has_lock: data['has_lock'] == true,
        has_curtains: data['has_curtains'] == true,
        curtain_state: data['curtain_state'] || 'open',
        connected_room_id: data['connected_room_id']&.to_i,
        sight_reduction: data['sight_reduction']&.to_f || 0.0
      )
      RoomExitCacheService.invalidate_location!(room.location_id)
      # Also invalidate connected room's location cache
      if feature.connected_room_id
        connected = Room[feature.connected_room_id]
        if connected && connected.location_id != room.location_id
          RoomExitCacheService.invalidate_location!(connected.location_id)
        end
      end
      { success: true, feature: feature_to_api_hash(feature) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end

    def update_feature(feature, data)
      allowed = %w[name feature_type x y z width height orientation open_state transparency_state visibility_state allows_movement allows_sight has_lock has_curtains curtain_state connected_room_id sight_reduction]
      updates = data.slice(*allowed)
      updates.transform_keys!(&:to_sym)

      %i[x y z width height sight_reduction].each do |key|
        updates[key] = updates[key].to_f if updates.key?(key)
      end
      %i[allows_movement allows_sight has_lock has_curtains].each do |key|
        updates[key] = !!updates[key] if updates.key?(key)
      end
      updates[:connected_room_id] = updates[:connected_room_id]&.to_i if updates.key?(:connected_room_id)

      feature.update(updates)
      RoomExitCacheService.invalidate_location!(feature.room.location_id)
      # Also invalidate connected room's location cache
      if feature.connected_room_id
        connected = Room[feature.connected_room_id]
        if connected && connected.location_id != feature.room.location_id
          RoomExitCacheService.invalidate_location!(connected.location_id)
        end
      end
      { success: true, feature: feature_to_api_hash(feature) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end

    # === SPATIAL EXITS (Read-only, calculated from polygon geometry) ===

    def spatial_exit_to_api_hash(exit_data)
      room = exit_data[:room]
      {
        direction: exit_data[:direction].to_s,
        to_room_id: room.id,
        to_room_name: room.name,
        room_type: room.room_type,
        exit_type: :spatial
      }
    end

    # === SUB-ROOMS (Nested) ===

    def subroom_to_api_hash(subroom)
      {
        id: subroom.id,
        name: subroom.name,
        room_type: subroom.room_type,
        short_description: subroom.short_description,
        min_x: subroom.min_x || 0,
        max_x: subroom.max_x || 20,
        min_y: subroom.min_y || 0,
        max_y: subroom.max_y || 20,
        min_z: subroom.min_z || 0,
        max_z: subroom.max_z || 10,
        room_polygon: subroom.room_polygon,
        polygon_mode: subroom.polygon_mode || 'simple',
        has_custom_polygon: subroom.has_custom_polygon?,
        features: RoomFeature.visible_from(subroom).map { |f| feature_to_api_hash(f) }
      }
    end

    def create_subroom(parent_room, data)
      # Handle polygon data
      room_polygon = data['room_polygon']
      polygon_mode = data['polygon_mode'] || 'simple'

      # Wrap polygon in JSONB if provided
      room_polygon_value = if room_polygon && room_polygon.is_a?(Array) && room_polygon.size >= 3
                             Sequel.pg_jsonb_wrap(room_polygon)
                           end

      subroom = Room.create(
        location_id: parent_room.location_id,
        inside_room_id: parent_room.id,
        name: data['name'] || 'New Room',
        room_type: data['room_type'] || 'standard',
        short_description: data['short_description'] || 'A small room.',
        long_description: data['long_description'],
        min_x: data['min_x']&.to_i || 0,
        max_x: data['max_x']&.to_i || 20,
        min_y: data['min_y']&.to_i || 0,
        max_y: data['max_y']&.to_i || 20,
        min_z: data['min_z']&.to_i || parent_room.min_z || 0,
        max_z: data['max_z']&.to_i || parent_room.max_z || 10,
        owner_id: parent_room.owner_id,
        room_polygon: room_polygon_value,
        polygon_mode: polygon_mode
      )
      RoomExitCacheService.invalidate_location!(parent_room.location_id)
      { success: true, subroom: subroom_to_api_hash(subroom) }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    end
  end
end
