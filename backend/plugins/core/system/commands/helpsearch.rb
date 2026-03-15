# frozen_string_literal: true

module Commands
  module System
    class Helpsearch < ::Commands::Base::Command
      command_name 'helpsearch'
      aliases 'searchhelp', 'findhelp'
      category :system
      help_text 'Search help files for matching topics'
      usage 'helpsearch <query> [category]'
      examples 'helpsearch combat', 'helpsearch sword navigation', 'helpsearch look'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip&.split(/\s+/) || []

        if args.empty?
          return error_result("Search what? Usage: helpsearch <query> [category]")
        end

        # Check if last arg is a category filter
        query, category = parse_query_and_category(args)

        options = {}
        options[:category] = category if category
        options[:limit] = 15

        results = Firefly::HelpManager.search(query, options)

        if results.empty?
          no_results_message(query, category)
        else
          format_results(query, results, category)
        end
      end

      private

      def parse_query_and_category(args)
        # Known categories
        categories = %w[navigation combat communication social economy crafting system info inventory events clothing]

        if args.length > 1 && categories.include?(args.last.downcase)
          category = args.pop.downcase
          query = args.join(' ')
          [query, category]
        else
          [args.join(' '), nil]
        end
      end

      def no_results_message(query, category)
        lines = ["No help topics found matching '#{query}'"]
        lines << " in category '#{category}'" if category
        lines << ""
        lines << "Try:"
        lines << "  - Using fewer or different keywords"
        lines << "  - Removing the category filter" if category
        lines << "  - Using 'help <command>' for specific command help"
        lines << "  - Using 'commands' to see all available commands"

        error_result(lines.join("\n"))
      end

      def format_results(query, results, category)
        lines = ["Help Search Results for '#{query}'"]
        lines << " (category: #{category})" if category
        lines << "=" * 40
        lines << ""

        results.each do |result|
          cmd_or_topic = result[:command] || result[:topic]
          summary = result[:summary] || "No description"
          cat = result[:category] ? "[#{result[:category]}]" : ""

          lines << "  #{cmd_or_topic} #{cat}"
          lines << "    #{truncate_summary(summary)}"
          lines << ""
        end

        lines << "Found #{results.length} result(s)."
        lines << "Type 'help <topic>' for detailed information."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'search',
            query: query,
            category: category,
            count: results.length,
            results: results
          }
        )
      end

      def truncate_summary(summary, max_length = 60)
        return summary if summary.length <= max_length

        "#{summary[0...max_length]}..."
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::Helpsearch)
