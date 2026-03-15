# frozen_string_literal: true

# Service for creating and managing vehicle types (templates)
class VehicleTypeDesignerService
  class << self
    def create(params)
      vehicle_type_params = extract_params(params)

      vehicle_type = VehicleType.new(vehicle_type_params)

      if vehicle_type.valid?
        vehicle_type.save
        { success: true, vehicle_type: vehicle_type }
      else
        { success: false, error: vehicle_type.errors.full_messages.join(', ') }
      end
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    rescue StandardError => e
      { success: false, error: "Failed to create vehicle type: #{e.message}" }
    end

    def update(vehicle_type, params)
      vehicle_type_params = extract_params(params)

      vehicle_type.update(vehicle_type_params)
      { success: true, vehicle_type: vehicle_type }
    rescue Sequel::ValidationFailed => e
      { success: false, error: e.message }
    rescue StandardError => e
      { success: false, error: "Failed to update vehicle type: #{e.message}" }
    end

    def delete(vehicle_type)
      # Check if any vehicles use this type
      if vehicle_type.vehicles.any?
        return { success: false, error: 'Cannot delete vehicle type with existing vehicles' }
      end

      vehicle_type.destroy
      { success: true }
    rescue StandardError => e
      { success: false, error: "Failed to delete vehicle type: #{e.message}" }
    end

    # Instantiate a vehicle from this type
    def spawn_vehicle(vehicle_type, options = {})
      Vehicle.create(
        vehicle_type_id: vehicle_type.id,
        vtype: vehicle_type.name,
        char_id: options[:owner_id],
        room_id: options[:room_id],
        max_passengers: vehicle_type.max_passengers || 4,
        condition: 100,
        parked: true,
        convertible: vehicle_type.properties&.dig('convertible') || false,
        opentop: false,
        short_desc: options[:short_desc] || vehicle_type.properties&.dig('short_desc_template'),
        in_desc: options[:in_desc] || vehicle_type.properties&.dig('in_desc_template'),
        out_desc: options[:out_desc] || vehicle_type.properties&.dig('out_desc_template')
      )
    end

    private

    def extract_params(params)
      vt = params['vehicle_type'] || params

      # Handle properties as JSON
      properties = {}
      if vt['properties'].is_a?(String) && !vt['properties'].empty?
        begin
          properties = JSON.parse(vt['properties'])
        rescue JSON::ParserError
          # Ignore invalid JSON
        end
      elsif vt['properties'].is_a?(Hash)
        properties = vt['properties']
      end

      # Add any individual property fields
      properties['convertible'] = vt['convertible'] == 'true' || vt['convertible'] == '1' if vt.key?('convertible')
      properties['short_desc_template'] = vt['short_desc_template'] if vt['short_desc_template']
      properties['in_desc_template'] = vt['in_desc_template'] if vt['in_desc_template']
      properties['out_desc_template'] = vt['out_desc_template'] if vt['out_desc_template']

      {
        name: vt['name']&.strip,
        category: vt['category'] || 'ground',
        description: vt['description']&.strip,
        universe_id: vt['universe_id'].to_s.empty? ? nil : vt['universe_id'].to_i,
        max_passengers: vt['max_passengers'].to_s.empty? ? 4 : vt['max_passengers'].to_i,
        cargo_capacity: vt['cargo_capacity'].to_s.empty? ? 100 : vt['cargo_capacity'].to_i,
        base_speed: vt['base_speed'].to_s.empty? ? 1.0 : vt['base_speed'].to_f,
        requires_fuel: vt['requires_fuel'] == 'true' || vt['requires_fuel'] == '1',
        properties: properties.empty? ? nil : properties
      }.compact
    end
  end
end
