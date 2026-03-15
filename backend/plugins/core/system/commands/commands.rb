# frozen_string_literal: true

module Commands
  module System
    class Commands < ::Commands::Base::Command
      command_name 'commands'
      aliases 'cmds', 'cmdlist'
      category :system
      output_category :info
      help_text 'List all available commands'
      usage 'commands [category]'
      examples 'commands', 'commands navigation', 'commands combat'

      CATEGORY_DESCRIPTIONS = {
        building: 'World building and room creation',
        clothing: 'Wearing and managing clothing',
        combat: 'Fighting and restraining others',
        communication: 'Channels, mail, and messaging',
        crafting: 'Creating items and objects',
        economy: 'Money, shopping, and trading',
        entertainment: 'Games, dice, and media',
        events: 'Activities and group events',
        info: 'Information and lookup commands',
        inventory: 'Managing belongings and storage',
        navigation: 'Movement, posture, and vehicles',
        roleplaying: 'Emotes, speech, and scenes',
        social: 'Relationships and customization',
        staff: 'Staff and admin commands',
        system: 'System, help, and status'
      }.freeze

      protected

      def perform_command(parsed_input)
        filter_category = parsed_input[:text]&.strip&.downcase
        filter_category = nil if filter_category&.empty?

        available = ::Commands::Base::Registry.list_commands_for_character(character_instance)

        # Group by category
        by_category = available.group_by { |cmd| cmd[:category].to_s }

        if filter_category
          # Show only specified category
          category_commands = by_category[filter_category]

          if category_commands.nil? || category_commands.empty?
            available_categories = by_category.keys.sort.join(', ')
            return error_result(
              "Unknown category: '#{filter_category}'\n" \
              "Available categories: #{available_categories}"
            )
          end

          output = format_category(filter_category, category_commands)
        else
          # Show all categories
          output = format_all_categories(by_category)
        end

        success_result(
          output,
          type: :message,
          structured: {
            display_type: :command_list,
            categories: by_category.transform_values { |cmds| cmds.map { |c| c[:name] } }
          }
        )
      end

      private

      def format_all_categories(by_category)
        categories = by_category.keys.sort

        lines = ['<h4>Available Command Categories</h4>']
        lines << '<table>'

        # Split into two columns
        mid = (categories.size / 2.0).ceil
        left_col = categories[0...mid]
        right_col = categories[mid..] || []

        left_col.each_with_index do |cat, i|
          right_cat = right_col[i]
          lines << '<tr>'
          lines << "  <td>#{cat}</td>"
          lines << "  <td>#{right_cat}</td>" if right_cat
          lines << '</tr>'
        end

        lines << '</table>'
        lines << ''
        lines << "Type 'commands &lt;category&gt;' for commands in a category."
        lines.join("\n")
      end

      def format_category(category, commands)
        description = CATEGORY_DESCRIPTIONS[category.to_sym] || "#{category.capitalize} commands"
        lines = ["#{category.upcase} - #{description}"]
        lines << ""

        commands.sort_by { |c| c[:name] }.each do |cmd|
          symbol = cmd[:status] == :unavailable ? "\u25cb" : "\u25cf"
          help_text = cmd[:help] || 'No description'
          lines << "  #{symbol} #{cmd[:name]} - #{help_text}"
        end

        lines << ""
        lines << "Type 'help <command>' for aliases and detailed usage."
        lines.join("\n")
      end
    end
  end
end

# Auto-register the command when the file is loaded
Commands::Base::Registry.register(Commands::System::Commands)
