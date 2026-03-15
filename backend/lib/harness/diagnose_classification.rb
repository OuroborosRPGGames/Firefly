# frozen_string_literal: true

# Diagnostic script: compare raw LLM classifier output vs current DB state for a room's battle map.
#
# Usage:
#   cd backend && bundle exec ruby tmp/diagnose_classification.rb [room_id]
#   Default room_id: 155

require_relative '../app'

ROOM_ID = (ARGV[0] || 155).to_i

room = Room[ROOM_ID]
abort "Room #{ROOM_ID} not found" unless room
abort "Room #{ROOM_ID} has no battle map image" unless room.battle_map_image_url

image_path = "public/#{room.battle_map_image_url}"
abort "Image not found: #{image_path}" unless File.exist?(image_path)

puts "=== Battle Map Classification Diagnostics ==="
puts "Room: #{ROOM_ID} (#{room.name})"
puts "Image: #{image_path}"
puts

# --- Current DB state ---
db_hexes = RoomHex.where(room_id: ROOM_ID).all
db_dist = db_hexes.group_by(&:hex_type).transform_values(&:length).sort_by { |_, v| -v }.to_h
db_total = db_hexes.length

puts "--- Current DB State (#{db_total} hexes) ---"
db_dist.each { |type, count| puts "  %-20s %4d  (%5.1f%%)" % [type, count, 100.0 * count / db_total] }
puts

# --- Raw classifier output (debug mode, no normalization) ---
puts "--- Running raw classification (debug=true, no normalization) ---"
puts "This may take a minute..."
puts

service = AIBattleMapGeneratorService.new(room, debug: true)
result = service.reanalyze(image_path)

unless result[:success]
  abort "Reanalyze failed: #{result[:error]}"
end

raw_hexes = result[:hex_data]
raw_total = raw_hexes.length

# Raw results use :hex_type key
raw_dist = raw_hexes.group_by { |h| h[:hex_type] }.transform_values(&:length).sort_by { |_, v| -v }.to_h

puts "--- Raw Classifier Output (#{raw_total} hexes, no normalization) ---"
raw_dist.each { |type, count| puts "  %-20s %4d  (%5.1f%%)" % [type, count, 100.0 * count / raw_total] }
puts

# --- Side-by-side comparison ---
all_types = (db_dist.keys + raw_dist.keys).uniq.sort
puts "--- Side-by-Side Comparison ---"
puts "  %-20s %6s %6s %8s" % ['Type', 'Raw', 'DB', 'Delta']
puts "  " + "-" * 44

all_types.each do |type|
  raw_count = raw_dist[type] || 0
  db_count = db_dist[type] || 0
  delta = db_count - raw_count
  delta_str = delta == 0 ? '' : (delta > 0 ? "+#{delta}" : delta.to_s)
  puts "  %-20s %6d %6d %8s" % [type, raw_count, db_count, delta_str]
end
puts

# --- Diagnosis ---
puts "--- Diagnosis ---"
wall_raw = raw_dist['wall'] || 0
wall_db = db_dist['wall'] || 0
if wall_db > wall_raw
  puts "  WALLS: DB has #{wall_db - wall_raw} more walls than raw classifier → normalization is promoting walls"
elsif wall_db < wall_raw
  puts "  WALLS: DB has #{wall_raw - wall_db} fewer walls than raw classifier → normalization is removing walls"
else
  puts "  WALLS: Same count in raw and DB → wall issues come from classifier, not normalization"
end

# Check for types that appear only in one
raw_only = raw_dist.keys - db_dist.keys
db_only = db_dist.keys - raw_dist.keys
puts "  Types in raw only: #{raw_only.join(', ')}" if raw_only.any?
puts "  Types in DB only: #{db_only.join(', ')}" if db_only.any?

# Overall open floor comparison
floor_raw = raw_dist.fetch('normal', 0) + raw_dist.fetch('open_floor', 0)
floor_db = db_dist.fetch('normal', 0) + db_dist.fetch('open_floor', 0)
puts "  FLOOR: raw=#{floor_raw} vs DB=#{floor_db} (delta: #{floor_db - floor_raw})"
puts
puts "If raw classifier already has bad types → fix the LLM prompt/chunking"
puts "If raw is good but DB is bad → fix the normalization pipeline"
