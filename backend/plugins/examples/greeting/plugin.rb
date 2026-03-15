# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Greeting
    # Greeting Plugin - A complete example demonstrating all plugin features
    #
    # This plugin serves as a reference implementation showing:
    # - Command registration with aliases and requirements
    # - Model extensions (adding methods to core models)
    # - Event handlers
    # - Plugin configuration
    #
    # Use this as a template when creating new plugins.
    #
    class Plugin < Firefly::Plugin
      name :greeting
      version '1.0.0'
      description 'Example plugin demonstrating greetings and social interactions'

      # Dependencies - this plugin requires these plugins to be loaded first
      # Uncomment if your plugin has dependencies:
      # depends_on :communication, :navigation

      # Configure paths for auto-discovery
      commands_path 'commands'
      models_path "models"

      # Track greetings for stats
      @greeting_count = 0

      class << self
        attr_accessor :greeting_count
      end

      def self.on_enable
        puts "[Greeting] Plugin enabled - ready to spread joy!"
        @greeting_count = 0
      end

      def self.on_disable
        puts "[Greeting] Plugin disabled - #{@greeting_count} greetings were made"
      end

      def self.on_reload
        puts "[Greeting] Plugin reloaded"
        # Preserve greeting count on reload
        super
      end

      # Event handlers - respond to game events
      on_event :character_enters_room do |character_instance, room|
        # Could auto-greet NPCs or trigger welcome messages
        # puts "[Greeting] #{character_instance.character.name} entered #{room.name}"
      end

      on_event :character_logged_in do |character_instance|
        # Welcome back message
        # puts "[Greeting] Welcome back, #{character_instance.character.name}!"
      end

      # Custom event that this plugin emits
      # Other plugins can listen to :greeting_performed
      # on_event :greeting_performed do |greeter, target, greeting_type|
      #   # Track stats, achievements, etc.
      # end

      # Model extension example - adds greeting-related methods to Character
      # Uncomment to enable:
      # extend_model Character, GreetingExtensions

      # Helper method for other plugins/commands to use
      def self.random_greeting
        greetings = [
          "Hello",
          "Hi there",
          "Greetings",
          "Hey",
          "Good day",
          "Salutations",
          "Howdy"
        ]
        greetings.sample
      end

      def self.increment_count
        @greeting_count += 1
      end
    end

    # Model extension module - adds methods to Character model
    # To use: uncomment extend_model line in Plugin class
    module GreetingExtensions
      def self.included(base)
        # Add associations
        # base.one_to_many :greeting_logs

        # Add class methods
        base.extend(ClassMethods)
      end

      module ClassMethods
        def most_friendly
          # Find character with most greetings
          # order(:greeting_count).last
        end
      end

      # Instance methods added to Character
      def greet(target)
        greeting = Plugins::Greeting::Plugin.random_greeting
        "#{full_name} says, '#{greeting}, #{target.full_name}!'"
      end

      def greeting_count
        # greeting_logs_dataset.count
        0
      end
    end
  end
end
