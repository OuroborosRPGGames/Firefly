# frozen_string_literal: true

module EarthImport
  # Uses GDAL/OGR to read Natural Earth land shapefiles and determine
  # whether geographic coordinates are on land or ocean.
  #
  # This provides accurate coastlines instead of hardcoded rectangular estimates.
  #
  # For large-scale imports (34M+ hexes), use rasterized mode for O(1) lookups
  # instead of expensive point-in-polygon tests.
  #
  # @example Basic usage
  #   service = LandMaskService.new('/path/to/ne_land')
  #   service.land?(lat: 40.7, lon: -74.0)  # => true (New York)
  #   service.land?(lat: 0, lon: -30)       # => false (Atlantic Ocean)
  #
  # @example Rasterized mode for bulk imports
  #   service = LandMaskService.new('/path/to/ne_land', rasterize: true)
  #   service.land?(lat: 40.7, lon: -74.0)  # O(1) lookup from bitmap
  #
  class LandMaskService
    class GdalNotAvailableError < StandardError; end

    # Default raster resolution: 0.01 degrees per pixel = ~1.1 km at equator
    # 36,000 × 18,000 pixels = 648M pixels = ~81 MB bitmap
    # Higher resolution uses more memory but provides more accurate coastlines
    DEFAULT_RASTER_RESOLUTION = 0.01

    # Adaptive resolution based on hex count (can be overridden)
    # These are tuned so that on average, several hexes share each pixel
    RESOLUTION_BY_SUBDIVISIONS = {
      7 => 0.1,    # 328K hexes -> 3.6K × 1.8K pixels
      8 => 0.05,   # 1.3M hexes -> 7.2K × 3.6K pixels
      9 => 0.02,   # 5.2M hexes -> 18K × 9K pixels
      10 => 0.01   # 21M hexes -> 36K × 18K pixels
    }.freeze

    attr_reader :land_shapefile_dir, :rasterized

    # Check if GDAL is available for use.
    # IMPORTANT: Load gdal before gdal-ruby/ogr or the MEM driver won't work.
    #
    # @return [Boolean] true if GDAL Ruby bindings are available
    def self.gdal_available?
      return @gdal_available if defined?(@gdal_available)

      @gdal_available = begin
        require 'gdal'           # Load GDAL raster first
        require 'gdal-ruby/ogr'  # Then load OGR vector
        Gdal::Gdal.all_register  # Register all drivers
        true
      rescue LoadError
        false
      end
    end

    # Raise an error if GDAL is not available.
    #
    # @raise [GdalNotAvailableError] if GDAL cannot be loaded
    def self.require_gdal!
      return if gdal_available?

      raise GdalNotAvailableError,
            'GDAL Ruby bindings not available. Install with: ' \
            'sudo apt-get install libgdal-dev && bundle add gdal'
    end

    # Initialize the land mask service.
    #
    # @param land_shapefile_dir [String] Path to directory containing ne_10m_land.shp
    # @param rasterize [Boolean] If true, pre-rasterize land mask for O(1) lookups
    # @param cache_dir [String, nil] Directory to cache rasterized bitmap
    # @param resolution [Float, nil] Raster resolution in degrees (default: 0.01)
    # @param subdivisions [Integer, nil] Subdivision level to auto-select resolution
    # @raise [GdalNotAvailableError] if GDAL is not available
    def initialize(land_shapefile_dir, rasterize: false, cache_dir: nil, resolution: nil, subdivisions: nil)
      self.class.require_gdal!

      @land_shapefile_dir = land_shapefile_dir
      @land_geometry = nil
      @loaded = false
      @rasterized = rasterize
      @raster_cache = nil
      @cache_dir = cache_dir || File.join(land_shapefile_dir, '..', 'earth_import_cache')

      # Determine resolution: explicit > subdivisions-based > default
      @resolution = resolution ||
                    (subdivisions && RESOLUTION_BY_SUBDIVISIONS[subdivisions]) ||
                    DEFAULT_RASTER_RESOLUTION

      # Calculate dimensions from resolution
      @raster_width = (360.0 / @resolution).to_i
      @raster_height = (180.0 / @resolution).to_i

      load_land_geometry

      # Build raster cache if requested and geometry loaded successfully
      build_raster_cache if @rasterized && @loaded
    end

    # Check if a coordinate is on land.
    #
    # @param lat [Float] Latitude in degrees (-90 to 90)
    # @param lon [Float] Longitude in degrees (-180 to 180)
    # @return [Boolean] true if the point is on land
    def land?(lat:, lon:)
      return false unless @loaded

      # Use rasterized lookup if available (O(1))
      if @rasterized && @raster_cache
        return land_from_raster?(lat, lon)
      end

      return false unless @land_geometries&.any?

      # Create a point geometry
      # Natural Earth shapefiles use standard (lon, lat) coordinate order
      point = Gdal::Ogr::Geometry.new(Gdal::Ogr::WKBPOINT)
      point.add_point(lon, lat)

      # Check if point is within any land polygon
      @land_geometries.any? { |geom| geom.contains(point) }
    rescue StandardError => e
      warn "[LandMaskService] Error checking point (#{lat}, #{lon}): #{e.message}"
      false
    end

    # Check if a coordinate is in the ocean.
    #
    # @param lat [Float] Latitude in degrees
    # @param lon [Float] Longitude in degrees
    # @return [Boolean] true if the point is in the ocean
    def ocean?(lat:, lon:)
      !land?(lat: lat, lon: lon)
    end

    # Check if the land mask was loaded successfully.
    #
    # @return [Boolean]
    def loaded?
      @loaded
    end

    # Check if rasterized mode is active.
    #
    # @return [Boolean]
    def rasterized?
      @rasterized && @raster_cache
    end

    # Get raster statistics (for debugging).
    #
    # @return [Hash, nil] Statistics about the raster cache
    def raster_stats
      return nil unless @raster_cache

      land_count = 0
      @raster_cache.each { |row| row.each { |v| land_count += 1 if v } }
      total = @raster_width * @raster_height

      {
        width: @raster_width,
        height: @raster_height,
        resolution_degrees: @resolution,
        land_pixels: land_count,
        ocean_pixels: total - land_count,
        land_percentage: (land_count.to_f / total * 100).round(2)
      }
    end

    private

    # O(1) lookup from rasterized bitmap.
    #
    # @param lat [Float] Latitude in degrees
    # @param lon [Float] Longitude in degrees
    # @return [Boolean] true if land
    def land_from_raster?(lat, lon)
      # Normalize longitude to 0-360 for array indexing
      norm_lon = lon < 0 ? lon + 360.0 : lon

      # Convert to pixel coordinates
      # X: 0-360 longitude maps to 0-raster_width
      x = ((norm_lon / 360.0) * @raster_width).to_i.clamp(0, @raster_width - 1)

      # Y: 90 to -90 latitude maps to 0-raster_height (top to bottom)
      y = (((90.0 - lat) / 180.0) * @raster_height).to_i.clamp(0, @raster_height - 1)

      @raster_cache[y][x] || false
    end

    # Build rasterized land mask for O(1) lookups.
    # First tries to load from cache file, then builds from scratch if needed.
    def build_raster_cache
      cache_file = cache_file_path

      if File.exist?(cache_file)
        load_raster_from_file(cache_file)
        return if @raster_cache
      end

      warn "[LandMaskService] Building rasterized land mask (#{@raster_width}x#{@raster_height})..."
      build_raster_with_gdal_native
      save_raster_to_file(cache_file) if @raster_cache
    end

    # Get the cache file path for the current resolution.
    #
    # @return [String] Path to cache file
    def cache_file_path
      File.join(@cache_dir, "land_raster_#{@raster_width}x#{@raster_height}.bin")
    end

    # Load raster from cached binary file.
    #
    # @param cache_file [String] Path to cache file
    def load_raster_from_file(cache_file)
      data = File.binread(cache_file)

      # Validate size
      expected_size = @raster_width * @raster_height / 8  # 1 bit per pixel
      unless data.bytesize == expected_size
        warn "[LandMaskService] Cache file size mismatch, rebuilding"
        return
      end

      # Unpack bits into 2D array
      @raster_cache = Array.new(@raster_height) { Array.new(@raster_width, false) }

      bit_index = 0
      data.each_byte do |byte|
        8.times do |i|
          break if bit_index >= @raster_width * @raster_height

          y = bit_index / @raster_width
          x = bit_index % @raster_width
          @raster_cache[y][x] = (byte >> (7 - i)) & 1 == 1
          bit_index += 1
        end
      end

      warn "[LandMaskService] Loaded rasterized land mask from cache (#{@raster_width}x#{@raster_height})"
    rescue StandardError => e
      warn "[LandMaskService] Error loading cache: #{e.message}"
      @raster_cache = nil
    end

    # Save raster to binary file for future use.
    #
    # @param cache_file [String] Path to cache file
    def save_raster_to_file(cache_file)
      FileUtils.mkdir_p(File.dirname(cache_file))

      # Pack bits into bytes
      bytes = []
      current_byte = 0
      bit_position = 7

      @raster_height.times do |y|
        @raster_width.times do |x|
          current_byte |= (1 << bit_position) if @raster_cache[y][x]
          bit_position -= 1

          if bit_position < 0
            bytes << current_byte
            current_byte = 0
            bit_position = 7
          end
        end
      end

      # Handle remaining bits
      bytes << current_byte if bit_position < 7

      File.binwrite(cache_file, bytes.pack('C*'))
      warn "[LandMaskService] Saved rasterized land mask to cache (#{bytes.size} bytes)"
    rescue StandardError => e
      warn "[LandMaskService] Error saving cache: #{e.message}"
    end

    # Build raster using GDAL's native rasterize_layer function.
    # This is ~100x faster than Ruby point-in-polygon tests.
    #
    # Uses the MEM driver to create an in-memory raster, rasterizes the land
    # polygons directly using GDAL's optimized C code, then reads the result
    # into Ruby arrays for fast lookup.
    def build_raster_with_gdal_native
      return unless @layer

      start_time = Time.now

      # Create in-memory raster dataset
      # Data type 1 = GDT_Byte (8-bit unsigned integer)
      # Note: GDAL must be loaded before OGR for MEM driver to work (done in gdal_available?)
      raster_driver = Gdal::Gdal.get_driver_by_name('MEM')
      raise 'MEM driver not available - ensure gdal is loaded before gdal-ruby/ogr' unless raster_driver
      target_ds = raster_driver.create('', @raster_width, @raster_height, 1, 1)

      # Set geotransform: [x_origin, x_pixel_size, x_rotation, y_origin, y_rotation, y_pixel_size]
      # Cover -180 to 180 longitude, 90 to -90 latitude
      geo_transform = [-180.0, @resolution, 0.0, 90.0, 0.0, -@resolution]
      target_ds.set_geo_transform(geo_transform)

      # Reset layer for reading
      @layer.reset_reading

      # Rasterize the land polygons (GDAL uses default burn value of 255 for byte type)
      # This is the critical optimization: GDAL's native C code is ~100x faster than Ruby
      Gdal::Gdal.rasterize_layer(target_ds, [1], @layer)

      elapsed = Time.now - start_time
      warn "[LandMaskService] GDAL rasterization complete in #{elapsed.round(2)}s"

      # Read the raster data into Ruby arrays
      read_raster_to_cache(target_ds)
    rescue StandardError => e
      warn "[LandMaskService] GDAL native rasterization failed: #{e.message}"
      warn e.backtrace.first(3).join("\n")

      # Fall back to slow Ruby method if GDAL rasterization fails
      warn "[LandMaskService] Falling back to Ruby rasterization..."
      build_raster_from_gdal_ruby
    end

    # Read raster data from GDAL dataset into Ruby cache arrays.
    #
    # @param target_ds [Gdal::Gdal::Dataset] The rasterized dataset
    def read_raster_to_cache(target_ds)
      band = target_ds.get_raster_band(1)

      @raster_cache = Array.new(@raster_height) { Array.new(@raster_width, false) }

      @raster_height.times do |y|
        # Read one row at a time for memory efficiency
        row_data = band.read_raster(0, y, @raster_width, 1)
        row_data.bytes.each_with_index do |b, x|
          @raster_cache[y][x] = b > 0
        end
      end

      warn "[LandMaskService] Rasterization complete (#{@raster_width}x#{@raster_height})"
    end

    # Fallback: Build raster by sampling GDAL geometries in Ruby.
    # Much slower than native rasterization but works if rasterize_layer fails.
    def build_raster_from_gdal_ruby
      return unless @land_geometries&.any?

      @raster_cache = Array.new(@raster_height) { Array.new(@raster_width, false) }

      total_pixels = @raster_width * @raster_height
      processed = 0
      last_progress = 0

      @raster_height.times do |y|
        # Convert Y to latitude (top = 90°, bottom = -90°)
        lat = 90.0 - (y.to_f / @raster_height) * 180.0

        @raster_width.times do |x|
          # Convert X to longitude (left = 0°, right = 360°, then normalize to -180..180)
          lon = (x.to_f / @raster_width) * 360.0
          lon -= 360.0 if lon > 180.0

          # Check if this pixel is land using GDAL
          point = Gdal::Ogr::Geometry.new(Gdal::Ogr::WKBPOINT)
          point.add_point(lon, lat)

          @raster_cache[y][x] = @land_geometries.any? { |geom| geom.contains(point) }

          processed += 1
          progress = (processed * 100 / total_pixels)
          if progress > last_progress && (progress % 5).zero?
            warn "[LandMaskService] Rasterizing: #{progress}%"
            last_progress = progress
          end
        end
      end

      warn '[LandMaskService] Rasterization complete'
    rescue StandardError => e
      warn "[LandMaskService] Rasterization failed: #{e.message}"
      @raster_cache = nil
    end

    # Load the land geometries from the shapefile.
    # Stores individual polygons instead of unioning them (much faster).
    def load_land_geometry
      # Try 110m resolution first (much faster), fall back to 10m
      shapefile_path = File.join(@land_shapefile_dir, 'ne_110m_land.shp')
      unless File.exist?(shapefile_path)
        shapefile_path = File.join(@land_shapefile_dir, 'ne_10m_land.shp')
      end

      unless File.exist?(shapefile_path)
        warn "[LandMaskService] Shapefile not found: #{shapefile_path}"
        return
      end

      # Open the shapefile using GDAL/OGR
      # Second arg: 0 = read-only, 1 = read-write
      driver = Gdal::Ogr.get_driver_by_name('ESRI Shapefile')
      @datasource = driver.open(shapefile_path, 0)

      unless @datasource
        warn "[LandMaskService] Failed to open shapefile: #{shapefile_path}"
        return
      end

      @layer = @datasource.get_layer(0)
      unless @layer
        warn '[LandMaskService] No layer found in shapefile'
        return
      end

      # Store individual geometries (faster than union)
      @land_geometries = []
      @layer.reset_reading

      while (feature = @layer.get_next_feature)
        geom = feature.get_geometry_ref
        next unless geom

        @land_geometries << geom.clone
      end

      # Set a flag for backward compatibility
      @land_geometry = @land_geometries.first
      @loaded = @land_geometries.any?

      if @loaded
        warn "[LandMaskService] Loaded #{@land_geometries.size} land polygons"
      else
        warn '[LandMaskService] Failed to load land geometry'
      end
    rescue StandardError => e
      warn "[LandMaskService] Error loading shapefile: #{e.message}"
      warn e.backtrace.first(3).join("\n")
      @loaded = false
    end
  end
end
