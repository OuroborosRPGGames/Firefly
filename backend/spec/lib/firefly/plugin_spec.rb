# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/firefly/plugin'
require_relative '../../../lib/firefly/plugin_manager'

RSpec.describe Firefly::Plugin do
  # Create a test plugin class
  before(:all) do
    module Plugins
      module TestExample
        class Plugin < Firefly::Plugin
          name :test_example
          version "1.0.0"
          description "A test plugin for specs"

          depends_on :core_feature

          @@enable_called = false
          @@disable_called = false

          def self.on_enable
            @@enable_called = true
          end

          def self.on_disable
            @@disable_called = true
          end

          def self.enable_called?
            @@enable_called
          end

          def self.disable_called?
            @@disable_called
          end

          def self.reset_flags!
            @@enable_called = false
            @@disable_called = false
          end
        end
      end
    end
  end

  let(:plugin_class) { Plugins::TestExample::Plugin }

  before do
    plugin_class.reset_flags!
  end

  describe 'metadata' do
    it 'has a name' do
      expect(plugin_class.plugin_name).to eq(:test_example)
    end

    it 'has a version' do
      expect(plugin_class.plugin_version).to eq("1.0.0")
    end

    it 'has a description' do
      expect(plugin_class.plugin_description).to eq("A test plugin for specs")
    end

    it 'has dependencies' do
      expect(plugin_class.dependencies).to include(:core_feature)
    end
  end

  describe '#dependencies_satisfied?' do
    it 'returns false when dependencies are not loaded' do
      expect(plugin_class.dependencies_satisfied?([])).to be false
    end

    it 'returns true when all dependencies are loaded' do
      expect(plugin_class.dependencies_satisfied?([:core_feature])).to be true
    end
  end

  describe 'lifecycle hooks' do
    it 'calls on_enable when enabled' do
      # Satisfy dependencies first
      allow(plugin_class).to receive(:dependencies_satisfied?).and_return(true)

      expect(plugin_class.enable_called?).to be false
      plugin_class.enable!
      expect(plugin_class.enable_called?).to be true
    end

    it 'calls on_disable when disabled' do
      plugin_class.instance_variable_set(:@enabled, true)

      expect(plugin_class.disable_called?).to be false
      plugin_class.disable!
      expect(plugin_class.disable_called?).to be true
    end

    it 'does not re-enable if already enabled' do
      plugin_class.instance_variable_set(:@enabled, true)
      plugin_class.reset_flags!

      plugin_class.enable!
      expect(plugin_class.enable_called?).to be false
    end
  end

  describe 'path configuration' do
    it 'has default commands path' do
      expect(plugin_class.commands_path).to eq('commands')
    end

    it 'has default models path' do
      expect(plugin_class.models_path).to eq('models')
    end

    it 'has default routes path' do
      expect(plugin_class.routes_path).to eq('routes')
    end
  end
end

RSpec.describe Firefly::PluginManager do
  let(:manager) { Firefly::PluginManager.new }

  describe '#register_plugin' do
    before(:all) do
      module Plugins
        module ManagerTest
          class Plugin < Firefly::Plugin
            name :manager_test
            version "1.0.0"
            description "Plugin for manager tests"
          end
        end
      end
    end

    it 'registers a plugin' do
      manager.register_plugin(Plugins::ManagerTest::Plugin)
      expect(manager.plugins).to have_key(:manager_test)
    end
  end

  describe '#status' do
    before(:all) do
      module Plugins
        module StatusTest
          class Plugin < Firefly::Plugin
            name :status_test
            version "2.0.0"
            description "Status test plugin"
          end
        end
      end
    end

    it 'returns status information for plugins' do
      manager.register_plugin(Plugins::StatusTest::Plugin)
      status = manager.status

      expect(status.length).to eq(1)
      expect(status.first[:name]).to eq(:status_test)
      expect(status.first[:version]).to eq("2.0.0")
      expect(status.first[:loaded]).to be false
    end
  end

  describe '#emit_event' do
    it 'calls registered event handlers' do
      handler_called = false

      # Create a plugin with an event handler
      module Plugins
        module EventTest
          class Plugin < Firefly::Plugin
            name :event_test
            version "1.0.0"

            @@handler_called = false

            on_event :test_event do |arg|
              @@handler_called = arg
            end

            def self.handler_called
              @@handler_called
            end
          end
        end
      end

      manager.register_plugin(Plugins::EventTest::Plugin)

      # Load the plugin (which registers event handlers)
      manager.load_plugin(:event_test)

      # Emit the event
      manager.emit_event(:test_event, true)

      expect(Plugins::EventTest::Plugin.handler_called).to be true
    end
  end
end
