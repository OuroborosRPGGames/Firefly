# frozen_string_literal: true

module Commands
  module Navigation
    class DeleteLocation < Commands::Base::Command
      command_name 'delete location'
      aliases 'forget location', 'remove bookmark', 'clear home'
      category :navigation
      help_text 'Clear your saved home location'
      usage 'delete location [home]'
      examples 'delete location home', 'clear home'

      protected

      def perform_command(parsed_input)
        text = (parsed_input[:text] || '').sub(/^location\s*/i, '').strip.downcase

        char = character_instance.character

        if text.empty? || text == 'home'
          unless char.home_room_id
            return error_result("You don't have a home location set.")
          end

          old_home = char.home_room
          old_home_name = old_home&.name || 'Unknown'

          char.update(home_room_id: nil)

          success_result(
            "You have cleared your home location (was: #{old_home_name}).",
            type: :message,
            data: {
              action: 'delete_location',
              location_type: 'home',
              old_room_id: old_home&.id,
              old_room_name: old_home_name
            }
          )
        else
          # Look up saved bookmark by name
          saved_loc = SavedLocation.find_by_name(char, text)
          unless saved_loc
            return error_result("No saved location called '#{text}'. Use 'save location as <name>' to bookmark a location.")
          end

          room_name = saved_loc.room&.name || 'unknown'
          saved_loc.destroy

          success_result(
            "Deleted saved location '#{text}' (#{room_name}).",
            type: :message,
            data: {
              action: 'delete_location',
              location_type: 'bookmark',
              name: text,
              room_name: room_name
            }
          )
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::DeleteLocation)
