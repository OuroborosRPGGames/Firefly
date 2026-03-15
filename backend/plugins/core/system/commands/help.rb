# frozen_string_literal: true

module Commands
  module System
    class Help < ::Commands::Base::Command
      command_name 'help'
      aliases 'h', '?'
      category :system
      output_category :info
      help_text 'Get help on commands and topics'
      usage 'help [command or topic] | help system <name> | help systems'
      examples 'help', 'help look', 'help navigation', 'help system combat', 'help systems'

      EMBEDDING_SIMILARITY_THRESHOLD = 0.8

      protected

      def perform_command(parsed_input)
        topic = parsed_input[:text]&.strip

        if topic.nil? || topic.empty?
          show_general_help
        elsif topic.downcase == 'systems'
          show_systems_list
        elsif topic.downcase.start_with?('system ')
          system_name = topic[7..-1].strip
          show_system_help(system_name)
        else
          show_topic_help(topic)
        end
      end

      private

      def show_general_help
        lines = ["Welcome to the Help System"]
        lines << "=" * 40
        lines << ""
        lines << "Common commands:"
        lines << "  look       - Look at your surroundings or a target"
        lines << "  say        - Say something out loud"
        lines << "  emote      - Perform an action"
        lines << "  move       - Move in a direction"
        lines << "  commands   - List all available commands"
        lines << ""
        lines << "Type 'help <command>' for detailed help."
        lines << "Type 'commands' to see all available commands."

        success_result(
          lines.join("\n"),
          type: :message,
          structured: { display_type: :help }
        )
      end

      def show_topic_help(topic)
        # First try to find a command
        command_class = find_command_class(topic)

        if command_class
          show_command_help(command_class)
        else
          # Try the help database
          help_content = Firefly::HelpManager.get_help(topic, character_instance)

          if help_content
            show_database_help(help_content)
          else
            suggest_help(topic)
          end
        end
      end

      def find_command_class(name)
        name_lower = name.downcase

        # Check exact command names
        if ::Commands::Base::Registry.commands[name_lower]
          return ::Commands::Base::Registry.commands[name_lower]
        end

        # Check aliases
        if ::Commands::Base::Registry.aliases[name_lower]
          return ::Commands::Base::Registry.aliases[name_lower]
        end

        nil
      end

      def show_command_help(command_class)
        lines = ["<h3>Help: #{command_class.command_name.upcase}</h3>"]
        lines << command_class.help_text if command_class.help_text
        lines << ""

        if command_class.usage
          lines << "Usage: #{command_class.usage}"
          lines << ""
        end

        if command_class.alias_names.any?
          lines << "Aliases: #{command_class.alias_names.join(', ')}"
          lines << ""
        end

        if command_class.examples.any?
          lines << "Examples:"
          command_class.examples.each do |example|
            lines << "  #{example}"
          end
          lines << ""
        end

        lines << "Category: #{command_class.category}"

        # Add staff information if viewer is staff
        if staff_view?
          lines << ""
          lines << "<h4>Staff Information</h4>"

          # Get helpfile for this command if it exists
          helpfile = Helpfile.first(command_name: command_class.command_name)
          if helpfile
            if helpfile.source_file
              source = helpfile.source_file
              source += ":#{helpfile.source_line}" if helpfile.source_line
              lines << "Source: #{source}"
            end

            if helpfile.requirements_summary && !helpfile.requirements_summary.empty?
              lines << "Requirements: #{helpfile.requirements_summary}"
            end

            if helpfile.staff_notes && !helpfile.staff_notes.empty?
              lines << ""
              lines << "Implementation Notes:"
              lines << helpfile.staff_notes
            end

            refs = helpfile.parsed_code_references
            if refs.any?
              lines << ""
              lines << "Related Files:"
              refs.each do |ref|
                desc = ref['desc'] || ref['description'] || ''
                file_ref = ref['file']
                file_ref += ":#{ref['line']}" if ref['line']
                lines << "  - #{file_ref}#{desc.empty? ? '' : " (#{desc})"}"
              end
            end
          else
            # Fallback: Try to get source location from command class
            source_info = Helpfile.extract_source_info(command_class)
            if source_info[:file]
              source = source_info[:file]
              source += ":#{source_info[:line]}" if source_info[:line]
              lines << "Source: #{source}"
            end
          end
        end

        success_result(
          lines.join("\n"),
          type: :message,
          structured: {
            display_type: :help,
            command: command_class.command_name,
            help_text: command_class.help_text,
            usage: command_class.usage,
            aliases: command_class.alias_names,
            examples: command_class.examples,
            category: command_class.category
          }
        )
      end

      def show_database_help(help_content)
        lines = ["Help: #{help_content[:topic] || help_content[:command]}"]
        lines << "=" * 40
        lines << ""
        lines << help_content[:content] if help_content[:content]

        success_result(
          lines.join("\n"),
          type: :message,
          structured: help_content.merge(display_type: :help)
        )
      end

      def suggest_help(topic)
        suggestions = Firefly::HelpManager.suggest_topics(topic, 5)

        # Also check command names
        command_suggestions = ::Commands::Base::Registry.suggest_commands(topic)
        suggestions = (suggestions + command_suggestions).uniq.first(5)

        # Fetch embedding results once — used for both similarity fallback and autohelper
        embedding_results = fetch_embedding_results(topic)

        # Try embedding similarity before expensive autohelper
        embedding_result = try_embedding_match(embedding_results)
        return embedding_result if embedding_result

        # Check if AI autohelper should trigger
        # Triggers when: no suggestions found OR topic ends with "?"
        if defined?(AutohelperService) && AutohelperService.should_trigger?(topic, has_matches: suggestions.any?)
          autohelp_result = AutohelperService.assist(
            query: topic,
            character_instance: character_instance,
            suggestions: suggestions,
            cached_helpfiles: embedding_results
          )

          if autohelp_result[:success]
            return format_autohelp_response(topic, autohelp_result, suggestions)
          end
        end

        # Fall back to standard suggestion display
        if suggestions.any?
          lines = ["No help found for '#{topic}'."]
          lines << ''
          lines << "Did you mean: #{suggestions.join(', ')}?"
          lines << ''
          lines << "Type 'commands' to see all available commands."
          lines << "Type 'help systems' to see system overviews."
        else
          lines = ["No help found for '#{topic}'."]
          lines << ''
          lines << "Type 'commands' to see all available commands."
          lines << "Type 'help systems' to see system overviews."
        end

        error_result(lines.join("\n"))
      end

      # Format AI autohelper response
      def format_autohelp_response(topic, result, suggestions)
        lines = ["<h3>AI Help: #{topic}</h3>"]
        lines << ''
        lines << result[:response]
        lines << ''

        if result[:sources]&.any?
          lines << "Related topics: #{result[:sources].join(', ')}"
        end

        if suggestions&.any?
          lines << "Similar commands: #{suggestions.join(', ')}"
        end

        lines << ''
        lines << "[AI-generated. For official help, try 'help <command>'.]"

        success_result(
          lines.join("\n"),
          type: :message,
          structured: {
            display_type: :autohelp,
            query: topic,
            sources: result[:sources] || [],
            suggestions: suggestions || []
          }
        )
      end

      # Show list of all help systems
      def show_systems_list
        return error_result('Help systems not available.') unless defined?(HelpSystem)

        systems = HelpSystem.ordered
        return error_result('No help systems defined.') if systems.empty?

        lines = ['<h3>Help Systems</h3>']
        lines << 'Type "help system <name>" for details.'
        lines << ''

        systems.each do |sys|
          name = sys.display_name || sys.name.capitalize
          lines << "  #{sys.name.ljust(15)} - #{sys.summary || name}"
        end

        success_result(
          lines.join("\n"),
          type: :message,
          structured: { display_type: :help_systems }
        )
      end

      # Show help for a specific system
      def show_system_help(system_name)
        return error_result('Help systems not available.') unless defined?(HelpSystem)

        sys = HelpSystem.find_by_name(system_name)
        return suggest_system(system_name) unless sys

        # Use staff or player display based on viewer
        content = staff_view? ? sys.to_staff_display : sys.to_player_display

        success_result(
          content,
          type: :message,
          structured: sys.to_agent_format.merge(display_type: :help_system)
        )
      end

      # Suggest similar systems when not found
      def suggest_system(name)
        return error_result('Help systems not available.') unless defined?(HelpSystem)

        systems = HelpSystem.ordered
        suggestions = systems.map(&:name).select { |n| n.include?(name.downcase) || name.downcase.include?(n) }

        lines = ["No help system found for '#{name}'."]
        lines << ''

        if suggestions.any?
          lines << "Did you mean: #{suggestions.join(', ')}?"
          lines << ''
        end

        lines << 'Available systems:'
        systems.each { |s| lines << "  - #{s.name}" }

        error_result(lines.join("\n"))
      end

      # Fetch embedding results once for reuse by both fallback and autohelper
      def fetch_embedding_results(topic)
        return [] unless defined?(Helpfile)

        Helpfile.search_helpfiles(topic, limit: 5)
      rescue StandardError => e
        warn "[Help] Embedding search failed: #{e.message}"
        []
      end

      def try_embedding_match(results)
        return nil if results.empty?

        top = results.first
        return nil unless top[:similarity] >= EMBEDDING_SIMILARITY_THRESHOLD

        helpfile = top[:helpfile]
        return nil if helpfile.hidden || helpfile.admin_only

        help_content = Firefly::HelpManager.get_help(helpfile.command_name, character_instance)
        return nil unless help_content

        show_database_help(help_content)
      end

      # Check if current viewer should see staff information
      def staff_view?
        return false unless character_instance

        character_instance.character&.staff? ||
          character_instance.character&.user&.admin?
      end
    end
  end
end

# Auto-register the command when the file is loaded
Commands::Base::Registry.register(Commands::System::Help)
