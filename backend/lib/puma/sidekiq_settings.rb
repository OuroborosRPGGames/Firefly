# frozen_string_literal: true

require 'erb'
require 'yaml'

module Puma
  module SidekiqSettings
    DEFAULT_CONFIG_PATH = File.expand_path('../../config/sidekiq.yml', __dir__)

    module_function

    # Load Sidekiq settings from config/sidekiq.yml.
    # Returns a Hash with string keys.
    #
    # @param path [String, nil]
    # @return [Hash]
    def load(path = nil)
      config_path = resolve_config_path(path)
      return {} unless File.exist?(config_path)

      raw = ERB.new(File.read(config_path)).result
      parsed = YAML.safe_load(raw, permitted_classes: [Symbol], aliases: true) || {}
      normalize_keys(parsed)
    rescue StandardError => e
      warn "[Puma::SidekiqSettings] Failed to load #{config_path}: #{e.message}"
      {}
    end

    # Expand weighted queue config into a flat Sidekiq queue list.
    #
    # Input examples:
    #   [["llm", 10], ["default", 1]]
    #   ["critical", "default"]
    #   [{"critical" => 5}, {"default" => 1}]
    #
    # Output:
    #   ["llm", ... (10x), "default"]
    #
    # @param queues [Array, nil]
    # @return [Array<String>]
    def expand_weighted_queues(queues)
      result = []

      Array(queues).each do |entry|
        case entry
        when Array
          name = entry[0]
          weight = to_weight(entry[1])
          result.concat(Array.new(weight, name.to_s)) unless blank?(name)
        when Hash
          entry.each do |name, weight|
            count = to_weight(weight)
            result.concat(Array.new(count, name.to_s)) unless blank?(name)
          end
        else
          result << entry.to_s unless blank?(entry)
        end
      end

      result.empty? ? ['default'] : result
    end

    def resolve_config_path(path)
      return DEFAULT_CONFIG_PATH if blank?(path)
      return path if path.start_with?('/')

      File.expand_path(path, Dir.pwd)
    end

    def normalize_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), out|
          out[k.to_s] = normalize_keys(v)
        end
      when Array
        value.map { |v| normalize_keys(v) }
      else
        value
      end
    end

    def to_weight(weight)
      w = weight.to_i
      w > 0 ? w : 1
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
