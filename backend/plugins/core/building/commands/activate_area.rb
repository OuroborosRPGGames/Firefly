# frozen_string_literal: true

module Commands
  module Building
    class ActivateLocation < Commands::Base::Command
      command_name 'activate location'
      aliases 'activatearea', 'activate area', 'activate zone', 'activatezone'
      category :building
      help_text 'Activate an inactive location you created'
      usage 'activate location'
      examples 'activate location', 'activate area'

      protected

      def perform_command(_parsed_input)
        error = require_building_permission(error_message: "You must be in creator mode or be staff to activate locations.")
        return error if error

        inactive_locations = Location.inactive_recent.all

        if inactive_locations.empty?
          return success_result(
            'You have no inactive locations to activate.',
            type: :message,
            data: {
              action: 'activate_location',
              locations: []
            }
          )
        end

        # Build menu for selection
        lines = ["Which location do you want to activate?\n"]

        inactive_locations.each_with_index do |loc, index|
          zone_name = loc.zone&.name || 'Unknown Zone'
          lines << "[#{index + 1}] #{loc.name} (#{zone_name})"
        end

        # Store options for quickmenu
        options = inactive_locations.map.with_index do |loc, index|
          {
            key: (index + 1).to_s,
            label: loc.name,
            description: loc.zone&.name || 'Unknown Zone'
          }
        end

        # Return as quickmenu
        {
          success: true,
          message: lines.join("\n"),
          type: :quickmenu,
          data: {
            action: 'activate_location_menu',
            prompt: 'Select a location to activate:',
            options: options,
            location_ids: inactive_locations.map(&:id)
          }
        }
      end

      def handle_quickmenu_response(selected_key, context)
        location_ids = context[:location_ids] || []
        index = selected_key.to_i - 1

        return error_result('Invalid selection.') if index < 0 || index >= location_ids.length

        location_id = location_ids[index]
        location = Location[location_id]

        return error_result('Location not found.') unless location
        return error_result('Location is already active.') if location.active?

        location.activate!

        success_result(
          "#{location.name} has been activated.",
          type: :action,
          data: {
            action: 'activate_location',
            location_id: location.id,
            location_name: location.name
          }
        )
      end
    end

    # Backward compatibility alias
    ActivateArea = ActivateLocation
  end
end

Commands::Base::Registry.register(Commands::Building::ActivateLocation)
