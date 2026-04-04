#!/usr/bin/env ruby
# frozen_string_literal: true

# Batch backfill h3_index for all world hexes using h3-pg SQL functions.
# Much faster than Ruby-level computation (~10-30 min for 42M rows).
#
# Usage:
#   bundle exec ruby scripts/backfill_h3_indexes.rb WORLD_ID
#   bundle exec ruby scripts/backfill_h3_indexes.rb WORLD_ID --refresh-views

$stdout.sync = true

require_relative '../app'

world_id = ARGV[0]&.to_i
refresh_views = ARGV.include?('--refresh-views')
abort "Usage: #{$0} WORLD_ID [--refresh-views]" unless world_id

world = World[world_id]
abort "World #{world_id} not found" unless world

DB.run("SET statement_timeout = '0'")

total = WorldHex.where(world_id: world_id).count
already = WorldHex.where(world_id: world_id).exclude(h3_index: nil).count
remaining = total - already

puts "World: #{world.name} (ID: #{world_id})"
puts "Total hexes: #{total}, Already have h3_index: #{already}, Remaining: #{remaining}"

if remaining == 0
  puts "All hexes already have h3_index."
else
  batch_size = 100_000
  updated = 0
  start_time = Time.now

  loop do
    rows = DB.run(<<~SQL)
      UPDATE world_hexes
      SET h3_index = h3_latlng_to_cell(point(longitude, latitude), 7)::bigint
      WHERE id IN (
        SELECT id FROM world_hexes
        WHERE h3_index IS NULL
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL
          AND world_id = #{world_id}
        ORDER BY id
        LIMIT #{batch_size}
      )
    SQL

    # Check how many remain
    still_remaining = WorldHex.where(world_id: world_id, h3_index: nil)
      .where { latitude !~ nil }
      .count

    batch_done = remaining - still_remaining - updated
    updated = remaining - still_remaining

    elapsed = Time.now - start_time
    rate = updated > 0 ? (updated / elapsed).round : 0
    eta = rate > 0 ? ((still_remaining / rate.to_f) / 60).round(1) : '?'

    puts "  #{updated}/#{remaining} done (#{rate}/sec, ~#{eta} min remaining)"

    break if still_remaining == 0
  end

  elapsed = Time.now - start_time
  puts "Backfill complete: #{updated} hexes in #{elapsed.round(1)}s"
end

if refresh_views
  puts "\nRefreshing LOD materialized views..."

  %w[world_hexes_lod3 world_hexes_lod4 world_hexes_lod5].each do |view|
    puts "  Refreshing #{view}..."
    start = Time.now
    begin
      DB.run("REFRESH MATERIALIZED VIEW #{view}")
      puts "  #{view} refreshed in #{(Time.now - start).round(1)}s"
    rescue Sequel::DatabaseError => e
      warn "  #{view} refresh failed: #{e.message}"
    end
  end

  puts "LOD views refreshed."
end
