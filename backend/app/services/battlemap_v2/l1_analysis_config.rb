# frozen_string_literal: true

module BattlemapV2
  # Shared L1 prompt/schema and light source constants used by both
  # AIBattleMapGeneratorService and BattlemapV2::PipelineService.
  module L1AnalysisConfig
    STANDARD_FEATURE_TYPES = %w[
      treetrunk treebranch shrubbery boulder mud snow ice
      puddle wading_water deep_water table chair bench fire log
      glass_window open_window barrel balcony staircase ladder door archway
      rubble pillar crate chest wagon tent pit cliff ledge bridge fence gate
    ].freeze

    LIGHT_SOURCE_TYPES = %w[fire torch candle gaslamp electric_light magical_light].freeze

    LIGHT_COLORS = {
      'fire' => [1.0, 0.7, 0.3],
      'torch' => [1.0, 0.75, 0.4],
      'candle' => [1.0, 0.85, 0.5],
      'gaslamp' => [1.0, 0.8, 0.45],
      'electric_light' => [0.95, 0.95, 1.0],
      'magical_light' => [0.5, 0.7, 1.0]
    }.freeze
    LIGHT_COLOR_DEFAULT = [1.0, 0.9, 0.8].freeze

    LIGHT_INTENSITIES = {
      'candle' => 0.5,
      'electric_light' => 1.0
    }.freeze
    LIGHT_INTENSITY_DEFAULT = 0.8

    def self.l1_prompt(grid_n = 3)
      total_squares = grid_n * grid_n
      GamePrompts.get(
        'battle_maps.grid.l1_analysis',
        grid_n: grid_n,
        total_squares: total_squares,
        standard_feature_types: STANDARD_FEATURE_TYPES.join(', ')
      )
    end

    def self.l1_schema
      {
        type: 'OBJECT',
        properties: {
          scene_description: { type: 'STRING' },
          has_perimeter_wall: { type: 'BOOLEAN', description: 'Does this map have an outer perimeter wall enclosing the space? FALSE for open terrain (forest, field, street), TRUE for rooms/buildings with visible boundary walls.' },
          has_inner_walls: { type: 'BOOLEAN', description: 'Are there interior partition walls INSIDE the space dividing it into sub-rooms or corridors? Do NOT count the outer perimeter wall. TRUE only if you can see structural walls that divide the interior.' },
          wall_visual: { type: 'STRING', description: 'Brief description of what walls look like on this map (color, material, texture)' },
          floor_visual: { type: 'STRING', description: 'Brief description of what the floor looks like (color, material, texture)' },
          lighting_direction: { type: 'STRING', description: 'Direction shadows are cast (e.g. "shadows fall to the southeast") or "no visible shadows"' },
          standard_types_present: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                type_name: { type: 'STRING' },
                visual_description: { type: 'STRING', description: 'What this type looks like on this specific map (color, shape, material)' },
                short_description: { type: 'STRING', description: '2-4 word visual phrase for image segmentation (e.g. "dark wooden table", "grey stone pillar")' }
              },
              required: %w[type_name visual_description short_description]
            },
            description: 'Standard types visible on this map, each with a visual description'
          },
          custom_types: {
            type: 'ARRAY',
            description: 'Custom types are ALWAYS traversable. If something blocks movement, use wall instead.',
            items: {
              type: 'OBJECT',
              properties: {
                type_name: { type: 'STRING' },
                visual_description: { type: 'STRING' },
                short_description: { type: 'STRING', description: '2-4 word visual phrase for image segmentation (e.g. "iron-banded barrel", "stone forge pit")' },
                provides_cover: { type: 'BOOLEAN', description: 'Does this provide cover from ranged attacks?' },
                is_exit: { type: 'BOOLEAN', description: 'Is this a door, gate, or passage?' },
                difficult_terrain: { type: 'BOOLEAN', description: 'Does this slow movement?' },
                elevation: { type: 'INTEGER', description: 'Height in feet above floor (0 for floor-level objects)' },
                hazards: { type: 'ARRAY', items: { type: 'STRING' }, description: 'Hazard types if any: fire, acid, cold, lightning, poison, necrotic, radiant, psychic, thunder, force' }
              },
              required: %w[type_name visual_description short_description provides_cover is_exit difficult_terrain elevation hazards]
            }
          },
          light_sources: {
            type: 'ARRAY',
            description: 'Light-emitting objects visible on the map. Do NOT include windows or ambient light.',
            items: {
              type: 'OBJECT',
              properties: {
                source_type: { type: 'STRING', enum: LIGHT_SOURCE_TYPES, description: 'fire=campfire/fireplace/brazier, torch=wall sconce/torch, candle=candle/candelabra, gaslamp=oil lamp/lantern/streetlamp, electric_light=fluorescent/spotlight, magical_light=glowing crystal/rune/orb' },
                description: { type: 'STRING', description: 'What it looks like (e.g. "iron wall sconce with flame", "candelabra on table")' },
                short_description: { type: 'STRING', description: '2-4 word visual phrase for image segmentation (e.g. "iron wall sconce", "stone hearth fire")' },
                squares: { type: 'ARRAY', items: { type: 'INTEGER' }, description: 'Which grid squares (1-9) contain this light source' }
              },
              required: %w[source_type description short_description squares]
            }
          },
          squares: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                square: { type: 'INTEGER' },
                description: { type: 'STRING' },
                has_walls: { type: 'BOOLEAN' },
                wall_description: { type: 'STRING' },
                has_interior_walls: { type: 'BOOLEAN' },
                interior_wall_description: { type: 'STRING' },
                objects: {
                  type: 'ARRAY',
                  items: {
                    type: 'OBJECT',
                    properties: {
                      type: { type: 'STRING' },
                      count: { type: 'INTEGER' },
                      location: { type: 'STRING' }
                    },
                    required: %w[type count location]
                  }
                }
              },
              required: %w[square description has_walls wall_description has_interior_walls interior_wall_description objects]
            }
          },
          perimeter_wall_doors: {
            type: 'ARRAY',
            description: 'Directions where doors, archways, or openings exist in the outer perimeter wall. May be incomplete — only include directions you are confident about.',
            items: { type: 'STRING', enum: %w[n s e w nw ne sw se] }
          },
          internal_walls: {
            type: 'ARRAY',
            description: 'Interior partition walls that divide the space. Only include walls you can clearly see. May be incomplete.',
            items: {
              type: 'OBJECT',
              properties: {
                location: { type: 'STRING', enum: %w[n s e w nw ne sw se center], description: 'Which part of the room this wall is in' },
                has_door: { type: 'BOOLEAN', description: 'Does this interior wall have a door or opening?' },
                door_side: { type: 'STRING', enum: %w[n s e w nw ne sw se none], description: 'Which side of the wall the door is on, or "none" if no door' }
              },
              required: %w[location has_door door_side]
            }
          }
        },
        required: %w[scene_description has_perimeter_wall has_inner_walls wall_visual floor_visual lighting_direction standard_types_present custom_types light_sources squares perimeter_wall_doors internal_walls]
      }
    end
  end
end
