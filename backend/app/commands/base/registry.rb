# frozen_string_literal: true

require_relative '../../helpers/string_helper'
require_relative 'context_resolver'
require_relative 'command_suggester'

module Commands
  module Base
    class Registry
      extend StringHelper
      @commands = {}
      @aliases = {}
      @multiword_aliases = {}   # Multi-word aliases like "look at" => command_class
      @contextual_aliases = {}  # context => { alias => command_class }
      @prefix_commands = {}     # For partial matching

      class << self
        include ContextResolver
        include CommandSuggester

        attr_reader :commands, :aliases, :multiword_aliases, :contextual_aliases

        # Clear all registrations (for reloading)
        def clear!
          @commands = {}
          @aliases = {}
          @multiword_aliases = {}
          @contextual_aliases = {}
          @prefix_commands = {}
        end

        # Reload all commands from plugin directories
        # Uses load instead of require to pick up changes
        # Commands self-register via Commands::Base::Registry.register(...) at the bottom of each file.
        def reload_commands!
          warn "[Registry] Reloading all commands..." if ENV['DEBUG']

          # Clear existing registrations
          clear!

          # Track files we've loaded
          loaded_count = 0

          # Find all command files in plugins (excluding spec directories)
          plugin_dirs = Dir.glob(File.join(File.dirname(__FILE__), '..', '..', '..', 'plugins', '**', 'commands', '*.rb'))
            .reject { |f| f.include?('/spec/') || f.end_with?('_spec.rb') }

          plugin_dirs.each do |file|
            begin
              # Use load instead of require to reload even if already required
              load file
              loaded_count += 1
            rescue StandardError => e
              warn "[Registry] Error loading #{file}: #{e.message}"
            end
          end

          warn "[Registry] Reloaded #{loaded_count} command files, #{@commands.size} commands registered" if ENV['DEBUG']

          {
            files_loaded: loaded_count,
            commands_registered: @commands.size,
            command_names: @commands.keys.sort
          }
        end

        def register(command_class)
          command_name = command_class.command_name
          @commands[command_name] = command_class

          # Register aliases
          (command_class.aliases || []).each do |alias_entry|
            if alias_entry.is_a?(Hash)
              alias_name = alias_entry[:name]
              context = alias_entry[:context]

              if context
                # Context-specific alias
                @contextual_aliases[context] ||= {}
                @contextual_aliases[context][alias_name] = command_class
              elsif alias_name.include?(' ')
                # Multi-word alias (e.g., "look at")
                @multiword_aliases[alias_name.downcase] = command_class
              else
                # Global alias
                @aliases[alias_name] = command_class
              end
            else
              alias_str = alias_entry.to_s
              if alias_str.include?(' ')
                # Multi-word alias
                @multiword_aliases[alias_str.downcase] = command_class
              else
                # Simple string alias (backward compatibility)
                @aliases[alias_str] = command_class
              end
            end
          end

          # Register for prefix matching (commands with short names)
          @prefix_commands[command_name] = command_class

          if ENV['DEBUG']
            aliases_display = command_class.alias_names.join(', ')
            warn "[Registry] Registered command: #{command_name} (#{aliases_display})"
          end
        end

        # Add an alias to an existing command dynamically
        def add_alias(alias_name, command_name_or_class, context: nil)
          command_class = command_name_or_class.is_a?(Class) ?
            command_name_or_class :
            @commands[command_name_or_class.to_s]

          return false unless command_class

          if context
            @contextual_aliases[context] ||= {}
            @contextual_aliases[context][alias_name.to_s] = command_class
          else
            @aliases[alias_name.to_s] = command_class
          end
          true
        end

        # Remove an alias
        def remove_alias(alias_name, context: nil)
          if context
            @contextual_aliases[context]&.delete(alias_name.to_s)
          else
            @aliases.delete(alias_name.to_s)
          end
        end

        # Find a command with context awareness
        # Returns [command_class, words_consumed] where words_consumed indicates
        # how many words were matched by a multi-word alias
        def find_command(input, context: nil)
          return [nil, 0] if blank?(input)

          words = input.strip.split
          return [nil, 0] if words.empty?

          command_word = words.first.downcase

          # 0. Try multi-word command name match first (e.g., "say to", "say through")
          # Check from longest to shortest possible matches
          @commands.each do |cmd_name, cmd_class|
            next unless cmd_name.include?(' ')
            cmd_words = cmd_name.split
            next if cmd_words.length > words.length

            input_phrase = words.first(cmd_words.length).map(&:downcase).join(' ')
            if input_phrase == cmd_name
              return [cmd_class, cmd_words.length]
            end
          end

          # 1. Try multi-word alias match (highest priority for natural phrases)
          # Check from longest to shortest possible matches
          @multiword_aliases.each do |alias_phrase, cmd_class|
            alias_words = alias_phrase.split
            next if alias_words.length > words.length

            # Check if input starts with this alias phrase
            input_phrase = words.first(alias_words.length).map(&:downcase).join(' ')
            if input_phrase == alias_phrase
              return [cmd_class, alias_words.length]
            end
          end

          # 2. Try contextual alias match (takes priority when context is active)
          if context
            contexts = context.is_a?(Array) ? context : [context]
            contexts.each do |ctx|
              if @contextual_aliases[ctx]
                command_class = @contextual_aliases[ctx][command_word]
                return [command_class, 1] if command_class
              end
            end
          end

          # 3. Try exact command name match (single-word commands)
          command_class = @commands[command_word]
          return [command_class, 1] if command_class

          # 3. Try global alias match
          command_class = @aliases[command_word]
          return [command_class, 1] if command_class

          # 4. Try prefix match (minimum 2 characters)
          if command_word.length >= 2
            command_class = find_by_prefix(command_word)
            return [command_class, 1] if command_class
          end

          # 5. Handle special shortcuts
          case command_word[0]
          when ':', '.'
            return [emote_command_class, 0]
          when '"', "'"
            return [say_command_class, 0]
          end

          # 6. No command found - return nil (don't default to say)
          [nil, 0]
        end

        def execute_command(character_instance, input, request_env: {})
          # Determine current context from character state
          context = determine_context(character_instance)

          command_class, words_consumed = find_command(input, context: context)

          unless command_class
            return unknown_command_result(input, context)
          end

          # Pass original input - the command's parse_input will handle detecting
          # which multi-word alias was used and extract the command word properly
          adjusted_input = input

          command = command_class.new(character_instance, request_env: request_env)
          command.execute(adjusted_input)
        end

        # Generate helpful error message for unknown commands
        def unknown_command_result(input, context)
          return { success: false, error: "No command provided.", target_panel: :right_observe_window, output_category: :info } if blank?(input)

          words = input.strip.split
          attempted_command = words.first

          suggestions = suggest_commands(input, context: context)

          error_lines = ["That's not a valid command."]
          error_lines << "Type 'commands' to see available commands."

          if suggestions.any?
            error_lines << ""
            error_lines << "Did you mean: #{suggestions.join(', ')}?"
          end

          {
            success: false,
            error: error_lines.join("\n"),
            attempted_command: attempted_command,
            suggestions: suggestions,
            target_panel: :right_observe_window,
            output_category: :info
          }
        end

        def list_commands_for_character(character_instance)
          context = determine_context(character_instance)
          available_commands = []

          @commands.each do |name, command_class|
            command = command_class.new(character_instance)

            # Check if command can be executed in current context
            next unless command.can_execute?

            # Include commands that have met requirements OR no requirements
            requirements_status = if command_class.requirements.empty?
              :available
            elsif command.requirements_met?
              :available
            else
              :unavailable
            end

            available_commands << {
              name: name,
              aliases: build_alias_list(command_class, context),
              category: command_class.category,
              help: command_class.help_text,
              usage: command_class.usage,
              examples: command_class.examples,
              status: requirements_status,
              requirements: requirements_status == :unavailable ?
                command.unmet_requirements.map { |r| r[:message] }.compact : []
            }
          end

          available_commands.sort_by { |cmd| [cmd[:category].to_s, cmd[:name]] }
        end

        # List commands available in a specific context
        def commands_for_context(context)
          base_commands = @commands.keys
          context_aliases = @contextual_aliases[context]&.keys || []
          global_aliases = @aliases.keys

          {
            commands: base_commands,
            aliases: global_aliases,
            context_aliases: context_aliases
          }
        end

        private

        # determine_context, in_active_delve?, in_active_activity?
        # are provided by ContextResolver

        # Build list of aliases including contextual ones
        def build_alias_list(command_class, context)
          aliases = command_class.alias_names.dup

          # Add contextual aliases if in that context
          if context
            contexts = context.is_a?(Array) ? context : [context]
            contexts.each do |ctx|
              @contextual_aliases[ctx]&.each do |alias_name, cmd_class|
                aliases << alias_name if cmd_class == command_class
              end
            end
          end

          aliases.uniq
        end

        # Find command by prefix matching
        def find_by_prefix(prefix)
          # Exact prefix match on command names
          matches = @commands.keys.select { |name| name.start_with?(prefix) }

          # Also check aliases
          alias_matches = @aliases.keys.select { |name| name.start_with?(prefix) }

          # Prefer exact matches, then command names, then aliases
          if matches.length == 1
            return @commands[matches.first]
          elsif alias_matches.length == 1
            return @aliases[alias_matches.first]
          end

          # Ambiguous - return nil (could show suggestions instead)
          nil
        end

        def say_command_class
          @commands['say'] || @aliases['say']
        end

        def emote_command_class
          @commands['emote'] || @aliases['emote']
        end

        # suggest_commands, levenshtein_distance
        # are provided by CommandSuggester

        # Make suggest_commands accessible to the help command
        public :suggest_commands

        # Find a command class by context name, normalizing underscores and spaces.
        # Used by form handlers and input interceptors.
        # @param command_name [String] command name to look up
        # @return [Class, nil] the command class or nil if not found
        def find_by_context(command_name)
          normalized = command_name.to_s.strip.downcase
          return nil if normalized.empty?

          [normalized, normalized.tr('_', ' '), normalized.delete('_')].uniq.each do |candidate|
            klass = commands[candidate] || aliases[candidate]
            return klass if klass
          end

          nil
        end

        public :find_by_context
      end
    end
  end
end
