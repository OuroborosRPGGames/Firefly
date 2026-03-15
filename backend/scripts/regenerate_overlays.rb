# Regenerate classified overlay images from existing results data.
# Run: bundle exec ruby scripts/regenerate_overlays.rb

require_relative '../app'

svc = BattleMapTestGalleryService.new
results = svc.send(:load_results)

def url_to_path(url)
  return nil unless url
  url.start_with?('/') ? "public#{url}" : "public/#{url}"
end

[0, 1, 2].each do |i|
  data = results[i.to_s]
  next unless data && data['success']

  room = Room[data['room_id']]
  unless room
    warn "No room for ##{i}"
    next
  end

  generator = AIBattleMapGeneratorService.new(room)
  hex_coords = generator.send(:custom_hex_coords_for_room, BattleMapTestGalleryService::GALLERY_HEX_SIZE_FEET)
  labeled_path = url_to_path(data['labeled_url'])
  unless labeled_path && File.exist?(labeled_path)
    warn "No labeled image for ##{i}: #{labeled_path}"
    next
  end
  warn "##{i}: room=#{room.id} hexes=#{hex_coords.length} labeled=#{labeled_path}"

  %w[overview simple].each do |approach|
    adata = data[approach]
    next unless adata && adata['hex_classifications']&.any?

    warn "  #{approach}: #{adata['hex_classifications'].length} classifications"
    path = svc.send(:generate_classified_overlay, labeled_path, room, adata['hex_classifications'], generator, hex_coords, suffix: "classified_#{approach}")
    warn "  -> #{path || 'FAILED'}"
  end

  if data['hex_classifications']&.any?
    warn "  legacy: #{data['hex_classifications'].length} classifications"
    path = svc.send(:generate_classified_overlay, labeled_path, room, data['hex_classifications'], generator, hex_coords, suffix: 'classified')
    warn "  -> #{path || 'FAILED'}"
  end
end

warn 'All done!'
