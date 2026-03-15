# frozen_string_literal: true

module BattlemapV2
  # Shared hex type mapping used by both AIBattleMapGeneratorService (legacy)
  # and the V2 pipeline (HexOverlayService). Maps type names from LLM analysis
  # to RoomHex attribute hashes.
  #
  # When updating this mapping, ensure both pipelines stay consistent.
  module HexTypeMapping
    SIMPLE_TYPE_TO_ROOM_HEX = {
      'treetrunk'     => { hex_type: 'cover', cover_object: 'tree', traversable: false },
      'treebranch'    => { hex_type: 'cover', cover_object: 'tree' },
      'shrubbery'     => { hex_type: 'concealed', difficult_terrain: true },
      'boulder'       => { hex_type: 'cover', cover_object: 'boulder', has_cover: true, traversable: false },
      'mud'           => { hex_type: 'difficult', difficult_terrain: true },
      'snow'          => { hex_type: 'difficult', difficult_terrain: true },
      'ice'           => { hex_type: 'difficult', difficult_terrain: true },
      'puddle'        => { hex_type: 'water', water_type: 'puddle' },
      'wading_water'  => { hex_type: 'water', water_type: 'wading', difficult_terrain: true },
      'deep_water'    => { hex_type: 'water', water_type: 'deep', traversable: false },
      'table'         => { hex_type: 'furniture', cover_object: 'table', has_cover: true, elevation_level: 3 },
      'chair'         => { hex_type: 'furniture', cover_object: 'chair', has_cover: false, elevation_level: 2, difficult_terrain: true },
      'bench'         => { hex_type: 'furniture', has_cover: false, elevation_level: 2, difficult_terrain: true },
      'fire'          => { hex_type: 'fire', hazard_type: 'fire', danger_level: 3 },
      'log'           => { hex_type: 'cover', cover_object: 'log', has_cover: true, difficult_terrain: true },
      'wall'          => { hex_type: 'wall', traversable: false },
      'glass_window'  => { hex_type: 'window', traversable: false },
      'open_window'   => { hex_type: 'window', traversable: false },
      'barrel'        => { hex_type: 'cover', cover_object: 'barrel', has_cover: true, elevation_level: 4, difficult_terrain: true },
      'balcony'       => { hex_type: 'normal', elevation_level: 4 },
      'staircase'     => { hex_type: 'stairs', is_stairs: true, elevation_level: 2 },
      'ladder'        => { hex_type: 'stairs', is_ladder: true, elevation_level: 2 },
      'door'          => { hex_type: 'door' },
      'archway'       => { hex_type: 'door' },
      'gate'          => { hex_type: 'door' },
      'rubble'        => { hex_type: 'debris', difficult_terrain: true },
      'pillar'        => { hex_type: 'cover', cover_object: 'pillar', has_cover: true, traversable: false },
      'crate'         => { hex_type: 'cover', cover_object: 'crate', has_cover: true, elevation_level: 4, difficult_terrain: true },
      'chest'         => { hex_type: 'furniture', elevation_level: 2 },
      'wagon'         => { hex_type: 'cover', cover_object: 'debris', has_cover: true, traversable: false },
      'tent'          => { hex_type: 'normal' },
      'pit'           => { hex_type: 'pit', traversable: false, elevation_level: -6, hazard_type: 'physical', danger_level: 3 },
      'cliff'         => { hex_type: 'wall', traversable: false },
      'ledge'         => { hex_type: 'normal', elevation_level: 2 },
      'bridge'        => { hex_type: 'normal', elevation_level: 2 },
      'fence'         => { hex_type: 'cover', cover_object: 'wall_low', has_cover: true, difficult_terrain: true },
      'off_map'       => { hex_type: 'wall', traversable: false },
      'open_floor'    => { hex_type: 'normal' },
      'other'         => { hex_type: 'normal' }
    }.freeze
  end
end
