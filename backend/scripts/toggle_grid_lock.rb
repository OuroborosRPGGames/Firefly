#!/usr/bin/env ruby
# frozen_string_literal: true

# Toggle grid lock on a world. When locked, replaces full 42M-row indexes
# with traversable-only partial indexes (~600x smaller, fits in RAM).
#
# Usage:
#   bundle exec ruby scripts/toggle_grid_lock.rb WORLD_ID lock
#   bundle exec ruby scripts/toggle_grid_lock.rb WORLD_ID unlock
#   bundle exec ruby scripts/toggle_grid_lock.rb WORLD_ID status

$stdout.sync = true

require_relative '../app'

world_id = ARGV[0]&.to_i
action = ARGV[1]&.downcase
abort "Usage: #{$0} WORLD_ID [lock|unlock|status]" unless world_id && %w[lock unlock status].include?(action)

world = World[world_id]
abort "World #{world_id} not found" unless world

DB.run("SET statement_timeout = '0'")

# Index definitions
FULL_INDEXES = {
  'world_hexes_world_lat_lon_idx' => <<~SQL,
    CREATE INDEX CONCURRENTLY world_hexes_world_lat_lon_idx
    ON world_hexes (world_id, latitude, longitude)
  SQL
  'idx_world_hexes_h3_index' => <<~SQL
    CREATE INDEX CONCURRENTLY idx_world_hexes_h3_index
    ON world_hexes (h3_index) WHERE h3_index IS NOT NULL
  SQL
}.freeze

LOCKED_INDEXES = {
  'world_hexes_world_lat_lon_idx' => <<~SQL,
    CREATE INDEX CONCURRENTLY world_hexes_world_lat_lon_idx
    ON world_hexes (world_id, latitude, longitude)
    WHERE traversable = true
  SQL
  'idx_world_hexes_h3_index' => <<~SQL
    CREATE INDEX CONCURRENTLY idx_world_hexes_h3_index
    ON world_hexes (h3_index)
    WHERE h3_index IS NOT NULL AND traversable = true
  SQL
}.freeze

def show_index_sizes
  sizes = DB.fetch(<<~SQL).all
    SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) as size
    FROM pg_indexes WHERE tablename='world_hexes'
    ORDER BY pg_relation_size(indexname::regclass) DESC
  SQL
  total = DB.fetch(<<~SQL).first[:total]
    SELECT pg_size_pretty(sum(pg_relation_size(indexname::regclass))) as total
    FROM pg_indexes WHERE tablename='world_hexes'
  SQL
  sizes.each { |r| puts "  #{r[:indexname]}: #{r[:size]}" }
  puts "  Total: #{total}"
end

case action
when 'status'
  puts "World: #{world.name} (ID: #{world_id})"
  puts "Grid locked: #{world.grid_locked}"
  puts "Indexes:"
  show_index_sizes

when 'lock'
  if world.grid_locked
    puts "World #{world_id} is already locked"
    exit
  end

  traversable_count = WorldHex.where(world_id: world_id, traversable: true).count
  total_count = WorldHex.where(world_id: world_id).count
  puts "World: #{world.name} (ID: #{world_id})"
  puts "Total hexes: #{total_count}, Traversable: #{traversable_count}"
  puts "Before:"
  show_index_sizes

  # Swap each index: drop full, create partial
  FULL_INDEXES.each_key do |idx_name|
    puts "\nSwapping #{idx_name}..."
    puts "  Dropping full index..."
    DB.run("DROP INDEX CONCURRENTLY IF EXISTS #{idx_name}")
    puts "  Creating traversable-only index..."
    DB.run(LOCKED_INDEXES[idx_name])
    puts "  Done"
  end

  # Refresh LOD views to only include traversable hexes
  puts "\nRefreshing LOD materialized views..."
  %w[world_hexes_lod3 world_hexes_lod4 world_hexes_lod5].each do |view|
    puts "  Refreshing #{view}..."
    DB.run("REFRESH MATERIALIZED VIEW #{view}")
  end

  world.update(grid_locked: true)
  puts "\nAfter:"
  show_index_sizes
  puts "\nGrid LOCKED. World builder will only show traversable hexes."

when 'unlock'
  unless world.grid_locked
    puts "World #{world_id} is not locked"
    exit
  end

  puts "World: #{world.name} (ID: #{world_id})"
  puts "Before:"
  show_index_sizes

  # Swap each index: drop partial, create full
  LOCKED_INDEXES.each_key do |idx_name|
    puts "\nSwapping #{idx_name}..."
    puts "  Dropping partial index..."
    DB.run("DROP INDEX CONCURRENTLY IF EXISTS #{idx_name}")
    puts "  Creating full index..."
    DB.run(FULL_INDEXES[idx_name])
    puts "  Done"
  end

  # Refresh LOD views to include all hexes
  puts "\nRefreshing LOD materialized views..."
  %w[world_hexes_lod3 world_hexes_lod4 world_hexes_lod5].each do |view|
    puts "  Refreshing #{view}..."
    DB.run("REFRESH MATERIALIZED VIEW #{view}")
  end

  world.update(grid_locked: false)
  puts "\nAfter:"
  show_index_sizes
  puts "\nGrid UNLOCKED. Full indexes restored for world builder."
end
