# frozen_string_literal: true

module Commands
  module Navigation
    class Eta < Commands::Base::Command
      command_name 'eta'
      aliases 'arrival', 'travel_status', 'journey_status'
      category :navigation
      help_text 'Check your estimated time of arrival during a journey'
      usage 'eta'
      examples 'eta', 'arrival'

      protected

      def perform_command(_parsed_input)
        unless character_instance.traveling?
          return error_result("You're not currently on a journey.")
        end

        journey = character_instance.current_world_journey
        unless journey
          return error_result("Journey data not found.")
        end

        eta_info = WorldTravelService.journey_eta(journey)

        # Build the status message
        destination = eta_info[:destination]
        time_remaining = eta_info[:time_remaining]
        hexes_remaining = eta_info[:hexes_remaining]
        terrain = journey.terrain_description

        message = build_eta_message(journey, destination, time_remaining, hexes_remaining, terrain)

        success_result(
          message,
          type: :travel_status,
          data: {
            destination: destination,
            time_remaining: time_remaining,
            hexes_remaining: hexes_remaining,
            vehicle: journey.vehicle_type,
            travel_mode: journey.travel_mode,
            current_terrain: terrain
          }
        )
      end

      private

      def build_eta_message(journey, destination, time_remaining, hexes_remaining, terrain)
        vehicle = journey.vehicle_type.tr('_', ' ')

        lines = []
        lines << "<h3>Journey Status</h3>"
        lines << "Destination: #{destination}"
        lines << "Vehicle: #{vehicle.capitalize}"
        lines << "Current terrain: #{terrain}"
        lines << "Distance remaining: #{hexes_remaining} hex#{'es' if hexes_remaining != 1}"
        lines << "Estimated arrival: #{time_remaining}"

        lines.join("\n")
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Eta)
