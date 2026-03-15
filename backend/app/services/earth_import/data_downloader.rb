# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'zip'
require 'fileutils'

module EarthImport
  # Downloads Natural Earth and HydroSHEDS data files with retry logic,
  # caching via CacheManager, and zip extraction.
  #
  # Usage:
  #   downloader = EarthImport::DataDownloader.new
  #   paths = downloader.download_natural_earth
  #   # => { coastlines: '/path/to/ne_coastlines', lakes: '/path/to/ne_lakes', ... }
  #
  #   rivers = downloader.download_hydrosheds
  #   # => { rivers: '/path/to/hydrorivers' }
  #
  class DataDownloader
    MAX_RETRIES = 3
    RETRY_DELAYS = [2, 4, 8].freeze

    # Natural Earth data URLs
    # Note: We use 110m for land mask (fast point-in-polygon) but 10m for detail
    NATURAL_EARTH_URLS = {
      coastlines: 'https://naciscdn.org/naturalearth/10m/physical/ne_10m_coastline.zip',
      lakes: 'https://naciscdn.org/naturalearth/10m/physical/ne_10m_lakes.zip',
      land: 'https://naciscdn.org/naturalearth/10m/physical/ne_10m_land.zip',
      land_110m: 'https://naciscdn.org/naturalearth/110m/physical/ne_110m_land.zip',
      land_cover: 'https://naciscdn.org/naturalearth/10m/raster/NE1_HR_LC_SR_W.zip'
    }.freeze

    # HydroSHEDS river data URL
    HYDROSHEDS_URL = 'https://data.hydrosheds.org/file/HydroRIVERS/HydroRIVERS_v10_shp.zip'

    attr_reader :cache_manager

    # Initialize the downloader.
    #
    # @param cache_manager [CacheManager, nil] Custom cache manager instance.
    #   Defaults to a new CacheManager with default settings.
    def initialize(cache_manager: nil)
      @cache_manager = cache_manager || CacheManager.new
    end

    # Download a file from URL, using cache if available.
    #
    # @param url [String] The URL to download from
    # @param filename [String] The filename to use for caching
    # @return [String] The path to the downloaded/cached file
    # @raise [DownloadError] if download fails after all retries
    def download_file(url, filename)
      # Check cache first - return if valid
      if cache_manager.cached?(filename) && cache_manager.valid_checksum?(filename)
        warn "[DataDownloader] Using cached file: #{filename}"
        return cache_manager.cache_path(filename)
      end

      warn "[DataDownloader] Downloading: #{url}"

      # Download with retries
      content = download_with_retries(url)
      cache_manager.store(filename, content)
      cache_manager.cache_path(filename)
    end

    # Download all Natural Earth data files.
    #
    # Downloads coastlines, lakes, land polygons, and land cover raster.
    # Each file is extracted to its own subdirectory.
    #
    # @return [Hash] Paths to extracted directories keyed by dataset name
    def download_natural_earth
      warn '[DataDownloader] Downloading Natural Earth datasets...'

      {
        coastlines: download_and_extract(NATURAL_EARTH_URLS[:coastlines], 'ne_coastlines'),
        lakes: download_and_extract(NATURAL_EARTH_URLS[:lakes], 'ne_lakes'),
        land: download_and_extract(NATURAL_EARTH_URLS[:land_110m], 'ne_110m_land'),
        land_cover: download_and_extract(NATURAL_EARTH_URLS[:land_cover], 'ne_land_cover')
      }
    end

    # Download HydroSHEDS river data.
    #
    # Downloads the HydroRIVERS shapefile containing global river networks.
    #
    # @return [Hash] Path to extracted directory with :rivers key
    def download_hydrosheds
      warn '[DataDownloader] Downloading HydroSHEDS river data...'

      {
        rivers: download_and_extract(HYDROSHEDS_URL, 'hydrorivers')
      }
    end

    private

    # Download a URL with retry logic.
    #
    # @param url [String] The URL to download
    # @return [String] The response body
    # @raise [DownloadError] if all retries fail
    def download_with_retries(url)
      retries = 0

      begin
        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)

        unless response.is_a?(Net::HTTPSuccess)
          raise DownloadError, "HTTP #{response.code}"
        end

        response.body
      rescue StandardError => e
        retries += 1
        if retries < MAX_RETRIES
          delay = RETRY_DELAYS[retries - 1] || 2
          warn "[DataDownloader] Retry #{retries}/#{MAX_RETRIES} after #{delay}s: #{e.message}"
          sleep(delay)
          retry
        end
        raise DownloadError, "Failed to download #{url} after #{MAX_RETRIES} attempts: #{e.message}"
      end
    end

    # Download a zip file and extract its contents.
    #
    # @param url [String] The URL of the zip file
    # @param prefix [String] Directory name prefix for extracted contents
    # @return [String] Path to the extraction directory
    def download_and_extract(url, prefix)
      zip_filename = "#{prefix}.zip"
      zip_path = download_file(url, zip_filename)

      extract_dir = File.join(cache_manager.cache_dir, prefix)
      FileUtils.mkdir_p(extract_dir)

      # Check if already extracted
      if Dir.exist?(extract_dir) && !Dir.empty?(extract_dir)
        warn "[DataDownloader] Using cached extraction: #{prefix}"
        return extract_dir
      end

      warn "[DataDownloader] Extracting: #{zip_filename}"

      # Extract zip contents
      Zip::File.open(zip_path) do |zip|
        zip.each do |entry|
          target = File.join(extract_dir, entry.name)
          FileUtils.mkdir_p(File.dirname(target))
          entry.extract(target) unless File.exist?(target)
        end
      end

      extract_dir
    end
  end
end
