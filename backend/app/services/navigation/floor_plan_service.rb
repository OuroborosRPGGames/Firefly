# frozen_string_literal: true

# FloorPlanService generates 2D floor plans for building interiors.
#
# Uses templates for known building types and BSP subdivision for
# unknown/AI-generated buildings. Returns coordinate data only — callers
# create Room records from the results.
#
# @example Generate a house ground floor
#   FloorPlanService.generate(
#     building_bounds: { min_x: 25, max_x: 175, min_y: 25, max_y: 175 },
#     floor_number: 0,
#     building_type: :house
#   )
#
class FloorPlanService
  FLOOR_HEIGHT = 10 # feet per floor

  # Template definitions: rooms as proportional rectangles (0.0–1.0).
  # x/y are fractions of the floor width/height. Hallway style varies by type.
  #
  # Hallway styles:
  #   :l_entry      — strip along south edge (entry from street)
  #   :central      — strip through the center, rooms on both sides
  #   :nave         — wide central passage (churches)
  #   :lobby_entry  — room at south end, larger space behind
  #   :none         — no hallway (single open spaces)
  TEMPLATES = {
    # === HOUSES ===
    house_ground: {
      hallway_style: :l_entry,
      hallway: { name: 'Entry Hall', x: 0.0, y: 0.0, w: 1.0, h: 0.2 },
      rooms: [
        { name: 'Kitchen', type: 'residence', x: 0.0, y: 0.2, w: 0.45, h: 0.8 },
        { name: 'Living Room', type: 'residence', x: 0.45, y: 0.2, w: 0.55, h: 0.8 }
      ]
    },
    house_upper: {
      hallway_style: :l_entry,
      hallway: { name: 'Landing', x: 0.0, y: 0.0, w: 1.0, h: 0.2 },
      rooms: [
        { name: 'Bedroom', type: 'residence', x: 0.0, y: 0.2, w: 0.5, h: 0.55 },
        { name: 'Second Bedroom', type: 'residence', x: 0.5, y: 0.2, w: 0.5, h: 0.8 },
        { name: 'Bathroom', type: 'bathroom', x: 0.0, y: 0.75, w: 0.5, h: 0.25 }
      ]
    },

    # === BROWNSTONES ===
    brownstone_ground: {
      hallway_style: :l_entry,
      hallway: { name: 'Foyer', x: 0.0, y: 0.0, w: 0.3, h: 1.0 },
      rooms: [
        { name: 'Parlor', type: 'residence', x: 0.3, y: 0.0, w: 0.7, h: 0.5 },
        { name: 'Kitchen', type: 'residence', x: 0.3, y: 0.5, w: 0.7, h: 0.5 }
      ]
    },
    brownstone_upper: {
      hallway_style: :l_entry,
      hallway: { name: 'Landing', x: 0.0, y: 0.0, w: 0.25, h: 1.0 },
      rooms: [
        { name: 'Bedroom', type: 'residence', x: 0.25, y: 0.0, w: 0.75, h: 0.6 },
        { name: 'Study', type: 'residence', x: 0.25, y: 0.6, w: 0.75, h: 0.4 }
      ]
    },

    # === APARTMENTS / OFFICES / HOTELS ===
    apartment_floor: {
      hallway_style: :central,
      hallway: { name: 'Corridor', x: 0.35, y: 0.0, w: 0.3, h: 1.0 },
      rooms: [
        { name: 'Unit A', type: 'apartment', x: 0.0, y: 0.0, w: 0.35, h: 0.5 },
        { name: 'Unit B', type: 'apartment', x: 0.0, y: 0.5, w: 0.35, h: 0.5 },
        { name: 'Unit C', type: 'apartment', x: 0.65, y: 0.0, w: 0.35, h: 0.5 },
        { name: 'Unit D', type: 'apartment', x: 0.65, y: 0.5, w: 0.35, h: 0.5 }
      ]
    },
    apartment_lobby: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Lobby', x: 0.0, y: 0.0, w: 1.0, h: 0.4 },
      rooms: [
        { name: 'Mail Room', type: 'commercial', x: 0.0, y: 0.4, w: 0.4, h: 0.6 },
        { name: 'Management Office', type: 'commercial', x: 0.4, y: 0.4, w: 0.6, h: 0.6 }
      ]
    },
    office_floor: {
      hallway_style: :central,
      hallway: { name: 'Corridor', x: 0.35, y: 0.0, w: 0.3, h: 1.0 },
      rooms: [
        { name: 'Office A', type: 'commercial', x: 0.0, y: 0.0, w: 0.35, h: 0.5 },
        { name: 'Office B', type: 'commercial', x: 0.0, y: 0.5, w: 0.35, h: 0.5 },
        { name: 'Office C', type: 'commercial', x: 0.65, y: 0.0, w: 0.35, h: 0.5 },
        { name: 'Office D', type: 'commercial', x: 0.65, y: 0.5, w: 0.35, h: 0.5 }
      ]
    },
    hotel_floor: {
      hallway_style: :central,
      hallway: { name: 'Corridor', x: 0.3, y: 0.0, w: 0.4, h: 1.0 },
      rooms: [
        { name: 'Room', type: 'residence', x: 0.0, y: 0.0, w: 0.3, h: 0.35 },
        { name: 'Room', type: 'residence', x: 0.0, y: 0.35, w: 0.3, h: 0.35 },
        { name: 'Room', type: 'residence', x: 0.0, y: 0.7, w: 0.3, h: 0.3 },
        { name: 'Room', type: 'residence', x: 0.7, y: 0.0, w: 0.3, h: 0.35 },
        { name: 'Room', type: 'residence', x: 0.7, y: 0.35, w: 0.3, h: 0.35 },
        { name: 'Room', type: 'residence', x: 0.7, y: 0.7, w: 0.3, h: 0.3 }
      ]
    },
    hotel_lobby: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Lobby', x: 0.0, y: 0.0, w: 1.0, h: 0.5 },
      rooms: [
        { name: 'Concierge', type: 'commercial', x: 0.0, y: 0.5, w: 0.5, h: 0.5 },
        { name: 'Lounge', type: 'commercial', x: 0.5, y: 0.5, w: 0.5, h: 0.5 }
      ]
    },

    # === CHURCHES / TEMPLES ===
    church_ground: {
      hallway_style: :nave,
      hallway: { name: 'Nave', x: 0.2, y: 0.0, w: 0.6, h: 1.0 },
      rooms: [
        { name: 'Vestry', type: 'temple', x: 0.0, y: 0.0, w: 0.2, h: 0.5 },
        { name: 'Chapel', type: 'temple', x: 0.0, y: 0.5, w: 0.2, h: 0.5 },
        { name: 'Altar Room', type: 'temple', x: 0.8, y: 0.0, w: 0.2, h: 0.6 },
        { name: 'Office', type: 'commercial', x: 0.8, y: 0.6, w: 0.2, h: 0.4 }
      ]
    },

    # === SCHOOLS ===
    school_floor: {
      hallway_style: :central,
      hallway: { name: 'Corridor', x: 0.3, y: 0.0, w: 0.4, h: 1.0 },
      rooms: [
        { name: 'Classroom', type: 'commercial', x: 0.0, y: 0.0, w: 0.3, h: 0.5 },
        { name: 'Classroom', type: 'commercial', x: 0.0, y: 0.5, w: 0.3, h: 0.5 },
        { name: 'Classroom', type: 'commercial', x: 0.7, y: 0.0, w: 0.3, h: 0.5 },
        { name: 'Classroom', type: 'commercial', x: 0.7, y: 0.5, w: 0.3, h: 0.5 }
      ]
    },
    school_ground: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Main Hall', x: 0.0, y: 0.0, w: 1.0, h: 0.4 },
      rooms: [
        { name: 'Office', type: 'commercial', x: 0.0, y: 0.4, w: 0.35, h: 0.6 },
        { name: 'Assembly Hall', type: 'commercial', x: 0.35, y: 0.4, w: 0.65, h: 0.6 }
      ]
    },

    # === HOSPITALS ===
    hospital_ground: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Reception', x: 0.0, y: 0.0, w: 1.0, h: 0.35 },
      rooms: [
        { name: 'Emergency', type: 'commercial', x: 0.0, y: 0.35, w: 0.5, h: 0.65 },
        { name: 'Triage', type: 'commercial', x: 0.5, y: 0.35, w: 0.5, h: 0.65 }
      ]
    },
    hospital_floor: {
      hallway_style: :central,
      hallway: { name: 'Corridor', x: 0.3, y: 0.0, w: 0.4, h: 1.0 },
      rooms: [
        { name: 'Ward', type: 'commercial', x: 0.0, y: 0.0, w: 0.3, h: 0.5 },
        { name: 'Ward', type: 'commercial', x: 0.0, y: 0.5, w: 0.3, h: 0.5 },
        { name: 'Ward', type: 'commercial', x: 0.7, y: 0.0, w: 0.3, h: 0.5 },
        { name: 'Ward', type: 'commercial', x: 0.7, y: 0.5, w: 0.3, h: 0.5 }
      ]
    },

    # === SHOPS / COMMERCIAL (no hallway) ===
    shop_single: {
      hallway_style: :none,
      rooms: [
        { name: 'Shop Floor', type: 'commercial', x: 0.0, y: 0.0, w: 1.0, h: 0.65 },
        { name: 'Back Room', type: 'commercial', x: 0.0, y: 0.65, w: 1.0, h: 0.35 }
      ]
    },
    bar_single: {
      hallway_style: :none,
      rooms: [
        { name: 'Bar', type: 'commercial', x: 0.0, y: 0.0, w: 1.0, h: 0.7 },
        { name: 'Kitchen', type: 'commercial', x: 0.0, y: 0.7, w: 1.0, h: 0.3 }
      ]
    },
    restaurant_single: {
      hallway_style: :none,
      rooms: [
        { name: 'Dining Room', type: 'commercial', x: 0.0, y: 0.0, w: 0.65, h: 1.0 },
        { name: 'Kitchen', type: 'commercial', x: 0.65, y: 0.0, w: 0.35, h: 1.0 }
      ]
    },

    # Upper floors for commercial buildings
    shop_upper: {
      hallway_style: :none,
      rooms: [
        { name: 'Storage', type: 'storage', x: 0.0, y: 0.0, w: 0.5, h: 1.0 },
        { name: 'Office', type: 'office', x: 0.5, y: 0.0, w: 0.5, h: 1.0 }
      ]
    },
    bar_upper: {
      hallway_style: :l_entry,
      hallway: { name: 'Upper Landing', x: 0.0, y: 0.0, w: 1.0, h: 0.2 },
      rooms: [
        { name: 'Private Room', type: 'bar', x: 0.0, y: 0.2, w: 0.5, h: 0.8 },
        { name: 'Storage Room', type: 'storage', x: 0.5, y: 0.2, w: 0.5, h: 0.8 }
      ]
    },
    restaurant_upper: {
      hallway_style: :l_entry,
      hallway: { name: 'Upper Hall', x: 0.0, y: 0.0, w: 1.0, h: 0.2 },
      rooms: [
        { name: 'Private Dining', type: 'restaurant', x: 0.0, y: 0.2, w: 0.6, h: 0.8 },
        { name: 'Office', type: 'office', x: 0.6, y: 0.2, w: 0.4, h: 0.8 }
      ]
    },

    # === CINEMA ===
    cinema_ground: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Lobby', x: 0.0, y: 0.0, w: 1.0, h: 0.3 },
      rooms: [
        { name: 'Main Theater', type: 'commercial', x: 0.0, y: 0.3, w: 1.0, h: 0.7 }
      ]
    },

    # === GYM ===
    gym_ground: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Reception', x: 0.0, y: 0.0, w: 1.0, h: 0.2 },
      rooms: [
        { name: 'Main Floor', type: 'commercial', x: 0.0, y: 0.2, w: 0.6, h: 0.8 },
        { name: 'Studios', type: 'commercial', x: 0.6, y: 0.2, w: 0.4, h: 0.8 }
      ]
    },

    # === MALL ===
    mall_floor: {
      hallway_style: :central,
      hallway: { name: 'Atrium', x: 0.25, y: 0.0, w: 0.5, h: 1.0 },
      rooms: [
        { name: 'Shop', type: 'commercial', x: 0.0, y: 0.0, w: 0.25, h: 0.35 },
        { name: 'Shop', type: 'commercial', x: 0.0, y: 0.35, w: 0.25, h: 0.35 },
        { name: 'Shop', type: 'commercial', x: 0.0, y: 0.7, w: 0.25, h: 0.3 },
        { name: 'Shop', type: 'commercial', x: 0.75, y: 0.0, w: 0.25, h: 0.35 },
        { name: 'Shop', type: 'commercial', x: 0.75, y: 0.35, w: 0.25, h: 0.35 },
        { name: 'Shop', type: 'commercial', x: 0.75, y: 0.7, w: 0.25, h: 0.3 }
      ]
    },

    # === EMERGENCY SERVICES ===
    police_ground: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Front Desk', x: 0.0, y: 0.0, w: 1.0, h: 0.35 },
      rooms: [
        { name: 'Holding Cells', type: 'commercial', x: 0.0, y: 0.35, w: 0.4, h: 0.65 },
        { name: 'Offices', type: 'commercial', x: 0.4, y: 0.35, w: 0.6, h: 0.65 }
      ]
    },
    fire_ground: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Engine Bay', x: 0.0, y: 0.0, w: 1.0, h: 0.6 },
      rooms: [
        { name: 'Living Quarters', type: 'residence', x: 0.0, y: 0.6, w: 0.5, h: 0.4 },
        { name: 'Kitchen', type: 'residence', x: 0.5, y: 0.6, w: 0.5, h: 0.4 }
      ]
    },

    # === TERRACE / TOWNHOUSE ===
    terrace_ground: {
      hallway_style: :l_entry,
      hallway: { name: 'Entry', x: 0.0, y: 0.0, w: 0.3, h: 1.0 },
      rooms: [
        { name: 'Living Room', type: 'residence', x: 0.3, y: 0.0, w: 0.7, h: 1.0 }
      ]
    },
    terrace_upper: {
      hallway_style: :l_entry,
      hallway: { name: 'Landing', x: 0.0, y: 0.0, w: 0.3, h: 1.0 },
      rooms: [
        { name: 'Bedroom', type: 'residence', x: 0.3, y: 0.0, w: 0.7, h: 0.65 },
        { name: 'Bathroom', type: 'bathroom', x: 0.3, y: 0.65, w: 0.7, h: 0.35 }
      ]
    },

    # === PARKING ===
    parking_floor: {
      hallway_style: :none,
      rooms: [
        { name: 'Parking Level', type: 'standard', x: 0.0, y: 0.0, w: 1.0, h: 1.0 }
      ]
    },

    # === LIBRARY ===
    library_ground: {
      hallway_style: :lobby_entry,
      hallway: { name: 'Reading Room', x: 0.0, y: 0.0, w: 1.0, h: 0.5 },
      rooms: [
        { name: 'Stacks', type: 'commercial', x: 0.0, y: 0.5, w: 0.6, h: 0.5 },
        { name: 'Reference', type: 'commercial', x: 0.6, y: 0.5, w: 0.4, h: 0.5 }
      ]
    }
  }.freeze

  # Maps building_type + floor_number to a template key
  TEMPLATE_MAP = {
    house:           { 0 => :house_ground, :default => :house_upper },
    brownstone:      { 0 => :brownstone_ground, :default => :brownstone_upper },
    terrace:         { 0 => :terrace_ground, :default => :terrace_upper },
    townhouse:       { 0 => :terrace_ground, :default => :terrace_upper },
    apartment_tower: { 0 => :apartment_lobby, :default => :apartment_floor },
    office_tower:    { 0 => :apartment_lobby, :default => :office_floor },
    hotel:           { 0 => :hotel_lobby, :default => :hotel_floor },
    church:          { 0 => :church_ground },
    temple:          { 0 => :church_ground },
    school:          { 0 => :school_ground, :default => :school_floor },
    hospital:        { 0 => :hospital_ground, :default => :hospital_floor },
    clinic:          { 0 => :hospital_ground },
    shop:            { 0 => :shop_single, :default => :shop_upper },
    cafe:            { 0 => :bar_single },
    bar:             { 0 => :bar_single, :default => :bar_upper },
    restaurant:      { 0 => :restaurant_single, :default => :restaurant_upper },
    cinema:          { 0 => :cinema_ground },
    gym:             { 0 => :gym_ground },
    mall:            { :default => :mall_floor },
    police_station:  { 0 => :police_ground },
    fire_station:    { 0 => :fire_ground },
    parking_garage:  { :default => :parking_floor },
    library:         { 0 => :library_ground }
  }.freeze

  class << self
    # Generate a floor plan for a building floor.
    #
    # @param building_bounds [Hash] { min_x:, max_x:, min_y:, max_y: }
    # @param floor_number [Integer] 0-based floor number
    # @param building_type [Symbol, nil] building type for template lookup
    # @param room_list [Array<Hash>, nil] override rooms (for AI-generated buildings)
    #   Each hash: { name: 'Kitchen', type: 'residence' }
    # @return [Array<Hash>] room definitions with :name, :room_type, :bounds, :is_hallway
    def generate(building_bounds:, floor_number:, building_type: nil, room_list: nil)
      min_z = floor_number * FLOOR_HEIGHT
      max_z = min_z + FLOOR_HEIGHT

      # Try template first
      template = template_for(building_type, floor_number) unless room_list

      if template
        apply_template(template, building_bounds, min_z, max_z)
      elsif room_list && !room_list.empty?
        # BSP subdivision for arbitrary room lists
        bsp_layout(building_bounds, room_list, min_z, max_z)
      else
        # Fallback: single room filling the floor
        [{
          name: "Floor #{floor_number + 1}",
          room_type: 'standard',
          bounds: building_bounds.merge(min_z: min_z, max_z: max_z),
          is_hallway: false
        }]
      end
    end

    # Look up the template for a building type and floor.
    #
    # @param building_type [Symbol, nil]
    # @param floor_number [Integer]
    # @return [Hash, nil] template definition or nil
    def template_for(building_type, floor_number)
      return nil unless building_type

      type_map = TEMPLATE_MAP[building_type.to_sym]
      return nil unless type_map

      key = type_map[floor_number] || type_map[:default]
      return nil unless key

      TEMPLATES[key]
    end

    private

    # Apply a proportional template to concrete building bounds.
    #
    # @param template [Hash] template with :hallway and :rooms
    # @param bounds [Hash] building bounds { min_x:, max_x:, min_y:, max_y: }
    # @param min_z [Integer] floor Z min
    # @param max_z [Integer] floor Z max
    # @return [Array<Hash>] concrete room definitions
    def apply_template(template, bounds, min_z, max_z)
      floor_w = bounds[:max_x] - bounds[:min_x]
      floor_h = bounds[:max_y] - bounds[:min_y]
      result = []

      # Add hallway if defined
      if template[:hallway]
        h = template[:hallway]
        result << {
          name: h[:name] || 'Hallway',
          room_type: 'hallway',
          bounds: scale_rect(h, bounds, floor_w, floor_h, min_z, max_z),
          is_hallway: true
        }
      end

      # Add rooms
      (template[:rooms] || []).each do |room|
        result << {
          name: room[:name],
          room_type: room[:type] || 'standard',
          bounds: scale_rect(room, bounds, floor_w, floor_h, min_z, max_z),
          is_hallway: false
        }
      end

      result
    end

    # Scale a proportional rectangle to concrete coordinates.
    def scale_rect(rect, bounds, floor_w, floor_h, min_z, max_z)
      {
        min_x: (bounds[:min_x] + rect[:x] * floor_w).round,
        max_x: (bounds[:min_x] + (rect[:x] + rect[:w]) * floor_w).round,
        min_y: (bounds[:min_y] + rect[:y] * floor_h).round,
        max_y: (bounds[:min_y] + (rect[:y] + rect[:h]) * floor_h).round,
        min_z: min_z,
        max_z: max_z
      }
    end

    # BSP subdivision for arbitrary room lists.
    # Reserves space for a central corridor, then subdivides remaining space.
    #
    # @param bounds [Hash] building bounds
    # @param room_list [Array<Hash>] rooms to place
    # @param min_z [Integer]
    # @param max_z [Integer]
    # @return [Array<Hash>]
    def bsp_layout(bounds, room_list, min_z, max_z)
      floor_w = bounds[:max_x] - bounds[:min_x]
      floor_h = bounds[:max_y] - bounds[:min_y]
      result = []

      # For narrow buildings (< 30ft), skip corridor and just stack rooms vertically
      if floor_w < 30
        cells = bsp_subdivide(bounds, room_list.length)
        room_list.each_with_index do |room, i|
          cell = cells[i] || cells.last
          result << {
            name: room[:name] || "Room #{i + 1}",
            room_type: room[:type] || 'standard',
            bounds: cell.merge(min_z: min_z, max_z: max_z),
            is_hallway: false
          }
        end
        return result
      end

      # Reserve 20% width for central corridor
      corridor_w = (floor_w * 0.2).round.clamp(10, 40)
      corridor_x = bounds[:min_x] + ((floor_w - corridor_w) / 2.0).round

      result << {
        name: 'Corridor',
        room_type: 'hallway',
        bounds: {
          min_x: corridor_x,
          max_x: corridor_x + corridor_w,
          min_y: bounds[:min_y],
          max_y: bounds[:max_y],
          min_z: min_z,
          max_z: max_z
        },
        is_hallway: true
      }

      # Interleave rooms between left and right sides for balanced distribution
      left_rooms = []
      right_rooms = []
      room_list.each_with_index do |room, i|
        if i.even?
          left_rooms << room
        else
          right_rooms << room
        end
      end

      # Left side bounds
      left_bounds = {
        min_x: bounds[:min_x],
        max_x: corridor_x,
        min_y: bounds[:min_y],
        max_y: bounds[:max_y]
      }

      # Right side bounds
      right_bounds = {
        min_x: corridor_x + corridor_w,
        max_x: bounds[:max_x],
        min_y: bounds[:min_y],
        max_y: bounds[:max_y]
      }

      # BSP subdivide each side
      left_cells = bsp_subdivide(left_bounds, left_rooms.length)
      right_cells = bsp_subdivide(right_bounds, right_rooms.length)

      left_rooms.each_with_index do |room, i|
        cell = left_cells[i] || left_cells.last
        result << {
          name: room[:name] || "Room #{i + 1}",
          room_type: room[:type] || 'standard',
          bounds: cell.merge(min_z: min_z, max_z: max_z),
          is_hallway: false
        }
      end

      right_rooms.each_with_index do |room, i|
        cell = right_cells[i] || right_cells.last
        result << {
          name: room[:name] || "Room #{left_rooms.length + i + 1}",
          room_type: room[:type] || 'standard',
          bounds: cell.merge(min_z: min_z, max_z: max_z),
          is_hallway: false
        }
      end

      result
    end

    # Recursively subdivide a rectangular area into N cells.
    #
    # @param bounds [Hash] { min_x:, max_x:, min_y:, max_y: }
    # @param target_count [Integer] number of cells needed
    # @return [Array<Hash>] array of cell bounds
    def bsp_subdivide(bounds, target_count)
      w = bounds[:max_x] - bounds[:min_x]
      h = bounds[:max_y] - bounds[:min_y]

      return [bounds] if target_count <= 1 || w < 10 || h < 10

      # Split along the longer axis
      if w >= h
        split = bounds[:min_x] + (w * 0.5).round
        left = { min_x: bounds[:min_x], max_x: split, min_y: bounds[:min_y], max_y: bounds[:max_y] }
        right = { min_x: split, max_x: bounds[:max_x], min_y: bounds[:min_y], max_y: bounds[:max_y] }
      else
        split = bounds[:min_y] + (h * 0.5).round
        left = { min_x: bounds[:min_x], max_x: bounds[:max_x], min_y: bounds[:min_y], max_y: split }
        right = { min_x: bounds[:min_x], max_x: bounds[:max_x], min_y: split, max_y: bounds[:max_y] }
      end

      left_count = (target_count / 2.0).ceil
      right_count = target_count - left_count

      bsp_subdivide(left, left_count) + bsp_subdivide(right, right_count)
    end
  end
end
