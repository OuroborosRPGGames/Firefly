# frozen_string_literal: true

module Commands
  module Storage
    class SaveLocation < Commands::Base::Command
      command_name 'save location'
      aliases 'saveloc', 'bookmark'
      category :inventory
      help_text 'Save your current location as a bookmark'
      usage 'save location as <name>'
      examples 'save location as home', 'saveloc as work', 'bookmark as secret'

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]&.strip
        return error_result("Usage: save location as <name>") if input.nil? || input.empty?

        # Parse "as <name>" format
        name = parse_name(input)
        return error_result("Usage: save location as <name>") unless name

        # Check for duplicate name
        existing = SavedLocation.find_by_name(character, name)
        if existing
          return error_result("You already have a location saved as '#{name}'. Use 'library delete #{name}' first.")
        end

        # Create saved location (using actual DB column name)
        SavedLocation.create(
          character_id: character.id,
          room_id: location.id,
          location_name: name
        )

        room_display = location.name
        zone_display = location.location&.zone&.name || 'unknown zone'

        success_result(
          "Location saved as '#{name}' (#{room_display} in #{zone_display}).",
          type: :message,
          data: {
            action: 'save_location',
            name: name,
            room_id: location.id,
            room_name: room_display,
            zone_name: zone_display
          }
        )
      end

      private

      def parse_name(input)
        # Support "as <name>" or just "<name>"
        if input.downcase.start_with?('as ')
          input[3..-1].strip
        else
          input
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Storage::SaveLocation)
