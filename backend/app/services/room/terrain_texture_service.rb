# frozen_string_literal: true

require 'tempfile'
require 'chunky_png'
require_relative '../../lib/world_terrain_config'

# TerrainTextureService generates an equirectangular PNG texture for globe rendering.
#
# Instead of rendering thousands of individual hex polygons (which causes GPU strain),
# this service pre-renders terrain to a single texture that Globe.gl can display
# efficiently using globeImageUrl.
#
# The texture uses equirectangular projection:
# - X axis: longitude (-180 to +180) maps to pixels 0 to WIDTH
# - Y axis: latitude (+90 to -90) maps to pixels 0 to HEIGHT
#
# Resolution is adaptive:
# - Target ~3M pixels max (2448x1224 for 2:1 aspect ratio)
# - For worlds with fewer hexes, scale down proportionally
# - For worlds with more hexes than pixels, use pixel-by-pixel sampling
#
# Usage:
#   world = World.find(id)
#   png_data = TerrainTextureService.new(world).generate
#   File.binwrite("texture.png", png_data)
#
class TerrainTextureService
  TERRAIN_COLORS = WorldTerrainConfig::TERRAIN_COLORS

  # Target texture resolution (2:1 aspect ratio for equirectangular)
  # ~3 million pixels = 2448x1224
  TARGET_PIXELS = 3_000_000
  MAX_WIDTH = 2448
  MAX_HEIGHT = 1224

  # Minimum texture dimensions for usable quality on 3D globe
  # Even small worlds need reasonable resolution when stretched over sphere
  MIN_WIDTH = 1024
  MIN_HEIGHT = 512


  # Default background color (black to distinguish "not loaded" from "ocean")
  BACKGROUND_COLOR = '#000000'

  attr_reader :world, :width, :height

  def initialize(world)
    @world = world
    @hex_count = nil
    @width = nil
    @height = nil
  end

  # Get cached hex count (uses extended timeout for large worlds)
  def hex_count
    @hex_count ||= begin
      DB.transaction do
        DB.run('SET LOCAL statement_timeout = 0')
        world.world_hexes_dataset.count
      end
    end
  end

  # Calculate adaptive texture dimensions based on hex count.
  # - For hex_count >= TARGET_PIXELS: use max dimensions
  # - For hex_count < TARGET_PIXELS: scale proportionally (1 pixel ≈ 1 hex)
  #
  # @return [Array<Integer>] [width, height]
  def calculate_dimensions
    return [@width, @height] if @width && @height

    count = hex_count

    if count <= 0
      @width = MIN_WIDTH
      @height = MIN_HEIGHT
    elsif count >= TARGET_PIXELS
      # Large world: use max dimensions
      @width = MAX_WIDTH
      @height = MAX_HEIGHT
    else
      # Scale proportionally: target roughly 1 pixel per hex
      # With 2:1 aspect ratio: width = sqrt(hex_count * 2), height = width / 2
      @width = Math.sqrt(count * 2).round
      @height = (@width / 2.0).round

      # Ensure minimum dimensions
      @width = [[@width, MIN_WIDTH].max, MAX_WIDTH].min
      @height = [[@height, MIN_HEIGHT].max, MAX_HEIGHT].min
    end

    [@width, @height]
  end

  # Generate the equirectangular texture as PNG binary data
  # @return [String] PNG binary data
  def generate
    count = hex_count
    calculate_dimensions

    if count.zero?
      return generate_ocean_texture
    end

    total_pixels = @width * @height
    warn "[TerrainTexture] Generating #{@width}x#{@height} texture (#{total_pixels} pixels) for #{hex_count} hexes"

    # Use ChunkyPNG for all rendering paths
    if chunky_png_available?
      require 'chunky_png'
      bg_color = color_to_chunky(BACKGROUND_COLOR)
      png = ChunkyPNG::Image.new(@width, @height, bg_color)

      if count > total_pixels
        # More hexes than pixels: sample nearest hex per pixel
        warn "[TerrainTexture] Using pixel-by-pixel sampling (#{count} hexes > #{total_pixels} pixels)"
        return generate_pixel_by_pixel(png)
      else
        # Fewer hexes than pixels: draw ellipses per hex
        warn "[TerrainTexture] Using ellipse rendering (#{count} hexes <= #{total_pixels} pixels)"
        return generate_from_hexes_chunky(png)
      end
    end

    # Fallback to ImageMagick for small worlds without ChunkyPNG
    hexes = load_hexes
    return generate_ocean_texture if hexes.empty?
    build_texture(hexes)
  end

  # Check if ChunkyPNG is available
  # @return [Boolean]
  def chunky_png_available?
    return @chunky_png_available if defined?(@chunky_png_available)

    @chunky_png_available = begin
      require 'chunky_png'
      true
    rescue LoadError
      false
    end
  end

  # Generate texture by sampling nearest hex for each pixel.
  # Used when hex count exceeds pixel count for accurate representation.
  #
  # @param png [ChunkyPNG::Image] Image to draw on
  # @return [String] PNG binary data
  def generate_pixel_by_pixel(png)
    hexes = load_hexes
    return png.to_blob if hexes.empty?

    # Build fine-grained spatial index for fast nearest-neighbor lookup
    # Use 0.5-degree buckets for ~20 hexes per bucket (vs ~2000 with 5-degree)
    # This makes the 3x3 bucket search check ~180 hexes instead of ~18,000
    bucket_size = 0.5
    hex_buckets = Hash.new { |h, k| h[k] = [] }

    hexes.each do |hex|
      next if hex.latitude.nil? || hex.longitude.nil?

      bucket_key = [
        (hex.latitude / bucket_size).floor,
        (hex.longitude / bucket_size).floor
      ]
      hex_buckets[bucket_key] << hex
    end

    avg_per_bucket = hexes.size.to_f / [hex_buckets.size, 1].max
    warn "[TerrainTexture] Built spatial index: #{hex_buckets.size} buckets, ~#{avg_per_bucket.round(1)} hexes/bucket"

    start_time = Time.now

    # Process each pixel
    @height.times do |y|
      @width.times do |x|
        # Convert pixel to lat/lon
        lat, lng = pixel_to_latlon(x, y)

        # Find bucket for this location
        bucket_lat = (lat / bucket_size).floor
        bucket_lng = (lng / bucket_size).floor

        # Search nearby buckets for nearest hex
        best_hex = nil
        best_dist_sq = Float::INFINITY

        # Check 3x3 grid of buckets
        (-1..1).each do |dlat|
          (-1..1).each do |dlng|
            candidates = hex_buckets[[bucket_lat + dlat, bucket_lng + dlng]]
            candidates.each do |hex|
              # Simple distance calculation (good enough for small differences)
              dlat_deg = hex.latitude - lat
              dlng_deg = hex.longitude - lng
              dist_sq = dlat_deg * dlat_deg + dlng_deg * dlng_deg

              if dist_sq < best_dist_sq
                best_dist_sq = dist_sq
                best_hex = hex
              end
            end
          end
        end

        # Set pixel color
        if best_hex
          png[x, y] = terrain_to_chunky(best_hex.terrain_type)
        end
      end

      # Progress logging every 64 rows (more frequent for large textures)
      if ((y + 1) % 64).zero?
        elapsed = Time.now - start_time
        pct = ((y + 1).to_f / @height * 100).round(1)
        eta = elapsed / (y + 1) * (@height - y - 1)
        warn "[TerrainTexture] Progress: #{y + 1}/#{@height} rows (#{pct}%) - ETA: #{eta.round(1)}s"
      end
    end

    elapsed = Time.now - start_time
    warn "[TerrainTexture] Pixel rendering complete in #{elapsed.round(1)}s"
    png.to_blob
  end

  # Generate texture from hexes using ChunkyPNG (medium path)
  # Used when regions aren't available but we still want fast PNG generation
  #
  # @param png [ChunkyPNG::Image] Image to draw on
  # @return [String] PNG binary data
  def generate_from_hexes_chunky(png)
    hexes = load_hexes
    return png.to_blob if hexes.empty?

    warn "[TerrainTexture] Rendering from #{hexes.size} hexes with ChunkyPNG"

    base_radius = calculate_hex_radius

    # Sort hexes by latitude - render from equator outward so polar hexes draw last
    # This ensures polar terrain doesn't get overwritten by lower-latitude hexes
    sorted_hexes = hexes.sort_by { |h| h.latitude&.abs || 0 }

    # Track terrain at each y-coordinate for polar gap filling
    terrain_by_row = {}  # y_pixel => { x_pixel => terrain_type }

    sorted_hexes.each do |hex|
      lat = hex.latitude
      lng = hex.longitude
      next if lat.nil? || lng.nil?

      px, py = latlon_to_pixel(lat, lng)
      color = terrain_to_chunky(hex.terrain_type)

      # Calculate latitude-corrected ellipse size
      # Near poles, cos(lat) approaches 0, so we need wider ellipses
      lat_scale = Math.cos(lat * Math::PI / 180.0).abs
      lat_scale = [lat_scale, 0.01].max  # Allow very wide ellipses near poles

      # For extreme polar latitudes (above 88°), use extra-wide ellipses
      # but still draw as ellipses (not destructive bands)
      if lat.abs > 88.0
        # At 89°, cos(89°) ≈ 0.017, so rx would be ~59x base_radius
        # Cap it at full width to ensure coverage without being excessive
        rx = @width / 2
      else
        rx = (base_radius / lat_scale).round.clamp(base_radius, @width / 2)
      end
      ry = base_radius

      draw_filled_ellipse(png, px, py, rx, ry, color)

      # Track terrain for gap filling (only for polar regions)
      if lat.abs > 80.0
        terrain_by_row[py] ||= {}
        terrain_by_row[py][px] = hex.terrain_type
      end
    end

    # Fill any remaining black gaps at the extreme poles
    # This only fills BACKGROUND color pixels, never overwrites terrain
    fill_polar_gaps(png, terrain_by_row, base_radius)

    png.to_blob
  end

  # Fill any remaining black gaps in the texture
  # Uses horizontal neighbor sampling to extend terrain into gaps
  # This handles the triangular corners in equirectangular projection
  def fill_polar_gaps(png, _terrain_by_row, _base_radius)
    bg_color = color_to_chunky(BACKGROUND_COLOR)

    # Fill ALL black pixels by scanning each row and extending terrain from edges
    # For the top half, scan left-to-right and right-to-left
    # For the bottom half, do the same

    (0...@height).each do |y|
      # Find the leftmost and rightmost non-black pixels on this row
      left_color = nil
      right_color = nil
      left_x = nil
      right_x = nil

      # Scan from left
      (0...@width).each do |x|
        if png[x, y] != bg_color
          left_color = png[x, y]
          left_x = x
          break
        end
      end

      # Scan from right
      (@width - 1).downto(0).each do |x|
        if png[x, y] != bg_color
          right_color = png[x, y]
          right_x = x
          break
        end
      end

      # If this row has no terrain at all, sample from adjacent rows
      if left_color.nil? && right_color.nil?
        # Try rows above and below
        sample_color = nil
        [1, 2, 3, 5, 8, 13].each do |offset|
          # Check row above
          if y - offset >= 0
            (0...@width).step(50).each do |sx|
              pixel = png[sx, y - offset]
              if pixel != bg_color
                sample_color = pixel
                break
              end
            end
          end
          break if sample_color

          # Check row below
          if y + offset < @height
            (0...@width).step(50).each do |sx|
              pixel = png[sx, y + offset]
              if pixel != bg_color
                sample_color = pixel
                break
              end
            end
          end
          break if sample_color
        end

        # Fill entire row with sampled color or tundra
        fill_color = sample_color || terrain_to_chunky('tundra')
        (0...@width).each do |x|
          png[x, y] = fill_color
        end
      else
        # Fill left gap (from x=0 to left_x) with left_color
        # But since equirectangular wraps, left gap should use right_color
        # and right gap should use left_color
        wrap_left_color = right_color || left_color
        wrap_right_color = left_color || right_color

        if left_x && left_x > 0
          (0...left_x).each do |x|
            png[x, y] = wrap_left_color if png[x, y] == bg_color
          end
        end

        # Fill right gap (from right_x to @width) with right_color
        if right_x && right_x < @width - 1
          ((right_x + 1)...@width).each do |x|
            png[x, y] = wrap_right_color if png[x, y] == bg_color
          end
        end
      end
    end
  end

  # Draw a filled ellipse on a ChunkyPNG image
  # Handles horizontal wrapping for polar regions where ellipses extend beyond texture edges
  #
  # @param png [ChunkyPNG::Image] Image to draw on
  # @param cx [Integer] Center X
  # @param cy [Integer] Center Y
  # @param rx [Integer] Horizontal radius
  # @param ry [Integer] Vertical radius
  # @param color [Integer] ChunkyPNG color
  def draw_filled_ellipse(png, cx, cy, rx, ry, color)
    (-ry..ry).each do |dy|
      # Calculate x bounds for this row of the ellipse
      # Using ellipse equation: (x/rx)² + (y/ry)² = 1
      # x = ±rx × √(1 - (y/ry)²)
      y_ratio = dy.to_f / ry
      next if y_ratio.abs > 1

      x_extent = (rx * Math.sqrt(1 - y_ratio * y_ratio)).round

      y = cy + dy
      next if y < 0 || y >= @height

      (-x_extent..x_extent).each do |dx|
        x = cx + dx

        # Handle horizontal wrapping for equirectangular projection
        # This is critical for polar regions where ellipses may extend beyond texture edges
        if x < 0
          x += @width  # Wrap from left edge to right edge
        elsif x >= @width
          x -= @width  # Wrap from right edge to left edge
        end

        next if x < 0 || x >= @width  # Safety check after wrapping

        png[x, y] = color
      end
    end
  end

  # Convert hex color string to ChunkyPNG color
  #
  # @param hex_color [String] Color like '#1e3a5f'
  # @return [Integer] ChunkyPNG color integer
  def color_to_chunky(hex_color)
    hex = hex_color.delete('#')
    r = hex[0..1].to_i(16)
    g = hex[2..3].to_i(16)
    b = hex[4..5].to_i(16)
    ChunkyPNG::Color.rgb(r, g, b)
  end

  # Convert terrain type to ChunkyPNG color
  #
  # @param terrain [String] Terrain type
  # @return [Integer] ChunkyPNG color integer
  def terrain_to_chunky(terrain)
    hex_color = WorldTerrainConfig::TERRAIN_COLORS[terrain] || WorldTerrainConfig::TERRAIN_COLORS['unknown']
    color_to_chunky(hex_color)
  end

  # Convert pixel coordinates to latitude/longitude (for globe hex lookup)
  # Equirectangular projection: pixel (x, y) -> (lat, lon)
  #
  # @param x [Integer] Pixel X coordinate (0 to @width-1)
  # @param y [Integer] Pixel Y coordinate (0 to @height-1)
  # @return [Array<Float>] [latitude, longitude] in degrees
  def pixel_to_latlon(x, y)
    # X: 0 to @width maps to -180 to +180 longitude
    lng = (x.to_f / @width) * 360.0 - 180.0

    # Y: 0 to @height maps to +90 to -90 latitude
    lat = 90.0 - (y.to_f / @height) * 180.0

    [lat, lng]
  end

  # Convert latitude/longitude to pixel coordinates
  # Equirectangular projection: (lat, lon) -> pixel (x, y)
  #
  # @param lat [Float] latitude (-90 to +90)
  # @param lng [Float] longitude (-180 to +180)
  # @return [Array<Integer>] [x, y] pixel coordinates
  def latlon_to_pixel(lat, lng)
    # Normalize longitude to -180..+180
    lng = ((lng + 180) % 360) - 180

    # X: longitude -180 to +180 maps to 0 to @width
    x = ((lng + 180.0) / 360.0 * @width).round

    # Y: latitude +90 to -90 maps to 0 to @height
    y = ((90.0 - lat) / 180.0 * @height).round

    [x.clamp(0, @width - 1), y.clamp(0, @height - 1)]
  end

  private

  # Load all hexes for this world with lat/lng coordinates
  # For large worlds, disable statement timeout to prevent query cancellation
  def load_hexes
    count = hex_count

    # For large worlds (>100K hexes), disable statement timeout within a transaction
    # SET LOCAL ensures the timeout change is scoped to this transaction only
    if count > 100_000
      warn "[TerrainTexture] Loading #{count} hexes with extended timeout..."
      result = DB.transaction do
        DB.run('SET LOCAL statement_timeout = 0')
        WorldHex.where(world_id: world.id)
                .exclude(latitude: nil)
                .exclude(longitude: nil)
                .select(:id, :latitude, :longitude, :terrain_type)
                .all
      end
      warn "[TerrainTexture] Loaded #{result.size} hexes"
      result
    else
      WorldHex.where(world_id: world.id)
              .exclude(latitude: nil)
              .exclude(longitude: nil)
              .select(:id, :latitude, :longitude, :terrain_type)
              .all
    end
  end

  # Generate a simple ocean texture when no hexes exist
  def generate_ocean_texture
    calculate_dimensions

    # Use ChunkyPNG if available (faster, no shell)
    if chunky_png_available?
      require 'chunky_png'
      bg_color = color_to_chunky(BACKGROUND_COLOR)
      png = ChunkyPNG::Image.new(@width, @height, bg_color)
      return png.to_blob
    end

    # Fall back to ImageMagick
    output_file = Tempfile.new(['terrain_ocean', '.png'])

    begin
      # Use shell command for ImageMagick
      system('convert', '-size', "#{@width}x#{@height}", "xc:#{BACKGROUND_COLOR}", output_file.path)

      File.binread(output_file.path)
    ensure
      output_file.close
      output_file.unlink
    end
  end

  # Build the texture image with all hexes using a single MVG file
  # This is much faster than multiple ImageMagick invocations
  # Used for small worlds (< LARGE_WORLD_THRESHOLD hexes)
  def build_texture(hexes)
    mvg_file = Tempfile.new(['terrain', '.mvg'])
    output_file = Tempfile.new(['terrain_output', '.png'])

    begin
      # Build MVG (Magick Vector Graphics) content with all drawing commands
      mvg_content = build_mvg_content(hexes)
      File.write(mvg_file.path, mvg_content)

      # Single ImageMagick call to render the entire MVG file
      success = system(
        'convert',
        '-size', "#{@width}x#{@height}",
        "xc:#{BACKGROUND_COLOR}",
        '-draw', "@#{mvg_file.path}",
        output_file.path
      )

      unless success
        warn "[TerrainTexture] ImageMagick convert failed"
        return generate_ocean_texture
      end

      File.binread(output_file.path)
    ensure
      mvg_file.close
      mvg_file.unlink
      output_file.close
      output_file.unlink
    end
  end

  # Build MVG content with all hex drawing commands grouped by color
  # Uses ellipses for smoother coastlines (less blocky than rectangles)
  def build_mvg_content(hexes)
    lines = []
    base_radius = calculate_hex_radius

    # Group hexes by terrain type to minimize fill color changes
    hexes_by_terrain = hexes.group_by(&:terrain_type)

    hexes_by_terrain.each do |terrain_type, terrain_hexes|
      color = WorldTerrainConfig::TERRAIN_COLORS[terrain_type] || WorldTerrainConfig::TERRAIN_COLORS['unknown']
      lines << "fill '#{color}'"
      lines << "stroke none"

      terrain_hexes.each do |hex|
        lat = hex.latitude
        lng = hex.longitude
        next if lat.nil? || lng.nil?

        px, py = latlon_to_pixel(lat, lng)

        # Use ellipses for smoother edges
        # Adjust width for latitude distortion (wider near equator, narrower at poles)
        lat_scale = Math.cos(lat * Math::PI / 180.0).abs
        lat_scale = [lat_scale, 0.1].max
        rx = (base_radius / lat_scale).round  # horizontal radius
        ry = base_radius                       # vertical radius

        # Draw ellipse: ellipse cx,cy rx,ry 0,360
        lines << "ellipse #{px},#{py} #{rx},#{ry} 0,360"
      end
    end

    lines.join("\n")
  end

  # Calculate base hex radius in pixels based on expected hex density
  # Uses generous overlap (1.8 multiplier) for smooth, natural-looking coastlines
  def calculate_hex_radius
    count = hex_count
    return 15 if count == 0

    # Approximate: if we have N hexes covering the sphere,
    # each hex covers ~(4*PI*R^2)/N surface area
    # Use 1.8 multiplier for generous overlap - creates smooth terrain edges
    # without the blocky "built from squares" appearance
    estimated_hexes_per_row = Math.sqrt(count * 2)
    (@width / estimated_hexes_per_row * 1.8).clamp(8, 60).round
  end

end
