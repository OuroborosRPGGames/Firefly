# frozen_string_literal: true

module Commands
  module Navigation
    class Taxi < Commands::Base::Command
      command_name 'taxi'
      aliases 'hail', 'hail taxi', 'hail cab', 'call taxi', 'call cab',
              'rideshare', 'uber', 'lyft', 'autocab', 'call autocab'
      category :navigation
      help_text 'Call a taxi or travel to a destination by taxi'
      usage 'taxi | taxi to <destination>'
      examples 'taxi', 'taxi to Main Street', 'hail cab', 'taxi to park'

      protected

      def perform_command(parsed_input)
        # Check if taxi service is available in this era
        unless EraService.taxi_available?
          return error_result(
            "There's no taxi service in this era. " \
            "You'll need to walk or use your own transportation."
          )
        end

        text = parsed_input[:text]&.strip || ''

        if text.empty?
          # No argument - show destination quickmenu
          return show_taxi_menu
        elsif text.downcase.start_with?('to ')
          # Taxi to a destination
          destination = text.sub(/^to\s+/i, '').strip
          travel_by_taxi(destination)
        else
          # Treat as destination
          travel_by_taxi(text)
        end
      end

      private

      def show_taxi_menu
        # Get known landmarks in the current location area
        landmarks = get_taxi_destinations

        if landmarks.empty?
          return call_taxi  # Fallback to just calling a taxi
        end

        options = landmarks.each_with_index.map do |landmark, idx|
          {
            key: (idx + 1).to_s,
            label: landmark[:name],
            description: landmark[:description] || ''
          }
        end

        options << { key: 'c', label: 'Just call a taxi', description: 'Wait for pickup' }
        options << { key: 'q', label: 'Cancel', description: 'Nevermind' }

        dest_data = landmarks.map { |l| { name: l[:name], id: l[:id] } }

        create_quickmenu(
          character_instance,
          "Where would you like to go?",
          options,
          context: {
            command: 'taxi',
            stage: 'select_destination',
            destinations: dest_data
          }
        )
      end

      def get_taxi_destinations
        # Get public rooms in the current area that can serve as taxi destinations
        current_room = location
        return [] unless current_room

        zone = current_room.location&.zone
        return [] unless zone

        # Find public rooms (no owner) in this zone, excluding current room
        rooms = Room.join(:locations, id: :location_id)
                    .where(Sequel[:locations][:zone_id] => zone.id)
                    .where(Sequel[:rooms][:owner_id] => nil)
                    .exclude(Sequel[:rooms][:id] => current_room.id)
                    .select_all(:rooms)
                    .limit(8)
                    .all

        rooms.map do |r|
          {
            id: r.id,
            name: r.name,
            description: r.room_type || r.location&.name
          }
        end
      rescue StandardError => e
        warn "[Taxi] Error getting destinations: #{e.message}"
        []
      end

      def call_taxi
        result = TaxiService.call_taxi(character_instance)

        if result[:success]
          success_result(
            result[:message],
            type: :message,
            data: result[:data]
          )
        else
          error_result(result[:error])
        end
      end

      def travel_by_taxi(destination)
        if destination.empty?
          return error_result("Where do you want to go? Use 'taxi to <destination>'")
        end

        # First, ensure a taxi is available (call one if needed)
        result = TaxiService.board_taxi(character_instance, destination)

        if result[:success]
          # Broadcast departure
          broadcast_taxi_departure

          success_result(
            result[:message],
            type: :message,
            data: result[:data].merge(
              action: 'taxi_travel',
              from_room: location.name
            )
          )
        else
          error_result(result[:error])
        end
      end

      def broadcast_taxi_departure
        taxi_name = EraService.taxi_name

        message = case EraService.taxi_type
                  when :carriage
                    "#{character.full_name} climbs into a hansom cab, which clatters away."
                  when :rideshare
                    "#{character.full_name} gets into a rideshare vehicle and drives off."
                  when :autocab
                    "#{character.full_name} enters an autocab, which glides silently away."
                  when :hovertaxi
                    "#{character.full_name} boards a hover taxi, which lifts off into the skylane."
                  else
                    "#{character.full_name} takes a #{taxi_name}."
                  end

        broadcast_to_room(message, exclude_character: character)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Taxi)
