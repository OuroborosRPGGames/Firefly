# frozen_string_literal: true

require 'yaml'

# ==============================================================================
# GamePrompts - Centralized LLM Prompt Configuration
# ==============================================================================
# Loads prompts from config/prompts.yml and provides easy access with interpolation.
#
# Usage:
#   # Simple lookup
#   prompt = GamePrompts.get('abuse_detection.first_pass')
#
#   # With interpolation
#   prompt = GamePrompts.get('combat.prose_enhancement', paragraph: text)
#
#   # Nested paths
#   prompt = GamePrompts.get('activities.free_roll.assess', situation: ctx)
#
#   # Image templates
#   template = GamePrompts.image_template(:npc_portrait)
#   # => { prefix: "...", suffix: "..." }
#
#   # Setting modifiers
#   modifier = GamePrompts.setting_modifier(:fantasy)
#   # => "medieval fantasy, magical, mystical"
#
# Reload prompts (for development):
#   GamePrompts.reload!
# ==============================================================================
module GamePrompts
  class << self
    # Get a prompt by dot-separated path with optional interpolation
    # @param path [String] Dot-separated path like 'abuse_detection.first_pass'
    # @param interpolations [Hash] Variables to interpolate into the prompt
    # @return [String] The interpolated prompt
    def get(path, **interpolations)
      prompt = dig_path(path)
      raise ArgumentError, "Prompt not found: #{path}" unless prompt
      raise ArgumentError, "Path #{path} is not a string prompt" unless prompt.is_a?(String)

      interpolate(prompt, interpolations)
    end

    # Get a prompt, returning nil if not found (no exception)
    # @param path [String] Dot-separated path
    # @param interpolations [Hash] Variables to interpolate
    # @return [String, nil] The interpolated prompt or nil
    def get_safe(path, **interpolations)
      get(path, **interpolations)
    rescue ArgumentError
      nil
    end

    # Check if a prompt exists at the given path
    # @param path [String] Dot-separated path
    # @return [Boolean]
    def exists?(path)
      prompt = dig_path(path)
      prompt.is_a?(String)
    end

    # Get image template (prefix/suffix/ratio/style)
    # @param type [Symbol] Template type like :npc_portrait, :item_on_black
    # @return [Hash, nil] { prefix: "...", suffix: "...", ratio: "...", style: "..." }, or nil if type not found
    def image_template(type)
      templates = prompts.dig('images', 'templates', type.to_s)
      return nil unless templates

      result = {
        prefix: templates['prefix'],
        suffix: templates['suffix'],
        ratio: templates['ratio'],
        style: templates['style']&.to_sym
      }

      if templates['image_framing']
        result[:image_framing] = templates['image_framing'].transform_keys(&:to_sym)
      end

      result
    end

    # Get all image template types
    # @return [Array<Symbol>]
    def image_template_types
      prompts.dig('images', 'templates')&.keys&.map(&:to_sym) || []
    end

    # Get setting aesthetic modifier
    # @param setting [Symbol] Setting like :fantasy, :modern, :sci_fi
    # @return [String, nil] The modifier string
    def setting_modifier(setting)
      prompts.dig('images', 'settings', setting.to_s)
    end

    # Get photographic profile for an era (for room/area background generation)
    # @param era [Symbol] Era like :fantasy, :gaslight, :modern, :cyberpunk, :scifi
    # @return [Hash, nil] { camera:, default_lens:, film_stock:, lighting:, imperfections:, genre_phrase: }
    def photo_profile(era)
      profile = prompts.dig('images', 'photo_profiles', era.to_s)
      return nil unless profile

      profile.transform_keys(&:to_sym)
    end

    # Get room-type framing for background generation
    # @param category [Symbol] Category like :indoor, :outdoor_urban, :outdoor_nature, :underground
    # @return [Hash, nil] { lens_override:, framing:, lighting_extra: }
    def room_framing(category)
      framing = prompts.dig('images', 'room_framing', category.to_s)
      return nil unless framing

      framing.transform_keys(&:to_sym)
    end

    # Get all available prompt paths (for documentation/debugging)
    # @return [Array<String>] List of all prompt paths
    def all_paths
      collect_paths(prompts)
    end

    # Reload prompts from disk (useful in development)
    def reload!
      @prompts = nil
      prompts
    end

    # Get raw prompts hash (for inspection)
    # @return [Hash]
    def raw
      prompts
    end

    private

    # Load prompts from YAML file
    def prompts
      @prompts ||= begin
        path = File.join(__dir__, 'prompts.yml')
        YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
    end

    # Dig into nested hash by dot-separated path
    def dig_path(path)
      keys = path.to_s.split('.')
      result = prompts
      keys.each do |key|
        result = result[key]
        return nil if result.nil?
      end
      result
    end

    # Interpolate variables into prompt string
    # Supports %{variable} syntax
    def interpolate(prompt, vars)
      return prompt if vars.empty?

      # Convert symbol keys to strings for consistent lookup
      string_vars = vars.transform_keys(&:to_s)

      prompt.gsub(/%\{(\w+)\}/) do |match|
        key = ::Regexp.last_match(1)
        if string_vars.key?(key)
          string_vars[key].to_s
        else
          match # Leave unmatched placeholders as-is
        end
      end
    end

    # Recursively collect all paths to string prompts
    def collect_paths(hash, prefix = '')
      paths = []
      hash.each do |key, value|
        current_path = prefix.empty? ? key : "#{prefix}.#{key}"
        if value.is_a?(Hash)
          paths.concat(collect_paths(value, current_path))
        elsif value.is_a?(String)
          paths << current_path
        end
      end
      paths
    end
  end
end
