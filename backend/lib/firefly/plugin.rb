# frozen_string_literal: true

module Firefly
  # Base class for all Firefly plugins.
  #
  # Plugins are self-contained modules that add functionality to the game.
  # Each plugin can provide:
  # - Commands (in commands/ directory)
  # - Model extensions (in models/ directory)
  # - Routes (in routes/ directory)
  # - Event handlers
  #
  # Example plugin:
  #
  #   module Plugins::Communication
  #     class Plugin < Firefly::Plugin
  #       name "communication"
  #       version "1.0.0"
  #       description "Say, whisper, emote, and channel commands"
  #
  #       depends_on :core, :characters
  #
  #       def self.on_enable
  #         # Called when plugin is enabled
  #       end
  #
  #       def self.on_disable
  #         # Called when plugin is disabled
  #       end
  #     end
  #   end
  #
  class Plugin
    class << self
      attr_reader :plugin_name, :plugin_version, :plugin_description
      attr_reader :dependencies, :commands_directory, :models_directory, :routes_directory

      # Define plugin metadata
      def name(value = nil)
        value ? @plugin_name = value : @plugin_name
      end

      def version(value = nil)
        value ? @plugin_version = value : @plugin_version
      end

      def description(value = nil)
        value ? @plugin_description = value : @plugin_description
      end

      # Declare dependencies on other plugins
      def depends_on(*plugins)
        @dependencies ||= []
        @dependencies.concat(plugins.map(&:to_sym))
        @dependencies.uniq!
        @dependencies
      end

      # Configure auto-discovery paths (relative to plugin directory)
      def commands_path(path = nil)
        path ? @commands_directory = path : (@commands_directory || 'commands')
      end

      def models_path(path = nil)
        path ? @models_directory = path : (@models_directory || 'models')
      end

      def routes_path(path = nil)
        path ? @routes_directory = path : (@routes_directory || 'routes')
      end

      # Lifecycle hooks (override in subclasses)
      def on_enable
        # Called when plugin is enabled
      end

      def on_disable
        # Called when plugin is disabled
      end

      def on_reload
        # Called when plugin is reloaded (development mode)
        on_disable
        on_enable
      end

      # Event subscription
      def on_event(event_name, &block)
        @event_handlers ||= {}
        @event_handlers[event_name.to_sym] ||= []
        @event_handlers[event_name.to_sym] << block
      end

      def event_handlers
        @event_handlers ||= {}
      end

      # Model extensions registration
      def extend_model(model_class, extension_module)
        @model_extensions ||= []
        @model_extensions << { model: model_class, extension: extension_module }
      end

      def model_extensions
        @model_extensions ||= []
      end

      # Route registration
      def register_routes(app, &block)
        @route_blocks ||= []
        @route_blocks << block if block_given?
      end

      def route_blocks
        @route_blocks ||= []
      end

      # Plugin directory (set by PluginManager)
      def plugin_dir(path = nil)
        path ? @plugin_dir = path : @plugin_dir
      end

      # Get the full path for commands, models, or routes
      def full_commands_path
        return nil unless @plugin_dir
        File.join(@plugin_dir, commands_path)
      end

      def full_models_path
        return nil unless @plugin_dir
        File.join(@plugin_dir, models_path)
      end

      def full_routes_path
        return nil unless @plugin_dir
        File.join(@plugin_dir, routes_path)
      end

      # Check if plugin requirements are satisfied
      def dependencies_satisfied?(loaded_plugins)
        return true if dependencies.nil? || dependencies.empty?
        dependencies.all? { |dep| loaded_plugins.include?(dep) }
      end

      # Plugin status
      def enabled?
        @enabled ||= false
      end

      def enable!
        return if enabled?
        apply_model_extensions
        on_enable
        @enabled = true
      end

      def disable!
        return unless enabled?
        on_disable
        @enabled = false
      end

      private

      def apply_model_extensions
        model_extensions.each do |ext|
          model_class = ext[:model]
          extension_module = ext[:extension]
          model_class.include(extension_module) unless model_class.include?(extension_module)
        end
      end
    end

    # Instance methods (for plugins that need state)
    def initialize
      @config = {}
    end

    attr_reader :config

    def configure(options = {})
      @config.merge!(options)
    end
  end
end
