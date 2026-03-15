# frozen_string_literal: true

namespace :earth do
  desc 'Build land raster cache for Earth imports'
  task :build_land_cache, [:resolution] do |_t, args|
    require_relative '../../config/app'

    resolution = (args[:resolution] || '0.01').to_f

    puts "Building land raster cache at #{resolution}° resolution..."
    puts "This will create a cache file for faster Earth imports.\n\n"

    # Find the land shapefile directory
    land_dir = File.join(APP_ROOT, 'data', 'earth', 'ne_110m_land')
    unless File.directory?(land_dir)
      land_dir = File.join(APP_ROOT, 'data', 'earth', 'ne_land')
    end

    unless File.directory?(land_dir)
      puts 'ERROR: Land shapefile directory not found.'
      puts 'Expected: data/earth/ne_110m_land/ or data/earth/ne_land/'
      puts ''
      puts 'Download Natural Earth land data first with:'
      puts '  rake earth:download'
      exit 1
    end

    # Calculate dimensions
    width = (360.0 / resolution).to_i
    height = (180.0 / resolution).to_i
    puts "Raster dimensions: #{width}x#{height} (#{width * height / 1_000_000.0}M pixels)"

    cache_dir = File.join(APP_ROOT, 'data', 'earth_import_cache')
    cache_file = File.join(cache_dir, "land_raster_#{width}x#{height}.bin")

    if File.exist?(cache_file)
      puts "Cache file already exists: #{cache_file}"
      print 'Delete and rebuild? [y/N] '
      response = $stdin.gets&.strip&.downcase
      if response != 'y'
        puts 'Aborted.'
        exit 0
      end
      File.delete(cache_file)
    end

    puts ''
    puts 'Loading land mask service with rasterization...'
    start_time = Time.now

    # This will build the cache
    service = EarthImport::LandMaskService.new(
      land_dir,
      rasterize: true,
      resolution: resolution,
      cache_dir: cache_dir
    )

    elapsed = Time.now - start_time

    if service.rasterized?
      stats = service.raster_stats
      puts ''
      puts '✓ Land raster cache built successfully!'
      puts "  Resolution: #{stats[:resolution_degrees]}°"
      puts "  Dimensions: #{stats[:width]}x#{stats[:height]}"
      puts "  Land pixels: #{stats[:land_pixels].to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
      puts "  Land percentage: #{stats[:land_percentage]}%"
      puts "  Build time: #{elapsed.round(2)}s"
      puts "  Cache file: #{cache_file}"
      puts "  File size: #{File.size(cache_file) / 1024}KB"
    else
      puts ''
      puts '✗ Failed to build land raster cache.'
      puts '  Check the error messages above for details.'
      exit 1
    end
  end

  desc 'Build caches for all standard resolution levels'
  task :build_all_caches do
    require_relative '../../config/app'

    resolutions = {
      '0.1' => 'subdivisions=7 (328K hexes)',
      '0.05' => 'subdivisions=8 (1.3M hexes)',
      '0.02' => 'subdivisions=9 (5.2M hexes)',
      '0.01' => 'subdivisions=10 (21M hexes)'
    }

    puts 'Building land raster caches for all standard resolutions...'
    puts ''

    resolutions.each do |res, desc|
      puts "="*60
      puts "Building #{res}° resolution cache (#{desc})"
      puts "="*60
      Rake::Task['earth:build_land_cache'].reenable
      Rake::Task['earth:build_land_cache'].invoke(res)
      puts ''
    end

    puts '✓ All caches built successfully!'
  end

  desc 'Download Natural Earth data for Earth imports'
  task :download do
    require_relative '../../config/app'

    puts 'Downloading Natural Earth data...'
    downloader = EarthImport::DataDownloader.new
    paths = downloader.download_natural_earth

    puts '✓ Natural Earth data downloaded:'
    paths.each { |k, v| puts "  #{k}: #{v}" }
  end

  desc 'Show cache status and stats'
  task :cache_status do
    require_relative '../../config/app'

    cache_dir = File.join(APP_ROOT, 'data', 'earth_import_cache')

    unless File.directory?(cache_dir)
      puts 'No cache directory found.'
      puts "Expected: #{cache_dir}"
      exit 0
    end

    cache_files = Dir.glob(File.join(cache_dir, 'land_raster_*.bin')).sort

    if cache_files.empty?
      puts 'No land raster cache files found.'
      puts 'Run `rake earth:build_land_cache` to create one.'
      exit 0
    end

    puts 'Land raster cache files:'
    puts ''

    cache_files.each do |cache_file|
      filename = File.basename(cache_file)
      size_kb = File.size(cache_file) / 1024

      # Parse dimensions from filename
      if filename =~ /land_raster_(\d+)x(\d+)\.bin/
        width, height = Regexp.last_match(1).to_i, Regexp.last_match(2).to_i
        resolution = 360.0 / width
        pixels_m = (width * height) / 1_000_000.0

        puts "  #{filename}"
        puts "    Resolution: #{resolution}°"
        puts "    Dimensions: #{width}x#{height} (#{pixels_m.round(1)}M pixels)"
        puts "    File size: #{size_kb}KB"
        puts ''
      end
    end
  end
end
