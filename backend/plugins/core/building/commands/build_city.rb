# frozen_string_literal: true

module Commands
  module Building
    class BuildCity < Commands::Base::Command
      command_name 'build city'
      aliases 'buildcity', 'create city', 'build town', 'create town'
      category :building
      help_text 'Build a city/town grid with streets and intersections'
      usage 'build city [name]'
      examples 'build city', 'build city New York', 'buildcity Chicago'

      protected

      def perform_command(parsed_input)
        # Check permissions - must be staff with building permission
        unless CityBuilderService.can_build?(character, :build_city)
          return error_result(
            'You must be staff with building permission to build cities. ' \
            "Contact an administrator if you need this access."
          )
        end

        # Get current location
        current_location = location.location
        unless current_location
          return error_result('You must be in a valid location to build a city.')
        end

        # Check if city already built
        if current_location.city_built_at
          return error_result(
            "A city has already been built at this location (#{current_location.city_name || current_location.name}). " \
            "You cannot build another city on top of an existing one."
          )
        end

        # Parse optional city name from command
        city_name = (parsed_input[:text] || '').sub(/^(city|town)\s*/i, '').strip
        city_name = nil if city_name.empty?

        # If no name provided or need more options, show form
        if city_name.nil? || parsed_input[:show_form]
          return show_city_form(current_location, city_name)
        end

        # Quick build with defaults
        build_city_with_params(current_location, {
                                 city_name: city_name,
                                 horizontal_streets: GameConfig::CityBuilder::DEFAULTS[:horizontal_streets],
                                 vertical_streets: GameConfig::CityBuilder::DEFAULTS[:vertical_streets],
                                 max_building_height: GameConfig::CityBuilder::DEFAULTS[:max_building_height]
                               })
      end

      # Handle form submission
      def handle_form_response(form_data, context)
        current_location = Location[context['location_id']]
        unless current_location
          return error_result('Location no longer exists.')
        end

        params = {
          city_name: form_data['city_name'],
          horizontal_streets: form_data['horizontal_streets'].to_i,
          vertical_streets: form_data['vertical_streets'].to_i,
          max_building_height: form_data['max_building_height'].to_i,
          longitude: form_data['longitude']&.to_f,
          latitude: form_data['latitude']&.to_f,
          use_llm_names: form_data['use_llm_names'] == 'true'
        }.compact

        build_city_with_params(current_location, params)
      end

      private

      def show_city_form(current_location, default_name)
        fields = [
          {
            name: 'city_name',
            label: 'City Name',
            type: 'text',
            required: true,
            default: default_name || current_location.name,
            placeholder: 'e.g., New York City'
          },
          {
            name: 'horizontal_streets',
            label: 'Streets (E-W)',
            type: 'number',
            required: true,
            default: GameConfig::CityBuilder::DEFAULTS[:horizontal_streets],
            min: GameConfig::CityBuilder::LIMITS[:min_streets],
            max: GameConfig::CityBuilder::LIMITS[:max_streets]
          },
          {
            name: 'vertical_streets',
            label: 'Avenues (N-S)',
            type: 'number',
            required: true,
            default: GameConfig::CityBuilder::DEFAULTS[:vertical_streets],
            min: GameConfig::CityBuilder::LIMITS[:min_avenues],
            max: GameConfig::CityBuilder::LIMITS[:max_avenues]
          },
          {
            name: 'max_building_height',
            label: 'Max Building Height (ft)',
            type: 'number',
            required: true,
            default: GameConfig::CityBuilder::DEFAULTS[:max_building_height],
            min: GameConfig::CityBuilder::LIMITS[:min_building_height],
            max: GameConfig::CityBuilder::LIMITS[:max_building_height]
          },
          {
            name: 'longitude',
            label: 'Longitude (optional)',
            type: 'number',
            required: false,
            placeholder: '-74.0060 (NYC)'
          },
          {
            name: 'latitude',
            label: 'Latitude (optional)',
            type: 'number',
            required: false,
            placeholder: '40.7128 (NYC)'
          },
          {
            name: 'use_llm_names',
            label: 'Use AI for Street Names',
            type: 'select',
            required: false,
            default: 'auto',
            options: [
              { value: 'auto', label: 'Auto-detect (based on world theme)' },
              { value: 'true', label: 'Yes (realistic names via AI)' },
              { value: 'false', label: 'No (generated/numbered names)' }
            ]
          }
        ]

        create_form(
          character_instance,
          'Build City',
          fields,
          context: {
            command: 'build_city',
            location_id: current_location.id
          }
        )
      end

      def build_city_with_params(current_location, params)
        # Validate parameters
        params[:horizontal_streets] ||= 10
        params[:vertical_streets] ||= 10
        params[:max_building_height] ||= 200

        if params[:horizontal_streets] < 2 || params[:horizontal_streets] > 50
          return error_result('Streets must be between 2 and 50.')
        end

        if params[:vertical_streets] < 2 || params[:vertical_streets] > 50
          return error_result('Avenues must be between 2 and 50.')
        end

        # Build the city
        result = CityBuilderService.build_city(
          location: current_location,
          params: params,
          character: character
        )

        unless result[:success]
          return error_result("Failed to build city: #{result[:error]}")
        end

        # Calculate stats
        street_count = result[:streets].length
        avenue_count = result[:avenues].length
        intersection_count = result[:intersections].length
        total_rooms = street_count + avenue_count + intersection_count + 1 # +1 for sky

        # Find the origin intersection to teleport to
        origin = result[:intersections].find { |i| i.grid_x == 0 && i.grid_y == 0 }
        if origin
          character_instance.update(current_room_id: origin.id, x: 0.0, y: 0.0, z: 0.0)
        end

        city_name = params[:city_name] || current_location.name

        success_result(
          "You have built #{city_name}!\n\n" \
          "Created:\n" \
          "  - #{street_count} streets (E-W)\n" \
          "  - #{avenue_count} avenues (N-S)\n" \
          "  - #{intersection_count} intersections\n" \
          "  - 1 sky room\n" \
          "  - Total: #{total_rooms} rooms\n\n" \
          "You are now at #{origin&.name || 'the city origin'}. " \
          "Use 'buildblock' at intersections to add buildings.",
          type: :action,
          data: {
            action: 'build_city',
            city_name: city_name,
            location_id: current_location.id,
            street_count: street_count,
            avenue_count: avenue_count,
            intersection_count: intersection_count,
            street_names: result[:street_names],
            avenue_names: result[:avenue_names]
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::BuildCity)
