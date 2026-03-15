# frozen_string_literal: true

# Seeds the 4 delve battle map templates from exported data.
# Templates are pre-generated and include hex data + image/mask files.

require 'json'

puts 'Seeding battle map templates...'

data_dir = File.join(__dir__, 'data')

templates = [
  {
    category: 'delve',
    shape_key: 'large_chamber',
    variant: 0,
    width_feet: 26.0,
    height_feet: 26.0,
    description_hint: 'A large dungeon hall with thick stone pillars supporting a vaulted ceiling, torches burning in iron brackets along the walls, a shallow underground stream cutting across the chamber floor, ominous atmosphere with ancient carvings on the walls',
    image_url: '/uploads/generated/templates/large_chamber.webp',
    wall_mask_url: '/uploads/battle_maps/template_large_chamber_wall_mask.png',
    water_mask_url: '/uploads/battle_maps/template_large_chamber_sam_water.png',
    foliage_mask_url: nil,
    fire_mask_url: '/uploads/battle_maps/template_large_chamber_sam_fire.png'
  },
  {
    category: 'delve',
    shape_key: 'rect_vertical',
    variant: 0,
    width_feet: 12.0,
    height_feet: 24.0,
    description_hint: 'A narrow stone dungeon corridor running north to south, rough-hewn walls with flickering torches mounted in iron brackets, cracked flagstone floor with scattered gravel and dust, open stone archway entrances at both the north and south ends',
    image_url: '/uploads/generated/templates/rect_vertical.webp',
    wall_mask_url: '/uploads/battle_maps/template_rect_vertical_wall_mask.png',
    water_mask_url: nil,
    foliage_mask_url: nil,
    fire_mask_url: nil
  },
  {
    category: 'delve',
    shape_key: 'rect_horizontal',
    variant: 0,
    width_feet: 24.0,
    height_feet: 12.0,
    description_hint: 'A narrow stone dungeon passage running east to west, ancient mortared walls with iron-bracketed torches every few feet, worn stone floor with scattered gravel, open stone archway entrances at both the east and west ends',
    image_url: '/uploads/generated/templates/rect_horizontal.webp',
    wall_mask_url: '/uploads/battle_maps/template_rect_horizontal_wall_mask.png',
    water_mask_url: nil,
    foliage_mask_url: nil,
    fire_mask_url: '/uploads/battle_maps/template_rect_horizontal_sam_fire.png'
  },
  {
    category: 'delve',
    shape_key: 'small_chamber',
    variant: 0,
    width_feet: 18.0,
    height_feet: 18.0,
    description_hint: 'A small dungeon chamber with rough stone walls, torches flickering in wall sconces, scattered rubble and debris on the flagstone floor',
    image_url: '/uploads/generated/templates/small_chamber.webp',
    wall_mask_url: '/uploads/battle_maps/template_small_chamber_wall_mask.png',
    water_mask_url: nil,
    foliage_mask_url: nil,
    fire_mask_url: nil
  }
]

templates.each do |tmpl|
  existing = DB[:battle_map_templates].where(
    category: tmpl[:category],
    shape_key: tmpl[:shape_key],
    variant: tmpl[:variant]
  ).first

  next if existing

  hex_file = File.join(data_dir, "template_#{tmpl[:shape_key]}_hex_data.json")
  hex_data = File.exist?(hex_file) ? Sequel.pg_jsonb_wrap(JSON.parse(File.read(hex_file))) : nil

  light_file = File.join(data_dir, "template_#{tmpl[:shape_key]}_light_sources.json")
  light_sources = File.exist?(light_file) ? Sequel.pg_jsonb_wrap(JSON.parse(File.read(light_file))) : Sequel.pg_jsonb_wrap([])

  DB[:battle_map_templates].insert(
    tmpl.merge(
      hex_data: hex_data,
      light_sources: light_sources,
      ai_object_metadata: Sequel.pg_jsonb_wrap({}),
      created_at: Time.now
    )
  )
  puts "  Created template: #{tmpl[:shape_key]}"
end

puts 'Battle map templates seeded.'
