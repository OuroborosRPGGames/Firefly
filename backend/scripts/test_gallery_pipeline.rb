#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate and classify specific gallery entries through the full pipeline.
# Run: cd backend && bundle exec ruby scripts/test_gallery_pipeline.rb
#
# Default: generates indices 0 (tavern), 1 (forest), 2 (cave)
# Custom:  bundle exec ruby scripts/test_gallery_pipeline.rb 0 1 2
#
# Approaches:
#   --simple    Use Approach A (simple enum + "other" fallback)
#   --overview  Use Approach B (overview pre-pass + constrained enum) [default]
#   --legacy    Use legacy v3 classification (property-per-hex)

require_relative '../app'

approach = if ARGV.delete('--simple')
             :simple
           elsif ARGV.delete('--legacy')
             :legacy
           else
             ARGV.delete('--overview')
             :overview
           end

indices = if ARGV.any?
            ARGV.map(&:to_i)
          else
            [0, 1, 2]
          end

puts "Pipeline: approach=#{approach}"

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
    lines = []
    lines << "\n=== ##{idx}: #{config[:label]} (#{config[:width]}x#{config[:height]}ft) ==="

    # Step 1: Generate image (includes resize + upscale + label)
    t0 = Time.now
    result = svc.generate_image(idx)
    elapsed = (Time.now - t0).round(1)

    if result[:success]
      lines << "  Generated (#{elapsed}s) — model=#{result[:model_used]}"
    else
      lines << "  Generate FAILED (#{elapsed}s): #{result[:error]}"
      mutex.synchronize { output[idx] = lines.join("\n") }
      next
    end

    # Step 2: Classify hexes
    t0 = Time.now
    classify_result = case approach
                      when :simple
                        svc.classify_hexes_simple(idx)
                      when :overview
                        svc.classify_hexes_overview(idx)
                      else
                        svc.classify_hexes(idx)
                      end
    elapsed = (Time.now - t0).round(1)

    if classify_result[:success]
      extra = classify_result[:approach] ? " approach=#{classify_result[:approach]}" : ''
      lines << "  Classified (#{elapsed}s) — #{classify_result[:count]} hexes, model=#{classify_result[:model]}#{extra}"

      data = svc.load_results[idx.to_s]
      hexes = data['hex_classifications'] || []

      # Show hex_type breakdown if available
      if hexes.any? { |h| h['hex_type'] }
        type_counts = hexes.select { |h| h['hex_type'] }.group_by { |h| h['hex_type'] }.transform_values(&:count).sort_by { |_, v| -v }
        lines << "    Types: #{type_counts.map { |t, c| "#{t}=#{c}" }.join(', ')}"
      else
        lines << "    Walls: #{hexes.count { |h| h['is_wall'] }}"
        lines << "    Cover: #{hexes.count { |h| h['provides_cover'] }}"
        lines << "    Concealment: #{hexes.count { |h| h['provides_concealment'] }}"
        lines << "    Off-map: #{hexes.count { |h| h['is_off_map'] }}"
      end

      lines << "    Chunks: #{(data['chunk_urls'] || []).length}"

      if data['overview_data']
        lines << "    Overview types: #{(data['overview_data']['present_types'] || []).map { |t| t['type_name'] }.join(', ')}"
      end
      lines << "    Other count: #{data['other_count']}" if data['other_count'] && data['other_count'] > 0
    else
      lines << "  Classify FAILED (#{elapsed}s): #{classify_result[:error]}"
    end

    mutex.synchronize { output[idx] = lines.join("\n") }
  end
end

threads.each { |t| t.join(600) }

indices.sort.each { |idx| puts output[idx] if output[idx] }
puts "\nDone!"
