# frozen_string_literal: true

module Commands
  module Navigation
    class Places < Commands::Base::Command
      command_name 'places'
      aliases 'furniture', 'spots'
      category :navigation
      help_text 'Show all available places in this room'
      usage 'places'
      examples 'places'

      protected

      def perform_command(_parsed_input)
        room = location
        visible_places = room.visible_places.all

        if visible_places.empty?
          return success_result(
            'There are no notable places here.',
            type: :message,
            data: { action: 'places', places: [] }
          )
        end

        place_names = visible_places.map(&:display_name)
        place_list = place_names.map(&:downcase).join(', ')
        message = "Places: #{place_list}"

        success_result(
          message,
          type: :message,
          data: {
            action: 'places',
            room_name: room.name,
            places: visible_places.map do |place|
              {
                id: place.id,
                name: place.name,
                description: place.description,
                is_furniture: place.furniture?,
                capacity: place.capacity,
                occupants: place.characters_here(character_instance.reality_id, viewer: character_instance).count
              }
            end
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Places)
