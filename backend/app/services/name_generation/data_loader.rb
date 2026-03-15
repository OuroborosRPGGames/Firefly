# frozen_string_literal: true

require 'yaml'

module NameGeneration
  # DataLoader handles loading and caching of YAML name data files.
  #
  # Data files are stored in data/names/ directory and loaded lazily.
  # Once loaded, data is cached in memory for performance.
  #
  # Usage:
  #   DataLoader.load('character/forenames', 'western_male')
  #   DataLoader.load('locations', 'city_components')
  #
  class DataLoader
    class << self
      # Load a YAML data file
      # @param category [String] the category path (e.g., 'character/forenames')
      # @param file [String] the file name without extension
      # @return [Hash] the parsed YAML data with symbolized keys
      def load(category, file)
        cache_key = "#{category}/#{file}"
        cache[cache_key] ||= load_file(category, file)
      end

      # Check if a data file exists
      # @param category [String] the category path
      # @param file [String] the file name
      # @return [Boolean]
      def exists?(category, file)
        path = file_path(category, file)
        File.exist?(path)
      end

      # List all available files in a category
      # @param category [String] the category path
      # @return [Array<String>] list of file names without extensions
      def list_files(category)
        dir_path = File.join(data_root, category)
        return [] unless Dir.exist?(dir_path)

        Dir.glob(File.join(dir_path, '*.yml'))
           .map { |f| File.basename(f, '.yml') }
           .sort
      end

      # Clear the cache (for testing or memory management)
      # @return [void]
      def clear_cache!
        @cache = {}
      end

      # Reload a specific file (bypasses cache)
      # @param category [String] the category path
      # @param file [String] the file name
      # @return [Hash] the fresh data
      def reload(category, file)
        cache_key = "#{category}/#{file}"
        cache[cache_key] = load_file(category, file)
      end

      # Get the data root directory
      # @return [String]
      def data_root
        @data_root ||= File.expand_path('../../../data/names', __dir__)
      end

      # Set custom data root (for testing)
      # @param path [String] the new data root path
      def data_root=(path)
        @data_root = path
        clear_cache!
      end

      private

      def cache
        @cache ||= {}
      end

      def file_path(category, file)
        File.join(data_root, category, "#{file}.yml")
      end

      def load_file(category, file)
        path = file_path(category, file)

        unless File.exist?(path)
          raise ArgumentError, "Data file not found: #{path}"
        end

        content = File.read(path)
        data = YAML.safe_load(content, permitted_classes: [Symbol], permitted_symbols: [], aliases: true)

        # Deep symbolize keys
        deep_symbolize_keys(data)
      end

      def deep_symbolize_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(key, value), result|
            new_key = key.is_a?(String) ? key.to_sym : key
            result[new_key] = deep_symbolize_keys(value)
          end
        when Array
          obj.map { |item| deep_symbolize_keys(item) }
        else
          obj
        end
      end
    end
  end
end
