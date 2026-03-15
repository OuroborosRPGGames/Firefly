# frozen_string_literal: true

# Usage: bundle exec ruby scripts/generate_battle_map_templates.rb [shape_key] [--clean]
#
# Generates AI battlemap templates for delve room shapes.
# Pass a specific shape_key to generate just that shape, or no args for all.
# Pass --clean to clear existing battlemaps from rooms 90, 141, 155.

require_relative '../app'

# Handle --clean flag
if ARGV.include?('--clean')
  [90, 141, 155].each do |id|
    room = Room[id]
    next unless room

    room.clear_battle_map! if room.battle_map_ready?
    room.update(
      battle_map_water_mask_url: nil,
      battle_map_foliage_mask_url: nil,
      battle_map_fire_mask_url: nil
    )
    puts "Cleared battlemap from room #{id} (#{room.name})"
  end
end

INTER_SHAPE_PAUSE = 10 # seconds to wait between shapes so Replicate isn't saturated

all_shapes = %w[rect_vertical rect_horizontal small_chamber large_chamber]
target = ARGV.reject { |a| a.start_with?('--') }.first
shapes = target && all_shapes.include?(target) ? [target] : all_shapes

# Each shape runs in its own subprocess to avoid libvips cache/memory corruption
# that occurs when many large images are processed in a single long-lived process.
script = File.expand_path(__FILE__)

if target
  # Single-shape mode: generate directly in this process
  require_relative '../app'
  puts "Generating template for delve/#{target}..."
  template = BattleMapTemplateService.generate_template!(category: 'delve', shape_key: target, variant: 0)
  if template
    puts "  OK: #{template.hex_data.size} hexes, image: #{template.image_url}"
  else
    puts "  FAILED"
  end
else
  # Multi-shape mode: spawn a fresh process per shape
  shapes.each_with_index do |shape_key, idx|
    if idx > 0
      puts "  Pausing #{INTER_SHAPE_PAUSE}s before next shape to let Replicate free up..."
      sleep INTER_SHAPE_PAUSE
    end

    puts "Generating template for delve/#{shape_key}..."
    success = system("bundle exec ruby #{script} #{shape_key}")
    puts "  Process exited with error" unless success
  end

  require_relative '../app'
  puts "\nDone. #{BattleMapTemplate.where(category: 'delve').count} delve templates total."
end
