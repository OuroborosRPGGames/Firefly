#!/usr/bin/env ruby
# frozen_string_literal: true

# Firefly Command Generator
#
# Usage:
#   bundle exec ruby scripts/generate_command.rb <plugin> <command_name> [options]
#
# Examples:
#   bundle exec ruby scripts/generate_command.rb core/social wave
#   bundle exec ruby scripts/generate_command.rb examples/magic fireball --category combat
#   bundle exec ruby scripts/generate_command.rb core/admin ban --admin
#
# Options:
#   --category <name>    Set command category (default: general)
#   --alias <name>       Add an alias (can specify multiple)
#   --admin              Mark as admin-only command
#   --help               Show this help

require 'fileutils'
require 'optparse'

class CommandGenerator
  TEMPLATE = <<~RUBY
    # frozen_string_literal: true

    module Commands
      module %<module_name>s
        class %<class_name>s < Commands::Base::Command
          command_name '%<command_name>s'
    %<aliases_line>s      category :%<category>s
          help_text '%<help_text>s'
          usage '%<usage>s'
          examples '%<example>s'

    %<requirements>s
          protected

          def perform_command(parsed_input)
            target = parsed_input[:text]&.strip

            # TODO: Implement command logic here
            #
            # Available helpers:
            #   - character          : Current character
            #   - character_instance : Current character instance
            #   - location           : Current room
            #   - broadcast_to_room(message) : Send to everyone in room
            #   - send_to_character(instance, message) : Send to specific player
            #   - find_character_by_name(name) : Find character in room
            #
            # Return types:
            #   - success_result(message, type:, data:)
            #   - error_result(message)

            success_result(
              "You %<verb>s.",
              type: :action,
              data: { action: '%<command_name>s', character: character.full_name }
            )
          end
        end
      end
    end

    Commands::Base::Registry.register(Commands::%<module_name>s::%<class_name>s)
  RUBY

  SPEC_TEMPLATE = <<~RUBY
    # frozen_string_literal: true

    require 'spec_helper'

    RSpec.describe Commands::%<module_name>s::%<class_name>s do
      let(:room) { create(:room) }
      let(:reality) { create(:reality) }
      let(:character) { create(:character) }
      let(:character_instance) do
        create(:character_instance,
               character: character,
               current_room: room,
               reality: reality,
               status: 'alive')
      end

      subject(:command) { described_class.new(character_instance) }

      describe 'command metadata' do
        it 'has correct command name' do
          expect(described_class.command_name).to eq('%<command_name>s')
        end

        it 'has help text' do
          expect(described_class.help_text).not_to be_empty
        end
      end

      describe '#execute' do
        context 'with no arguments' do
          it 'succeeds' do
            result = command.execute('%<command_name>s')
            expect(result[:success]).to be true
          end
        end

        # TODO: Add more test cases
        #
        # Examples:
        #
        # context 'when targeting another character' do
        #   let(:target) { create(:character) }
        #   let!(:target_instance) do
        #     create(:character_instance,
        #            character: target,
        #            current_room: room,
        #            reality: reality)
        #   end
        #
        #   it 'succeeds with valid target' do
        #     result = command.execute('%<command_name>s \#{target.forename}')
        #     expect(result[:success]).to be true
        #   end
        # end
        #
        # context 'when character is dead' do
        #   before { character_instance.update(status: 'dead') }
        #
        #   it 'fails with requires_alive' do
        #     result = command.execute('%<command_name>s')
        #     expect(result[:success]).to be false
        #   end
        # end
      end
    end
  RUBY

  def initialize
    @options = {
      category: 'general',
      aliases: [],
      admin: false,
    }
  end

  def run(args)
    parse_options!(args)

    if args.length < 2
      puts usage
      exit 1
    end

    plugin_path = args[0]
    command_name = args[1].downcase

    generate(plugin_path, command_name)
  end

  private

  def parse_options!(args)
    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} <plugin_path> <command_name> [options]"

      opts.on('--category NAME', 'Set command category') do |v|
        @options[:category] = v
      end

      opts.on('--alias NAME', 'Add an alias (can specify multiple)') do |v|
        @options[:aliases] << v
      end

      opts.on('--admin', 'Mark as admin-only command') do
        @options[:admin] = true
      end

      opts.on('--help', 'Show this message') do
        puts opts
        exit
      end
    end.parse!(args)
  end

  def generate(plugin_path, command_name)
    # Parse plugin path
    parts = plugin_path.split('/')
    category = parts[0]
    plugin_name = parts[1]

    # Build paths
    base_dir = File.expand_path('..', __dir__)
    plugin_dir = File.join(base_dir, 'plugins', category, plugin_name)
    commands_dir = File.join(plugin_dir, 'commands')
    spec_dir = File.join(plugin_dir, 'spec', 'commands')

    # Create directories
    FileUtils.mkdir_p(commands_dir)
    FileUtils.mkdir_p(spec_dir)

    # Generate files
    module_name = plugin_name.split('_').map(&:capitalize).join
    class_name = command_name.split('_').map(&:capitalize).join

    variables = {
      module_name: module_name,
      class_name: class_name,
      command_name: command_name,
      category: @options[:category],
      aliases_line: build_aliases_line,
      requirements: build_requirements,
      help_text: "#{class_name} does something",
      usage: "#{command_name} [target]",
      example: command_name,
      verb: command_name,
    }

    # Write command file
    command_file = File.join(commands_dir, "#{command_name}.rb")
    if File.exist?(command_file)
      puts "ERROR: Command file already exists: #{command_file}"
      exit 1
    end
    File.write(command_file, format(TEMPLATE, variables))
    puts "Created: #{command_file}"

    # Write spec file
    spec_file = File.join(spec_dir, "#{command_name}_spec.rb")
    if File.exist?(spec_file)
      puts "WARNING: Spec file already exists: #{spec_file}"
    else
      File.write(spec_file, format(SPEC_TEMPLATE, variables))
      puts "Created: #{spec_file}"
    end

    # Check if plugin.rb exists
    plugin_file = File.join(plugin_dir, 'plugin.rb')
    unless File.exist?(plugin_file)
      puts "\nWARNING: No plugin.rb found at #{plugin_file}"
      puts "You may need to create a plugin definition. See PLUGIN_DEVELOPMENT.md"
    end

    puts "\nDone! Remember to:"
    puts "  1. Implement the command logic in #{command_name}.rb"
    puts "  2. Add test cases in #{command_name}_spec.rb"
    puts "  3. Run: bundle exec rspec #{spec_file}"
    puts "  4. Restart the server to load the new command"
  end

  def build_aliases_line
    return '' if @options[:aliases].empty?

    aliases = @options[:aliases].map { |a| "'#{a}'" }.join(', ')
    "      aliases #{aliases}\n"
  end

  def build_requirements
    requirements = []
    requirements << '      requires_alive' # Default requirement
    requirements << '      requires :has_permission, :admin' if @options[:admin]
    requirements.join("\n")
  end

  def usage
    <<~USAGE
      Firefly Command Generator

      Usage:
        bundle exec ruby scripts/generate_command.rb <plugin_path> <command_name> [options]

      Examples:
        bundle exec ruby scripts/generate_command.rb core/social wave
        bundle exec ruby scripts/generate_command.rb examples/magic fireball --category combat
        bundle exec ruby scripts/generate_command.rb core/admin ban --admin

      Options:
        --category <name>    Set command category (default: general)
        --alias <name>       Add an alias (can specify multiple)
        --admin              Mark as admin-only command
        --help               Show this help

      Plugin path format: <category>/<plugin_name>
        - category: core, examples, etc.
        - plugin_name: navigation, combat, social, etc.
    USAGE
  end
end

CommandGenerator.new.run(ARGV)
