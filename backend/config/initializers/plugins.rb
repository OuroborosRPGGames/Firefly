# frozen_string_literal: true

# Plugin initialization
#
# This file sets up the Firefly plugin system and loads all core plugins.
# Plugins are loaded in dependency order (topologically sorted).
#
# Plugin directories:
# - plugins/core/     - Required system plugins
# - plugins/optional/ - Optional feature plugins (not yet implemented)
# - plugins/custom/   - User-created plugins (gitignored)

require_relative '../../lib/firefly/plugin'
require_relative '../../lib/firefly/plugin_manager'

# Create the global plugin manager instance
PLUGIN_MANAGER = Firefly::PluginManager.new

# Discover plugins from standard locations
plugins_dir = File.expand_path('../../plugins', __dir__)

# Load core plugins (required)
core_plugins_dir = File.join(plugins_dir, 'core')
if File.directory?(core_plugins_dir)
  PLUGIN_MANAGER.discover_plugins(core_plugins_dir)
end

# Load optional plugins if directory exists
optional_plugins_dir = File.join(plugins_dir, 'optional')
if File.directory?(optional_plugins_dir)
  PLUGIN_MANAGER.discover_plugins(optional_plugins_dir)
end

# Load custom plugins if directory exists (user-created)
custom_plugins_dir = File.join(plugins_dir, 'custom')
if File.directory?(custom_plugins_dir)
  PLUGIN_MANAGER.discover_plugins(custom_plugins_dir)
end

# Load example plugins (for reference/testing)
examples_plugins_dir = File.join(plugins_dir, 'examples')
if File.directory?(examples_plugins_dir)
  PLUGIN_MANAGER.discover_plugins(examples_plugins_dir)
end

# Load all plugins (this loads commands, models, and enables plugins)
# Note: This should be called after base command classes are loaded
def load_firefly_plugins!
  PLUGIN_MANAGER.load_all
  PLUGIN_MANAGER.print_status if ENV['RACK_ENV'] == 'development'
end

# Helper to access the plugin manager
def plugin_manager
  PLUGIN_MANAGER
end
