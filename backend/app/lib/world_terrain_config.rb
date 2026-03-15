# frozen_string_literal: true

# Canonical terrain color definitions for world map rendering.
# Used by SVG builders, zone maps, world region models, and texture services.
module WorldTerrainConfig
  TERRAIN_COLORS = {
    # Water - natural blues, less navy
    'ocean' => '#2d5f8a',
    'lake' => '#4a8ab5',
    # Coastal - warm naturals
    'rocky_coast' => '#8a8a7d',
    'sandy_coast' => '#d4c9a8',
    # Plains - muted sage, not neon green
    'grassy_plains' => '#a8b878',
    'rocky_plains' => '#b0a88a',
    # Forest - natural greens
    'light_forest' => '#6d9a52',
    'dense_forest' => '#3a6632',
    'jungle' => '#2d5a2d',
    # Wetland
    'swamp' => '#5a6b48',
    # Mountains/Hills - warm earthy tones
    'mountain' => '#8a7d6b',
    'grassy_hills' => '#96a07a',
    'rocky_hills' => '#9a8d78',
    # Cold
    'tundra' => '#c8d5d8',
    # Arid - muted sandy tan
    'desert' => '#c8b48a',
    # Volcanic
    'volcanic' => '#4a2828',
    # Urban - lighter grays like Google Maps
    'urban' => '#7a7a7a',
    'light_urban' => '#9a9a9a',
    # Fallback
    'unknown' => '#4a4a4a'
  }.freeze
end
