# frozen_string_literal: true

module Commands
  module Building
    class BuildApartment < Commands::Base::Command
      command_name 'build apartment'
      aliases 'buildapartment', 'create apartment', 'get apartment', 'find apartment'
      category :building
      help_text 'Find or create an apartment in the city and optionally claim it'
      usage 'build apartment [size]'
      examples 'build apartment', 'build apartment small', 'build apartment penthouse'

      SIZES = {
        'small' => :small,
        'medium' => :medium,
        'large' => :large,
        'penthouse' => :penthouse
      }.freeze

      protected

      def perform_command(parsed_input)
        # Check permissions - can be in creator mode OR staff
        unless CityBuilderService.can_build?(character, :build_apartment)
          return error_result(
            "You don't have permission to request apartments. " \
            "You need to be in creator mode or have staff building permission."
          )
        end

        # Get city location
        city_location = find_city_location
        unless city_location
          return error_result(
            'You must be in a city to request an apartment. ' \
            "This location doesn't have a city grid."
          )
        end

        # Parse size preference
        size_text = (parsed_input[:text] || '').sub(/^apartment\s*/i, '').strip.downcase
        size = SIZES[size_text] || :medium

        # Try to find or create an apartment
        apartment = CityBuilderService.find_or_create_building(
          location: city_location,
          building_type: :apartment_tower,
          preferences: { size: size }
        )

        unless apartment
          return error_result(
            'No apartments are available and no space exists to build new ones. ' \
            "Try a different city or contact staff."
          )
        end

        # Show apartment details and option to claim
        show_apartment_details(apartment, size)
      end

      # Handle quickmenu response
      def handle_quickmenu_response(selected_key, context)
        apartment = Room[context['apartment_id']]
        unless apartment
          return error_result('Apartment no longer exists.')
        end

        case selected_key
        when 'claim'
          claim_apartment(apartment)
        when 'visit'
          visit_apartment(apartment)
        when 'cancel'
          success_result('You decided not to take the apartment.', type: :message)
        else
          error_result("Unknown option: #{selected_key}")
        end
      end

      private

      def find_city_location
        # Get the Location (not Room) that has city data
        room_location = location.location
        return nil unless room_location

        # Check if city was built
        return room_location if room_location.city_built_at

        nil
      end

      def show_apartment_details(apartment, size)
        building = apartment.inside_room || apartment
        floor = apartment.floor_number || 0
        size_name = size.to_s.capitalize

        options = [
          { key: 'claim', label: 'Claim Apartment', description: 'Make this your home' },
          { key: 'visit', label: 'Just Visit', description: 'Take a look without claiming' },
          { key: 'cancel', label: 'Cancel', description: 'Never mind' }
        ]

        create_quickmenu(
          character_instance,
          "Found a #{size_name} apartment:\n\n" \
          "  #{apartment.name}\n" \
          "  Floor: #{floor + 1}\n" \
          "  Building: #{building.name rescue 'Unknown'}\n\n" \
          "What would you like to do?",
          options,
          context: {
            command: 'build_apartment',
            apartment_id: apartment.id
          }
        )
      end

      def claim_apartment(apartment)
        if apartment.respond_to?(:owner_id) && apartment.owner_id && apartment.owner_id != character.id
          return error_result('That apartment has already been claimed by someone else.')
        end

        # Assign to character
        success = CityBuilderService.assign_building(
          building: apartment,
          character: character
        )

        unless success
          return error_result('Failed to claim apartment. Please try again.')
        end

        # Move to apartment
        character_instance.update(current_room_id: apartment.id, x: 0.0, y: 0.0, z: 0.0)

        # Update character's home if they have one
        if character.respond_to?(:home_room_id=)
          character.home_room_id = apartment.id
          character.save
        end

        success_result(
          "You have claimed #{apartment.name}!\n\n" \
          "This is now your home. Use 'home' to return here anytime.",
          type: :action,
          data: {
            action: 'claim_apartment',
            apartment_id: apartment.id,
            apartment_name: apartment.name,
            character_id: character.id
          }
        )
      end

      def visit_apartment(apartment)
        # Just move there without claiming
        character_instance.update(current_room_id: apartment.id, x: 0.0, y: 0.0, z: 0.0)

        success_result(
          "You are now visiting #{apartment.name}.\n\n" \
          "Use 'build apartment' again to claim it, or explore the city.",
          type: :action,
          data: {
            action: 'visit_apartment',
            apartment_id: apartment.id,
            apartment_name: apartment.name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::BuildApartment)
