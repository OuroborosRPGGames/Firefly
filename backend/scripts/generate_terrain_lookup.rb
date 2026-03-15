# frozen_string_literal: true

# Generate terrain lookup binary for Earth import.
# Creates a bitmap that maps lat/lon to terrain type indices.
#
# Usage: ruby scripts/generate_terrain_lookup.rb

require 'fileutils'

OUTPUT_PATH = File.join(__dir__, '../data/terrain_lookup.bin')

# Define terrain indices based on WorldHex::TERRAIN_TYPES
TERRAIN_INDICES = {
  'ocean' => 0,
  'lake' => 1,
  'rocky_coast' => 2,
  'sandy_coast' => 3,
  'grassy_plains' => 4,
  'rocky_plains' => 5,
  'light_forest' => 6,
  'dense_forest' => 7,
  'jungle' => 8,
  'swamp' => 9,
  'mountain' => 10,
  'grassy_hills' => 11,
  'rocky_hills' => 12,
  'tundra' => 13,
  'desert' => 14,
  'volcanic' => 15,
  'urban' => 16,
  'light_urban' => 17
}.freeze

# Grid parameters - 0.25 degree resolution
LAT_MIN = -90.0
LAT_MAX = 90.0
LON_MIN = -180.0
LON_MAX = 180.0
RESOLUTION = 0.25

ROWS = ((LAT_MAX - LAT_MIN) / RESOLUTION).to_i  # 720
COLS = ((LON_MAX - LON_MIN) / RESOLUTION).to_i  # 1440

# Classify terrain based on latitude and longitude using biome rules.
# This is a simplified classifier that provides realistic Earth terrain.
def classify_terrain(lat, lon)
  abs_lat = lat.abs

  # Polar regions (high latitudes)
  return TERRAIN_INDICES['tundra'] if abs_lat > 66.0

  # Determine base biome by latitude zone and longitude

  # Arctic/subarctic (50-66 degrees)
  if abs_lat > 50.0
    # Taiga/boreal forest dominates high latitudes
    return TERRAIN_INDICES['dense_forest'] if longitude_in_taiga?(lat, lon)
    return TERRAIN_INDICES['rocky_plains']
  end

  # Temperate (23.5-50 degrees)
  if abs_lat > 23.5
    return desert_zone?(lat, lon) ? TERRAIN_INDICES['desert'] : temperate_biome(lat, lon)
  end

  # Tropical (0-23.5 degrees)
  tropical_biome(lat, lon)
end

# Check if coordinate is in major taiga/boreal regions
def longitude_in_taiga?(lat, lon)
  # Northern hemisphere taiga (Canada, Russia, Scandinavia)
  return true if lat > 45 && ((lon > -170 && lon < -60) || (lon > 15 && lon < 180))
  false
end

# Check if coordinate is in major desert zones
def desert_zone?(lat, lon)
  abs_lat = lat.abs

  # Sahara Desert (North Africa)
  return true if lat > 15 && lat < 35 && lon > -20 && lon < 35

  # Arabian Desert
  return true if lat > 15 && lat < 35 && lon > 35 && lon < 60

  # Gobi Desert (Mongolia/China)
  return true if lat > 38 && lat < 48 && lon > 90 && lon < 120

  # Great Basin/Mojave (Western US)
  return true if lat > 32 && lat < 42 && lon > -120 && lon < -104

  # Australian deserts
  return true if lat < -18 && lat > -30 && lon > 115 && lon < 145

  # Atacama Desert (South America)
  return true if lat < -18 && lat > -28 && lon > -72 && lon < -68

  # Namib/Kalahari (Southern Africa)
  return true if lat < -15 && lat > -30 && lon > 12 && lon < 28

  # Patagonian steppe
  return true if lat < -38 && lat > -52 && lon > -72 && lon < -65

  false
end

