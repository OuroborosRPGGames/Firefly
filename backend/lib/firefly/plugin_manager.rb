# frozen_string_literal: true

require_relative 'plugin'

module Firefly
  # Manages loading, dependency resolution, and lifecycle of plugins.
  #
  # Usage:
  #   manager = Firefly::PluginManager.new
  #   manager.discover_plugins('plugins/core')
  #   manager.discover_plugins('plugins/optional')
  #   manager.load_all
  #
  class PluginManager
    attr_reader :plugins, :loaded_plugins, :plugin_paths

    def initialize
      @plugins = {}           # name => Plugin class
      @loaded_plugins = []    # names of successfully loaded plugins
      @plugin_paths = []      # directories to search for plugins
      @event_handlers = Hash.new { |h, k| h[k] = [] }
    end

    # Add a directory to search for plugins
    def add_plugin_path(path)
      full_path = File.expand_path(path)
      @plugin_paths << full_path unless @plugin_paths.include?(full_path)
    end

    # Discover plugins in a directory
    # Each subdirectory should contain a plugin.rb file
    def discover_plugins(directory)
      full_path = File.expand_path(directory)
      return unless File.directory?(full_path)

      add_plugin_path(full_path)

      Dir.glob(File.join(full_path, '*', 'plugin.rb')).each do |plugin_file|
        load_plugin_file(plugin_file)
      end
    end

    # Load a single plugin from its plugin.rb file
    def load_plugin_file(plugin_file)
      plugin_dir = File.dirname(plugin_file)
      plugin_name = File.basename(plugin_dir)

      begin
        # Load the plugin file
        require plugin_file

        # Find the plugin class (convention: Plugins::<Name>::Plugin)
        module_name = plugin_name.split('_').map(&:capitalize).join
        plugin_class = Object.const_get("Plugins::#{module_name}::Plugin")

        # Set the plugin directory
        plugin_class.plugin_dir(plugin_dir)

        # Register the plugin
        register_plugin(plugin_class)

        puts "[PluginManager] Discovered: #{plugin_class.plugin_name || plugin_name}"
      rescue LoadError => e
        warn "[PluginManager] Failed to load #{plugin_file}: #{e.message}"
      rescue NameError => e
        warn "[PluginManager] Plugin class not found in #{plugin_file}: #{e.message}"
      rescue StandardError => e
        warn "[PluginManager] Error loading #{plugin_file}: #{e.class}: #{e.message}"
      end
    end

    # Register a plugin class
    def register_plugin(plugin_class)
      name = plugin_class.plugin_name&.to_sym
      return unless name

      @plugins[name] = plugin_class
    end

    # Load all discovered plugins in dependency order
    def load_all
      # Build dependency graph and sort topologically
      sorted = topological_sort

      sorted.each do |plugin_name|
        load_plugin(plugin_name)
      end

      @loaded_plugins
    end

    # Load a specific plugin
    def load_plugin(name)
      name = name.to_sym
      plugin_class = @plugins[name]

      unless plugin_class
        warn "[PluginManager] Plugin not found: #{name}"
        return false
      end

      # Check dependencies
      unless plugin_class.dependencies_satisfied?(@loaded_plugins)
        missing = (plugin_class.dependencies || []) - @loaded_plugins
        warn "[PluginManager] Missing dependencies for #{name}: #{missing.join(', ')}"
        return false
      end

      # Load plugin components
      load_plugin_commands(plugin_class)
      load_plugin_models(plugin_class)

      # Enable the plugin
      plugin_class.enable!

      # Register event handlers
      plugin_class.event_handlers.each do |event, handlers|
        handlers.each { |handler| @event_handlers[event] << handler }
      end

      @loaded_plugins << name
      puts "[PluginManager] Loaded: #{name} v#{plugin_class.plugin_version}"
      true
    rescue StandardError => e
      warn "[PluginManager] Error loading #{name}: #{e.class}: #{e.message}"
      warn e.backtrace.first(5).join("\n")
      false
    end

    # Unload a plugin
    def unload_plugin(name)
      name = name.to_sym
      plugin_class = @plugins[name]
      return false unless plugin_class

      # Check if other plugins depend on this one
      dependents = @loaded_plugins.select do |loaded_name|
        deps = @plugins[loaded_name]&.dependencies || []
        deps.include?(name)
      end

      unless dependents.empty?
        warn "[PluginManager] Cannot unload #{name}: required by #{dependents.join(', ')}"
        return false
      end

      plugin_class.disable!
      @loaded_plugins.delete(name)
      puts "[PluginManager] Unloaded: #{name}"
      true
    end

    # Reload a plugin (for development)
    def reload_plugin(name)
      name = name.to_sym
      plugin_class = @plugins[name]
      return false unless plugin_class

      plugin_class.on_reload
      puts "[PluginManager] Reloaded: #{name}"
      true
    end

    # Emit an event to all registered handlers
    def emit_event(event_name, *args)
      handlers = @event_handlers[event_name.to_sym]
      handlers.each do |handler|
        handler.call(*args)
      rescue StandardError => e
        warn "[PluginManager] Event handler error for #{event_name}: #{e.message}"
      end
    end

    # Get plugin status information
    def status
      @plugins.map do |name, plugin_class|
        {
          name: name,
          version: plugin_class.plugin_version,
          description: plugin_class.plugin_description,
          dependencies: plugin_class.dependencies,
          loaded: @loaded_plugins.include?(name),
          enabled: plugin_class.enabled?
        }
      end
    end

    # Print plugin status to console
    def print_status
      puts "\n=== Firefly Plugins ==="
      status.each do |info|
        status_icon = info[:loaded] ? "[LOADED]" : "[      ]"
        deps = info[:dependencies]&.any? ? " (depends: #{info[:dependencies].join(', ')})" : ""
        puts "#{status_icon} #{info[:name]} v#{info[:version]}#{deps}"
        puts "         #{info[:description]}" if info[:description]
      end
      puts "=====================\n"
    end

    private

    # Load commands from a plugin's commands directory
    def load_plugin_commands(plugin_class)
      commands_path = plugin_class.full_commands_path
      return unless commands_path && File.directory?(commands_path)

      Dir.glob(File.join(commands_path, '**', '*.rb')).each do |file|
        require file
      end
    end

    # Load models/extensions from a plugin's models directory
    def load_plugin_models(plugin_class)
      models_path = plugin_class.full_models_path
      return unless models_path && File.directory?(models_path)

      Dir.glob(File.join(models_path, '**', '*.rb')).each do |file|
        require file
      end
    end

    # Topological sort of plugins by dependencies
    def topological_sort
      sorted = []
      visited = Set.new
      temp_visited = Set.new

      visit = lambda do |name|
        return if visited.include?(name)

        if temp_visited.include?(name)
          raise "Circular dependency detected involving: #{name}"
        end

        temp_visited.add(name)

        plugin_class = @plugins[name]
        (plugin_class&.dependencies || []).each do |dep|
          visit.call(dep) if @plugins.key?(dep)
        end

        temp_visited.delete(name)
        visited.add(name)
        sorted << name
      end

      @plugins.keys.each { |name| visit.call(name) }
      sorted
    end
  end
end
