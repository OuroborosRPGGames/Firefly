#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate all gallery entries in parallel.
# Usage: cd backend && bundle exec ruby scripts/test_gallery_generate_all.rb

require_relative '../app'

total = BattleMapTestGalleryService::TEST_CONFIGS.size
puts "Generating #{total} gallery entries (max #{BattleMapTestGalleryService::MAX_CONCURRENT_MAPS} concurrent)"

mutex = Mutex.new
output = {}

threads = total.times.map do |i|
  Thread.new do
    svc = BattleMapTestGalleryService.new
    config = BattleMapTestGalleryService::TEST_CONFIGS[i]
    label = config[:label] || "Entry #{i}"

    t0 = Time.now
    result = svc.generate_image(i)
    elapsed = (Time.now - t0).round(1)

    mutex.synchronize do
      if result[:success]
        output[i] = "  [#{i + 1}/#{total}] #{label}: OK (#{elapsed}s) — model=#{result[:model_used]}"
      else
        output[i] = "  [#{i + 1}/#{total}] #{label}: FAILED (#{elapsed}s) — #{result[:error]}"
      end
    end
  end
end

threads.each { |t| t.join(600) }

successes = 0
total.times do |i|
  puts output[i]
  successes += 1 if output[i]&.include?('OK')
end

puts "Done! #{successes}/#{total} succeeded."
