#!/usr/bin/env ruby
# frozen_string_literal: true

# Seed pet patterns based on the Python reference
#
# Usage:
#   cd backend && bundle exec ruby scripts/seed_pet_patterns.rb
#

require_relative '../config/application'

# Pet type definitions from the Python reference
PET_TYPES = {
  'tiny_elephant' => {
    type_name: 'Tiny Elephant',
    description: 'a tiny eight-inch tall elephant',
    sounds: 'trumpets softly, flaps its ears',
    source_id: 15_300
  },
  'tiny_trex' => {
    type_name: 'Tiny T-Rex',
    description: 'a cat-sized tyrannosaurus rex',
    sounds: 'chirps, growls playfully',
    source_id: 15_301
  },
  'sprite' => {
    type_name: 'Sprite',
    description: 'a small glowing fae-sprite with gossamer wings',
    sounds: 'chimes, twinkles',
    source_id: 15_302
  },
  'imp' => {
    type_name: 'Imp',
    description: 'a small red-skinned imp with bat-like wings',
    sounds: 'cackles, chittering',
    source_id: 15_303
  },
  'marionette_cat' => {
    type_name: 'Marionette Cat',
    description: 'a jointed wooden marionette cat without strings',
    sounds: 'clicks, creaks warmly',
    source_id: 15_304
  },
  'bonsai' => {
    type_name: 'Bonsai',
    description: 'a tiny animated bonsai tree with root-feet',
    sounds: 'rustles its leaves',
    source_id: 15_305
  },
  'winged_unicorn' => {
    type_name: 'Winged Unicorn',
    description: 'a sparrow-sized unicorn with iridescent wings',
    sounds: 'whinnies softly, flutters',
    source_id: 15_306
  },
  'plant_cat' => {
    type_name: 'Plant Cat',
    description: 'a cat made of living vines and flowers',
    sounds: 'purrs with rustling leaves',
    source_id: 15_307
  },
  'glass_lizard' => {
    type_name: 'Glass Lizard',
    description: 'a crystalline lizard with prismatic colors',
    sounds: 'chimes, clicks',
    source_id: 15_308
  },
  'baby_griffon' => {
    type_name: 'Baby Griffon',
    description: 'a fluffy cat-sized baby griffon',
    sounds: 'chirps, trills',
    source_id: 15_309
  },
  'winged_snake' => {
    type_name: 'Winged Snake',
    description: 'a small winged serpent with soft plumage',
    sounds: 'hisses softly, rustles feathers',
    source_id: 15_310
  },
  'clockwork_hummingbird' => {
    type_name: 'Clockwork Hummingbird',
    description: 'a tiny mechanical hummingbird of copper and brass',
    sounds: 'whirs, clicks, buzzes',
    source_id: 15_311
  },
  'spectral_wolf' => {
    type_name: 'Spectral Wolf',
    description: 'a translucent ghostly wolf pup',
    sounds: 'howls faintly, whimpers',
    source_id: 15_312
  },
  'dragonling' => {
    type_name: 'Dragonling',
    description: 'a kitten-sized dragon',
    sounds: 'chirps, puffs tiny smoke rings',
    source_id: 15_313
  }
}.freeze

def create_or_update_pet_unified_type(key, data)
  existing = UnifiedObjectType.first(source_table: 'ptypes', source_id: data[:source_id])

  if existing
    existing.update(
      name: data[:type_name],
      category: 'pet',
      subcategory: 'magical'
    )
    puts "  Updated unified object type: #{data[:type_name]}"
    existing
  else
    type = UnifiedObjectType.create(
      name: data[:type_name],
      category: 'pet',
      subcategory: 'magical',
      source_table: 'ptypes',
      source_id: data[:source_id]
    )
    puts "  Created unified object type: #{data[:type_name]}"
    type
  end
end

def create_or_update_pet_pattern(key, data, unified_type)
  existing = Pattern.first(source_table: 'ppatterns', source_id: data[:source_id])

  if existing
    existing.update(
      description: "a #{data[:type_name]}",
      is_pet: true,
      pet_type_name: data[:type_name],
      pet_description: data[:description],
      pet_sounds: data[:sounds],
      unified_object_type_id: unified_type.id
    )
    puts "  Updated pattern: #{data[:type_name]}"
    existing
  else
    pattern = Pattern.create(
      description: "a #{data[:type_name]}",
      source_table: 'ppatterns',
      source_id: data[:source_id],
      is_pet: true,
      pet_type_name: data[:type_name],
      pet_description: data[:description],
      pet_sounds: data[:sounds],
      unified_object_type_id: unified_type.id
    )
    puts "  Created pattern: #{data[:type_name]}"
    pattern
  end
end

def main
  puts 'Seeding pet patterns...'
  puts

  created_types = 0
  created_patterns = 0

  PET_TYPES.each do |key, data|
    puts "Processing: #{data[:type_name]}"

    # Create or update unified object type
    unified_type = create_or_update_pet_unified_type(key, data)
    created_types += 1

    # Create or update pattern
    create_or_update_pet_pattern(key, data, unified_type)
    created_patterns += 1
  end

  puts
  puts "Done! Processed #{created_types} types and #{created_patterns} patterns."
  puts
  puts 'To create a pet instance:'
  puts '  pattern = Pattern.pets.first'
  puts '  pet = pattern.instantiate(name: "Fluffy", character_instance: char_instance)'
  puts '  pet.update(is_pet_instance: true, held: true)'
end

if __FILE__ == $PROGRAM_NAME
  main
end