# Determine temperate biome
def temperate_biome(lat, lon)
  # Major forest regions

  # Eastern North America forests
  if lat > 30 && lat < 50 && lon > -95 && lon < -65
    return rand < 0.7 ? TERRAIN_INDICES['dense_forest'] : TERRAIN_INDICES['light_forest']
  end

  # European forests
  if lat > 40 && lat < 55 && lon > -10 && lon < 45
    return rand < 0.6 ? TERRAIN_INDICES['dense_forest'] : TERRAIN_INDICES['light_forest']
  end

  # East Asian forests
  if lat > 25 && lat < 50 && lon > 100 && lon < 145
    return rand < 0.5 ? TERRAIN_INDICES['dense_forest'] : TERRAIN_INDICES['light_forest']
  end

  # Pacific Northwest
  if lat > 42 && lat < 60 && lon > -128 && lon < -118
    return TERRAIN_INDICES['dense_forest']
  end

  # New Zealand
  if lat < -34 && lat > -47 && lon > 166 && lon < 179
    return rand < 0.7 ? TERRAIN_INDICES['dense_forest'] : TERRAIN_INDICES['grassy_plains']
  end

  # Default to grasslands for temperate areas
  rand < 0.4 ? TERRAIN_INDICES['light_forest'] : TERRAIN_INDICES['grassy_plains']
end

# Determine tropical biome
def tropical_biome(lat, lon)
  # Amazon rainforest
  if lat > -15 && lat < 5 && lon > -80 && lon < -45
    return TERRAIN_INDICES['jungle']
  end

  # Congo rainforest
  if lat > -10 && lat < 5 && lon > 10 && lon < 30
    return TERRAIN_INDICES['jungle']
  end

  # Southeast Asian rainforests
  if lat > -8 && lat < 10 && lon > 95 && lon < 150
    return rand < 0.8 ? TERRAIN_INDICES['jungle'] : TERRAIN_INDICES['dense_forest']
  end

  # Central American rainforest
  if lat > 5 && lat < 20 && lon > -92 && lon < -78
    return rand < 0.7 ? TERRAIN_INDICES['jungle'] : TERRAIN_INDICES['dense_forest']
  end

  # Indian subcontinent
  if lat > 8 && lat < 25 && lon > 68 && lon < 90
    return rand < 0.5 ? TERRAIN_INDICES['dense_forest'] : TERRAIN_INDICES['grassy_plains']
  end

  # Tropical swamps
  if lat > -5 && lat < 5 && ((lon > -65 && lon < -55) || (lon > 105 && lon < 115))
    return TERRAIN_INDICES['swamp']
  end

  # African savanna
  if lat > -20 && lat < 15 && lon > -20 && lon < 45
    return rand < 0.6 ? TERRAIN_INDICES['grassy_plains'] : TERRAIN_INDICES['light_forest']
  end

  # Default tropical - mix of forest and grassland
  rand < 0.4 ? TERRAIN_INDICES['light_forest'] : TERRAIN_INDICES['grassy_plains']
end

# Generate the lookup binary
puts "Generating terrain lookup: #{ROWS}x#{COLS} (#{ROWS * COLS} pixels)"
puts "Resolution: #{RESOLUTION} degrees"
puts "Output: #{OUTPUT_PATH}"

# Ensure data directory exists
FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))

# Use deterministic randomness for reproducibility
srand(42)

data = []
total = ROWS * COLS
ROWS.times do |row|
  lat = LAT_MIN + (row + 0.5) * RESOLUTION
  COLS.times do |col|
    lon = LON_MIN + (col + 0.5) * RESOLUTION
    terrain_idx = classify_terrain(lat, lon)
    data << terrain_idx
  end

  # Progress update
  processed = (row + 1) * COLS
  if (row + 1) % 72 == 0
    pct = (processed * 100.0 / total).round(1)
    puts "Progress: #{pct}% (row #{row + 1}/#{ROWS})"
  end
end

File.open(OUTPUT_PATH, 'wb') do |f|
  # Header: magic number and version
  f.write([0x54455252, 1].pack('L<L<'))

  # Bounds and resolution (as 32-bit floats)
  f.write([LAT_MIN, LAT_MAX, LON_MIN, LON_MAX, RESOLUTION].pack('eeeee'))

  # Dimensions
  f.write([ROWS, COLS].pack('L<L<'))

  # Terrain data (one byte per pixel)
  f.write(data.pack('C*'))
end

puts "Done! Generated #{File.size(OUTPUT_PATH)} bytes"
puts "Terrain lookup saved to: #{OUTPUT_PATH}"
