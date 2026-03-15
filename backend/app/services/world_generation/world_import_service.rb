# frozen_string_literal: true

module WorldGeneration
  # Imports world data from JSON files produced by Python world generation.
  #
  # This service reads the JSON output from the Python worldgen pipeline and
  # creates WorldHex records in the database. It handles batch insertion for
  # performance and clears existing hexes before importing.
  #
  # @example Basic usage
  #   service = WorldImportService.new(world, '/tmp/world_output.json')
  #   service.import
  #
  # @see WorldGeneration::PythonRunnerService
  #
  class WorldImportService
    # Number of records to insert per batch (for performance)
    BATCH_SIZE = 10_000

    # @param world [World] The world to import hexes into
    # @param json_path [String] Path to the JSON file from Python
    def initialize(world, json_path)
      @world = world
      @json_path = json_path
      @data = nil
    end

    # Run the import process
    #
    # This method:
    # 1. Loads the JSON file
    # 2. Clears existing hexes for this world
    # 3. Batch-inserts new hexes
    # 4. Updates world metadata if present
    #
    # @return [void]
    def import
      load_json
      clear_existing
      import_hexes
      update_world_metadata
    end

    private

    # Load and parse the JSON file
    #
    # @return [void]
    # @raise [JSON::ParserError] if JSON is invalid
    # @raise [Errno::ENOENT] if file doesn't exist
    def load_json
      content = File.read(@json_path)
      @data = JSON.parse(content)
    rescue JSON::ParserError => e
      warn "[WorldImportService] Failed to parse JSON: #{e.message}"
      raise
    rescue Errno::ENOENT => e
      warn "[WorldImportService] JSON file not found: #{@json_path}"
      raise
    end

    # Clear existing WorldHex records for this world
    #
    # Uses delete (not destroy) for performance since we're replacing all data.
    #
    # @return [void]
    def clear_existing
      WorldHex.where(world_id: @world.id).delete
    end

    # Import hexes from the loaded JSON data
    #
    # Handles batching for performance with large hex counts.
    #
    # @return [void]
    def import_hexes
      hexes = @data['hexes'] || []
      return if hexes.empty?

      hexes.each_slice(BATCH_SIZE) do |batch|
        records = batch.map { |h| hex_to_record(h) }
        WorldHex.multi_insert(records)
      end
    end

    # Convert a hex JSON object to a database record hash
    #
    # Maps Python JSON keys to WorldHex column names:
    # - id -> globe_hex_id (the unique hex identifier from the globe grid)
    # - lat/lon -> latitude/longitude
    # - elevation -> altitude (database column name)
    #
    # @param h [Hash] The hex data from JSON
    # @return [Hash] A hash suitable for WorldHex.multi_insert
    def hex_to_record(h)
      # Build river_edges as properly typed PG array
      # Must explicitly cast to text[] for PostgreSQL when array might be empty
      river_edges_raw = h['river_edges'] || []
      river_edges = Sequel.pg_array(river_edges_raw, :text)

      # Parse globe_hex_id from the id field (e.g., "2-0-0" -> extract numeric ID or hash it)
      # If it's a string like "2-0-0", convert to an integer hash
      # If it's already an integer, use it directly
      globe_hex_id = parse_globe_hex_id(h['id'])

      {
        world_id: @world.id,
        globe_hex_id: globe_hex_id,
        latitude: h['lat']&.to_f,
        longitude: h['lon']&.to_f,
        altitude: h['elevation']&.to_i || 0,
        terrain_type: normalize_terrain(h['terrain_type']),
        temperature: h['temperature']&.to_f,
        moisture: h['moisture']&.to_f,
        river_edges: river_edges,
        river_width: h['river_width'] || 0,
        lake_id: h['lake_id'],
        plate_id: h['plate_id']
      }
    end

    # Normalize terrain type strings from Python output.
    # Catches known mismatches and falls back to default for unknown types.
    #
    # @param terrain [String, nil] The terrain type from JSON
    # @return [String] A valid WorldHex terrain type
    def normalize_terrain(terrain)
      case terrain
      when 'volcano' then 'volcanic'
      when 'rift_valley' then 'rocky_plains'
      else
        WorldHex::TERRAIN_TYPES.include?(terrain) ? terrain : WorldHex::DEFAULT_TERRAIN
      end
    end

    # Parse globe_hex_id from JSON id field
    # Supports:
    # - Integer: used directly
    # - String like "2-0-0" (subdivision-q-r): parsed to unique integer
    # - Other strings: hashed to unique integer (capped to fit PostgreSQL integer)
    #
    # @param id [Integer, String] the id value from JSON
    # @return [Integer] the globe_hex_id
    def parse_globe_hex_id(id)
      case id
      when Integer
        id
      when String
        # Try to parse structured IDs like "2-0-0" (subdivision-q-r)
        if id =~ /^(\d+)-(-?\d+)-(-?\d+)$/
          # Convert to unique integer: subdivision * 1_000_000 + (q + 500_000) * 1000 + (r + 500_000)
          subdivision, q, r = $1.to_i, $2.to_i, $3.to_i
          # This allows subdivision 0-4, q/r up to ~500k each, fitting in ~2B
          (subdivision * 1_000_000_000 + (q + 500_000) * 1000 + (r + 500_000)) % 2_147_483_647
        else
          # Generic string: hash and constrain to PostgreSQL integer range (0 to 2^31-1)
          id.hash.abs % 2_147_483_647
        end
      else
        # Fallback: use a counter based on the current hex count
        @hex_counter ||= 0
        @hex_counter += 1
      end
    end

    # Update world metadata from the JSON metadata section
    #
    # @return [void]
    def update_world_metadata
      metadata = @data['metadata'] || {}
      return if metadata.empty?

      updates = { updated_at: Time.now }

      # Only update fields that exist on the World model and have values
      updates[:generation_seed] = metadata['seed'] if metadata['seed'] && @world.respond_to?(:generation_seed=)
      updates[:hex_count] = metadata['hex_count'] if metadata['hex_count'] && @world.respond_to?(:hex_count=)

      @world.update(updates) unless updates.keys == [:updated_at]
    rescue StandardError => e
      # Don't fail the import if metadata update fails
      warn "[WorldImportService] Failed to update world metadata: #{e.message}"
    end
  end
end
