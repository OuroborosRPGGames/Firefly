# frozen_string_literal: true

module Commands
  module Inventory
    class Delete < Commands::Base::Command
      command_name 'delete'
      aliases 'del'
      category :inventory
      help_text 'Delete various items (bulletin, place, etc.)'
      usage 'delete <type>'
      examples(
        'delete bulletin',
        'delete place'
      )

      VALID_TYPES = %w[bulletin place].freeze

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return show_usage if blank?(text)

        args = text.strip.split(/\s+/)
        delete_type = args[0].downcase
        rest = args[1..].join(' ').strip
        rest = nil if rest.empty?

        case delete_type
        when 'bulletin'
          delete_bulletin
        when 'place'
          delete_place(rest)
        else
          error_result(
            "Unknown delete type: #{delete_type}\n" \
            "Valid types: #{VALID_TYPES.join(', ')}"
          )
        end
      end

      private

      def show_usage
        error_result(
          "Usage: delete <type>\n\n" \
          "Types:\n" \
          "  bulletin - Delete your bulletin\n" \
          "  place <name> - Delete a place (requires room ownership)"
        )
      end

      def delete_bulletin
        existing = ::Bulletin.by_character(character).all

        if existing.empty?
          return error_result("You don't have any bulletins to delete.")
        end

        count = existing.length
        ::Bulletin.delete_for_character(character)

        success_result(
          "Deleted #{count} bulletin(s).",
          type: :message,
          data: { action: 'delete_bulletin', count: count }
        )
      end

      def delete_place(place_name)
        room = location
        return error_result("You're not in a room.") unless room

        outer_room = room.respond_to?(:outer_room) ? room.outer_room : room

        unless outer_room.owned_by?(character)
          return error_result("You don't own this room.")
        end

        if blank?(place_name)
          return list_places_for_deletion(room)
        end

        # Find the place
        places = Place.where(room_id: room.id).all
        place = find_place_by_name(places, place_name)

        unless place
          return error_result("No place named '#{place_name}' in this room.")
        end

        place_desc = place.name || place.description
        place.destroy

        success_result(
          "Deleted place: #{place_desc}",
          type: :message,
          data: {
            action: 'delete_place',
            place_name: place_desc
          }
        )
      end

      def list_places_for_deletion(room)
        places = Place.where(room_id: room.id).all

        if places.empty?
          return error_result("There are no places in this room.")
        end

        lines = ["Places in this room:\n"]
        places.each_with_index do |place, idx|
          lines << "  #{idx + 1}. #{place.name || place.description}"
        end
        lines << "\nUse 'delete place <name>' to delete a place."

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'list_places', count: places.length }
        )
      end

      def find_place_by_name(places, name)
        # Places use name as primary, description as fallback
        TargetResolverService.resolve(
          query: name,
          candidates: places,
          name_field: :name,
          description_field: :description
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Delete)
