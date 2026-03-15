# frozen_string_literal: true

require 'digest'
require 'json'
require 'fileutils'

module EarthImport
  # Manages caching of downloaded Natural Earth and HydroSHEDS data files.
  # Implements 30-day expiry and SHA256 checksum validation to detect corruption.
  #
  # Usage:
  #   cache = EarthImport::CacheManager.new
  #   cache.store('coastlines.shp', shapefile_content)
  #   cache.cached?('coastlines.shp')  # => true
  #   cache.valid_checksum?('coastlines.shp')  # => true
  #
  class CacheManager
    EXPIRY_DAYS = 30

    attr_reader :cache_dir

    # Initialize the cache manager.
    #
    # @param cache_dir [String, nil] Custom cache directory path.
    #   Defaults to backend/data/earth if not provided.
    def initialize(cache_dir: nil)
      @cache_dir = cache_dir || default_cache_dir
      FileUtils.mkdir_p(@cache_dir)
    end

    # Get the full path for a cached file.
    #
    # @param filename [String] The filename to cache
    # @return [String] Full path within the cache directory
    def cache_path(filename)
      File.join(@cache_dir, filename)
    end

    # Check if a file is cached and not expired.
    #
    # @param filename [String] The filename to check
    # @return [Boolean] true if file exists and is less than 30 days old
    def cached?(filename)
      path = cache_path(filename)
      return false unless File.exist?(path)

      age = age_days(filename)
      !age.nil? && age < EXPIRY_DAYS
    end

    # Store content in the cache with checksum tracking.
    #
    # @param filename [String] The filename to store
    # @param content [String] The content to write
    # @return [String] The full path where content was stored
    def store(filename, content)
      path = cache_path(filename)
      File.write(path, content)
      update_checksum(filename, content)
      path
    end

    # Validate a cached file's checksum.
    #
    # @param filename [String] The filename to validate
    # @return [Boolean] true if file exists and checksum matches
    def valid_checksum?(filename)
      path = cache_path(filename)
      return false unless File.exist?(path)

      checksums = load_checksums
      expected = checksums[filename]
      return false if expected.nil? || expected.empty?

      actual = Digest::SHA256.file(path).hexdigest
      actual == expected
    end

    # Remove all cached files older than EXPIRY_DAYS.
    # Preserves the checksums.json metadata file.
    #
    # @return [Array<String>] List of deleted file paths
    def clear_expired
      deleted = []

      Dir.glob(File.join(@cache_dir, '*')).each do |path|
        next if File.basename(path) == 'checksums.json'
        next unless File.file?(path)

        filename = File.basename(path)
        age = age_days(filename)
        next if age.nil? || age < EXPIRY_DAYS

        File.delete(path)
        deleted << path
        warn "[CacheManager] Expired cache file removed: #{filename}"
      end

      deleted
    end

    # Get the age of a cached file in days.
    #
    # @param filename [String] The filename to check
    # @return [Float, nil] Age in days, or nil if file doesn't exist
    def age_days(filename)
      path = cache_path(filename)
      return nil unless File.exist?(path)

      (Time.now - File.mtime(path)) / (24 * 60 * 60)
    end

    private

    def default_cache_dir
      File.join(Dir.pwd, 'data', 'earth')
    end

    def checksums_path
      File.join(@cache_dir, 'checksums.json')
    end

    def load_checksums
      return {} unless File.exist?(checksums_path)

      JSON.parse(File.read(checksums_path))
    rescue JSON::ParserError => e
      warn "[CacheManager] Corrupted checksums.json, will be overwritten: #{e.message}"
      {}
    end

    def update_checksum(filename, content)
      checksums = load_checksums
      checksums[filename] = Digest::SHA256.hexdigest(content)
      File.write(checksums_path, JSON.pretty_generate(checksums))
    end
  end
end
