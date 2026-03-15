# frozen_string_literal: true

module Commands
  module Storage
    class SaveGradient < Commands::Base::Command
      command_name 'save gradient'
      aliases 'savegrad'
      category :inventory
      help_text 'Save a color gradient to your library'
      usage 'save gradient <codes> as <name>'
      examples 'save gradient #ff0000,#00ff00 as christmas', 'savegrad #000000,#ffffff as monochrome'

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]&.strip
        return error_result("Usage: save gradient <codes> as <name>") if input.nil? || input.empty?

        # Parse "<codes> as <name>" format
        codes, name = parse_gradient_input(input)
        return error_result("Usage: save gradient <codes> as <name>") unless codes && name

        # Validate gradient format (comma-separated hex codes)
        unless valid_gradient?(codes)
          return error_result("Invalid gradient format. Use comma-separated hex codes like: #ff0000,#00ff00,#0000ff")
        end

        # Check for duplicate name
        existing = MediaLibrary.find_by_name(character, name)
        if existing
          return error_result("You already have something saved as '#{name}'. Use 'library delete #{name}' first.")
        end

        # Create media library entry (using actual DB column names)
        MediaLibrary.create(
          character_id: character.id,
          mtype: 'gradient',
          mname: name,
          mtext: codes
        )

        success_result(
          "Gradient saved as '#{name}'.",
          type: :message,
          data: {
            action: 'save_gradient',
            name: name,
            codes: codes
          }
        )
      end

      private

      def parse_gradient_input(input)
        # Split on " as " to separate codes from name
        parts = input.split(/\s+as\s+/i, 2)
        return [nil, nil] unless parts.length == 2

        codes = parts[0].strip
        name = parts[1].strip

        return [nil, nil] if codes.empty? || name.empty?

        [codes, name]
      end

      def valid_gradient?(codes)
        # Gradient should be comma-separated hex codes
        colors = codes.split(',').map(&:strip)
        return false if colors.length < 2

        # Each color should be a valid hex code (3 or 6 characters)
        colors.all? { |c| c.match?(/^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/) }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Storage::SaveGradient)
