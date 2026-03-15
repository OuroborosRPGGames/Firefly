#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-run trim → resize → Crystal upscale → label → chunk for existing gallery entries.
# Does NOT regenerate images or re-classify — just reprocesses the pipeline steps.
#
# Run: cd backend && bundle exec ruby scripts/reprocess_gallery.rb
# Custom: bundle exec ruby scripts/reprocess_gallery.rb 0 1 2

require_relative '../app'

indices = if ARGV.any?
            ARGV.map(&:to_i)
          else
            [0, 1, 2]
          end

puts "Reprocessing #{indices.size} entries in parallel"

mutex = Mutex.new
output = {}

threads = indices.map do |idx|
  Thread.new do
    config = BattleMapTestGalleryService::TEST_CONFIGS[idx]
    unless config
      mutex.synchronize { output[idx] = "  ##{idx}: INVALID INDEX (max #{BattleMapTestGalleryService::TEST_CONFIGS.length - 1})" }
      next
    end

    svc = BattleMapTestGalleryService.new
    data = svc.load_results[idx.to_s]
    unless data && data['success']
      mutex.synchronize { output[idx] = "  ##{idx}: No successful result to reprocess" }
      next
    end

    room = Room[data['room_id']]
    unless room
      mutex.synchronize { output[idx] = "  ##{idx}: Room #{data['room_id']} not found" }
      next
    end

    image_url = data['image_url']
    image_path = image_url.start_with?('/') ? "public#{image_url}" : "public/#{image_url}"
    unless File.exist?(image_path)
      mutex.synchronize { output[idx] = "  ##{idx}: Image file missing: #{image_path}" }
      next
    end

    lines = []
    lines << "\n=== ##{idx}: #{config[:label]} (#{config[:width]}x#{config[:height]}ft) ==="
    lines << "  Source: #{image_path} (#{(File.size(image_path) / 1024.0).round}KB)"

    # Step 1: Trim → Resize → Crystal Upscale → Label
    t0 = Time.now
    result = svc.send(:resize_and_label, image_path, room)
    elapsed = (Time.now - t0).round(1)

    unless result
      lines << "  Processing FAILED (#{elapsed}s)"
      mutex.synchronize { output[idx] = lines.join("\n") }
      next
    end

    lines << "  Processed (#{elapsed}s)"
    lines << "    Resized:  #{result[:resized]} (#{(File.size(result[:resized]) / 1024.0).round}KB)"
    lines << "    Upscaled: #{result[:upscaled]} (#{(File.size(result[:upscaled]) / 1024.0).round}KB)"
    lines << "    Labeled:  #{result[:labeled]} (#{(File.size(result[:labeled]) / 1024.0).round}KB)"

    # Update results with new URLs
    data['resized_url'] = result[:resized].sub(/^public/, '')
    data['upscaled_url'] = result[:upscaled].sub(/^public/, '')
    data['labeled_url'] = result[:labeled].sub(/^public/, '')

    # Step 2: Build chunks (without classification)
    t0 = Time.now
    require 'vips'
    base = Vips::Image.new_from_file(result[:upscaled])
    img_w = base.width
    img_h = base.height

    generator = AIBattleMapGeneratorService.new(room)
    hex_coords = generator.send(:custom_hex_coords_for_room, BattleMapTestGalleryService::GALLERY_HEX_SIZE_FEET)
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min

    hex_pixel_map = svc.send(:build_hex_pixel_map, hex_coords, generator, min_x, min_y, img_w, img_h, hex_coords)

    svc.instance_variable_set(:@coord_lookup, {})
    hex_pixel_map.each do |_label, info|
      next unless info.is_a?(Hash) && info[:hx]
      svc.instance_variable_get(:@coord_lookup)[[info[:hx], info[:hy]]] = info
    end

    chunks = svc.send(:build_spatial_chunks, hex_coords, BattleMapTestGalleryService::CHUNK_SIZE)
    chunk_urls = []

    chunks.each_with_index do |chunk, chunk_idx|
      crop_result = svc.send(:crop_image_for_chunk, base, chunk, hex_pixel_map, img_w, img_h)
      labeled_crop = svc.send(:overlay_chunk_labels, crop_result, chunk, generator, min_x, min_y, hex_coords, hex_pixel_map)
      chunk_path = File.join(BattleMapTestGalleryService::RESULTS_DIR, "chunk_#{idx}_#{chunk_idx}.png")
      File.binwrite(chunk_path, labeled_crop)
      chunk_urls << { 'index' => chunk_idx, 'url' => "/uploads/battle_map_tests/chunk_#{idx}_#{chunk_idx}.png" }
    end

    elapsed = (Time.now - t0).round(1)
    lines << "  Chunks (#{elapsed}s) — #{chunks.length} chunks, #{hex_coords.length} hexes"

    data['chunk_urls'] = chunk_urls.sort_by { |c| c['index'] }
    svc.send(:save_result, idx, data)
    lines << "  Results saved."

    mutex.synchronize { output[idx] = lines.join("\n") }
  end
end

threads.each { |t| t.join(600) }

indices.sort.each { |idx| puts output[idx] if output[idx] }
puts "\nDone! View at /admin/battle_maps/test_gallery"
