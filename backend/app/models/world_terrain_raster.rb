# frozen_string_literal: true

# WorldTerrainRaster caches pre-rendered terrain textures for fast globe display.
#
# For worlds with millions of hexes, texture generation can take 10-20 seconds.
# This model stores the generated PNG so subsequent loads are near-instant.
#
# The cache is automatically invalidated when:
# - The world's updated_at changes (hexes were modified)
# - The resolution changes
# - The cache is manually cleared
#
# Usage:
#   # Get or generate texture (returns PNG binary data)
#   png_data = WorldTerrainRaster.terrain_texture(world)
#
#   # Force regeneration
#   png_data = WorldTerrainRaster.terrain_texture(world, force: true)
#
#   # Cache texture after generation
#   WorldTerrainRaster.cache_texture(world, png_data)
#
class WorldTerrainRaster < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :world

  # Default texture resolution
  DEFAULT_WIDTH = 4096
  DEFAULT_HEIGHT = 2048

  def validate
    super
    validates_presence [:world_id, :resolution_x, :resolution_y]
    validates_integer :resolution_x
    validates_integer :resolution_y
  end

  # Check if the cached texture is still valid.
  #
  # @return [Boolean] true if cache is valid
  def valid_cache?
    return false unless png_data
    return false unless generated_at

    # Check if world has been modified since generation
    if world_modified_at && world.updated_at
      return false if world.updated_at > world_modified_at
    end

    true
  end

  class << self
    # Get texture for a world, using cache if valid.
    #
    # @param world [World] The world to get texture for
    # @param width [Integer] Texture width (default 4096)
    # @param height [Integer] Texture height (default 2048)
    # @param force [Boolean] Force regeneration
    # @return [String, nil] PNG binary data or nil on failure
    def terrain_texture(world, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT, force: false)
      raster = find_or_create(
        world_id: world.id,
        resolution_x: width,
        resolution_y: height
      )

      # Return cached texture if valid
      if !force && raster.valid_cache?
        return raster.png_data
      end

      # Generate new texture
      png_data = TerrainTextureService.new(world).generate
      return nil unless png_data

      # Update cache
      raster.update(
        png_data: Sequel.blob(png_data),
        generated_at: Time.now,
        hex_count: WorldHex.where(world_id: world.id).count,
        source_type: determine_source_type(world),
        world_modified_at: world.updated_at
      )

      png_data
    rescue StandardError => e
      warn "[WorldTerrainRaster] Error getting texture: #{e.message}"
      nil
    end

    # Cache a pre-generated texture.
    #
    # @param world [World] The world
    # @param png_data [String] PNG binary data
    # @param width [Integer] Texture width
    # @param height [Integer] Texture height
    # @return [WorldTerrainRaster] The raster record
    def cache_texture(world, png_data, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT)
      raster = find_or_create(
        world_id: world.id,
        resolution_x: width,
        resolution_y: height
      )

      raster.update(
        png_data: Sequel.blob(png_data),
        generated_at: Time.now,
        hex_count: WorldHex.where(world_id: world.id).count,
        source_type: determine_source_type(world),
        world_modified_at: world.updated_at
      )

      raster
    rescue StandardError => e
      warn "[WorldTerrainRaster] Error caching texture: #{e.message}"
      nil
    end

    # Invalidate texture cache for a world.
    #
    # @param world [World] The world
    def invalidate(world)
      where(world_id: world.id).update(png_data: nil, generated_at: nil)
    end

    private

    # Determine how the texture was generated.
    #
    # @param world [World] The world
    # @return [String] Source type
    def determine_source_type(world)
      hex_count = WorldHex.where(world_id: world.id).count
      region_count = WorldRegion.where(world_id: world.id, zoom_level: 3).count

      if region_count.positive? && hex_count > 100_000
        'regions'
      elsif hex_count.positive?
        'hexes'
      else
        'empty'
      end
    end
  end

  # API representation
  def to_api_hash
    {
      id: id,
      world_id: world_id,
      resolution: "#{resolution_x}x#{resolution_y}",
      generated_at: generated_at,
      hex_count: hex_count,
      source_type: source_type,
      has_texture: !png_data.nil?,
      texture_size: png_data&.bytesize
    }
  end
end
