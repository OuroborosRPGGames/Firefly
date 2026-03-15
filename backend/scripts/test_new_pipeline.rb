#!/usr/bin/env ruby
# frozen_string_literal: true

require "vips"
ENV["RACK_ENV"] = "development"
require_relative "../app"

room = Room[155]
image_path = "public/uploads/generated/2026/03/5e721dbf5928c2bf7eae43cd_pretrim.webp"

puts "Analyzing #{room.name} with new pipeline..."
svc = AIBattleMapGeneratorService.new(room, debug: true)
result = svc.reanalyze(image_path)

puts "Success: #{result[:success]}"
puts "Hex count: #{result[:hex_count]}"
puts "Error: #{result[:error]}" unless result[:success]

if result[:hex_data]
  types = result[:hex_data].group_by { |h| h[:_simple_type] || h[:hex_type] }
                           .transform_values(&:length)
                           .sort_by { |_, c| -c }
  puts "\nType breakdown:"
  types.each { |t, c| puts "  #{t}: #{c}" }

  traversable = result[:hex_data].count { |h| h[:traversable] != false }
  walls = result[:hex_data].count { |h| h[:hex_type] == 'wall' }
  puts "\nTraversable: #{traversable}/#{result[:hex_count]}"
  puts "Walls: #{walls}"

  # Generate debug overlay
  base = Vips::Image.new_from_file(image_path)
  hex_coords = svc.send(:generate_hex_coordinates)
  min_x = hex_coords.map { |x, _| x }.min
  min_y = hex_coords.map { |_, y| y }.min
  hex_pixel_map = svc.send(:build_hex_pixel_map, hex_coords, min_x, min_y, base.width, base.height)
  hex_size = hex_pixel_map[:hex_size]

  coord_lookup = {}
  hex_pixel_map.each do |_label, info|
    next unless info.is_a?(Hash) && info[:hx]
    coord_lookup[[info[:hx], info[:hy]]] = info
  end

  colors = {
    'wall' => 'rgba(100,100,100,0.5)', 'fire' => 'rgba(255,80,0,0.5)',
    'furniture' => 'rgba(139,90,43,0.5)', 'water' => 'rgba(0,100,255,0.5)',
    'cover' => 'rgba(180,130,50,0.5)', 'door' => 'rgba(0,200,0,0.5)',
    'stairs' => 'rgba(200,200,0,0.5)', 'normal' => 'rgba(200,0,200,0.3)',
    'difficult' => 'rgba(150,100,50,0.4)', 'debris' => 'rgba(130,100,80,0.4)',
    'window' => 'rgba(150,200,255,0.5)', 'pit' => 'rgba(50,0,0,0.5)'
  }

  svg_parts = [%(<svg xmlns="http://www.w3.org/2000/svg" width="#{base.width}" height="#{base.height}">)]
  result[:hex_data].each do |h|
    next if h[:hex_type] == 'normal' && (h[:elevation_level] || 0) == 0
    info = coord_lookup[[h[:x], h[:y]]]
    next unless info

    fill = colors[h[:hex_type]] || 'rgba(200,200,0,0.4)'
    pts = (0..5).map { |i| a = Math::PI / 3 * i; "#{(info[:px] + hex_size * 0.9 * Math.cos(a)).round},#{(info[:py] + hex_size * 0.9 * Math.sin(a)).round}" }.join(' ')
    svg_parts << %(<polygon points="#{pts}" fill="#{fill}" stroke="white" stroke-width="1"/>)

    fs = (hex_size * 0.2).round
    simple = h[:_simple_type] || h[:hex_type]
    svg_parts << %(<text x="#{info[:px].round}" y="#{(info[:py] + fs * 0.35).round}" text-anchor="middle" fill="white" stroke="black" stroke-width="2" font-size="#{fs}" font-family="sans-serif" font-weight="bold">#{simple}</text>)
  end
  svg_parts << '</svg>'

  overlay = Vips::Image.svgload_buffer(svg_parts.join("\n"))
  overlay = overlay.resize(base.width.to_f / overlay.width) if overlay.width != base.width
  img = base.bands < 4 ? base.bandjoin(255) : base
  overlay = overlay.colourspace(:srgb) if overlay.interpretation != :srgb
  out = img.composite2(overlay, :over)
  out.write_to_file("/tmp/new_pipeline_overlay.png")
  puts "\nOverlay saved to /tmp/new_pipeline_overlay.png"
end
