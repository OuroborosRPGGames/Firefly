# frozen_string_literal: true

module WeatherGrid
  # StormService - Manages discrete storm entities with lifecycles
  #
  # Storms are tracked as separate objects that move across the grid,
  # affecting weather in cells they pass through. They have lifecycles:
  # forming → mature → dissipating
  #
  # Storm Types:
  #   - thunderstorm: Common, moderate intensity
  #   - blizzard: Cold temperature required
  #   - hurricane: Forms over warm ocean
  #   - tornado: Brief, intense, forms from severe thunderstorms
  #
  # Usage:
  #   WeatherGrid::StormService.tick_storms(world, grid)    # Update all storms
  #   WeatherGrid::StormService.genesis_check(world, grid)  # Check for new storms
  #   WeatherGrid::StormService.apply_effects(world, grid)  # Apply storm effects to grid
  #
  module StormService
    extend self

    # Storm type definitions
    STORM_TYPES = {
      thunderstorm: {
        min_instability: 65,
        min_humidity: 75,
        min_temp: 15,
        max_temp: 45,
        base_intensity: 0.6,
        base_radius: 1.5,
        forming_duration: 4..8,      # ticks
        mature_duration: 20..60,
        dissipating_duration: 8..20
      },
      blizzard: {
        min_instability: 50,
        min_humidity: 60,
        min_temp: -40,
        max_temp: 2,
        base_intensity: 0.7,
        base_radius: 2.0,
        forming_duration: 6..12,
        mature_duration: 30..80,
        dissipating_duration: 15..30
      },
      hurricane: {
        min_instability: 70,
        min_humidity: 80,
        min_temp: 26,
        max_temp: 35,
        requires_water: true,
        base_intensity: 0.9,
        base_radius: 4.0,
        forming_duration: 20..40,
        mature_duration: 60..200,
        dissipating_duration: 30..60
      },
      tornado: {
        min_instability: 85,
        min_humidity: 70,
        min_temp: 20,
        max_temp: 40,
        base_intensity: 1.0,
        base_radius: 0.5,
        forming_duration: 1..2,
        mature_duration: 4..15,
        dissipating_duration: 1..3
      }
    }.freeze

    # Storm names for hurricanes and major storms
    STORM_NAMES = %w[
      Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa
      Ana Bob Crystal David Elena Franklin Gloria Henri Irene Jack
      Kira Luis Maria Nate Ophelia Philippe Rina Stan Tammy Victor Wanda
    ].freeze

    GRID_SIZE = GridService::GRID_SIZE

    # Run a full storm tick for a world (loads grid automatically)
    #
    # Convenience method for scheduler integration. Loads the grid,
    # runs storm updates, checks for new storm formation, and applies effects.
    #
    # @param world [World] The world to process
    # @return [Hash] Results with :storms_updated, :storms_formed counts
    def tick(world)
      return { storms_updated: 0, storms_formed: 0 } unless world&.id

      grid = GridService.load(world)
      return { storms_updated: 0, storms_formed: 0 } unless grid

      updated = tick_storms(world, grid)
      formed = genesis_check(world, grid)
      apply_effects(world, grid) if updated.any? || formed.any?

      { storms_updated: updated.size, storms_formed: formed.size }
    rescue StandardError => e
      warn "[WeatherGrid::StormService] Tick failed for world #{world&.id}: #{e.message}"
      { storms_updated: 0, storms_formed: 0 }
    end

    # Update all storms for a world
    #
    # @param world [World] The world
    # @param grid [Hash] Current grid state
    # @return [Array<Hash>] Updated storms
    def tick_storms(world, grid)
      storms = load_storms(world, grid)
      return [] if storms.empty?

      storms = storms.map { |storm| update_storm(storm, grid) }
      storms = storms.reject { |storm| storm['phase'] == 'dead' }

      save_storms(world, storms, grid)
      storms
    end

    # Check for new storm formation
    #
    # @param world [World] The world
    # @param grid [Hash] Current grid state
    # @return [Array<Hash>] Newly formed storms
    def genesis_check(world, grid)
      cells = grid[:cells]
      terrain = TerrainService.load(world)
      new_storms = []

      cells.each_with_index do |cell, i|
        x, y = GridService.index_to_coords(i)
        terrain_cell = terrain&.at(i)

        # Check each storm type
        STORM_TYPES.each do |type, config|
          next unless meets_genesis_conditions?(cell, config, terrain_cell)
          next unless genesis_roll(cell, config)
          next if storm_nearby?(world, grid, x, y, type)

          new_storm = create_storm(type, x, y, cell, config)
          new_storms << new_storm
        end
      end

      # Add new storms to grid
      if new_storms.any?
        storms = load_storms(world, grid) + new_storms
        save_storms(world, storms, grid)
      end

      new_storms
    end

    # Apply storm effects to grid cells
    #
    # @param world [World] The world
    # @param grid [Hash] Current grid state
    # @return [Hash] Modified grid
    def apply_effects(world, grid)
      storms = load_storms(world, grid)
      return grid if storms.empty?

      cells = grid[:cells]

      storms.each do |storm|
        cells = apply_storm_to_cells(storm, cells)
      end

      grid[:cells] = cells
      grid
    end

    # Get all active storms for a world
    #
    # @param world [World] The world
    # @return [Array<Hash>]
    def active_storms(world)
      grid = GridService.load(world)
      return [] unless grid

      load_storms(world, grid)
    end

    # Get storm affecting a specific grid position
    #
    # @param world [World] The world
    # @param grid_x [Float] Grid X position
    # @param grid_y [Float] Grid Y position
    # @return [Hash, nil] Storm data or nil
    def storm_at(world, grid_x, grid_y)
      storms = active_storms(world)

      storms.find do |storm|
        distance = Math.sqrt(
          (grid_x - storm['grid_x'])**2 +
          (grid_y - storm['grid_y'])**2
        )
        distance <= storm['radius_cells']
      end
    end

    private

    # ========================================
    # Storm State Management
    # ========================================

    def load_storms(world, grid)
      grid[:meta]&.dig('storms') || []
    end

    def save_storms(world, storms, grid)
      GridService.update_meta(world, { 'storms' => storms })
    end

    # ========================================
    # Storm Genesis
    # ========================================

    def meets_genesis_conditions?(cell, config, terrain_cell)
      return false if cell['instability'] < config[:min_instability]
      return false if cell['humidity'] < config[:min_humidity]
      return false if cell['temperature'] < config[:min_temp]
      return false if cell['temperature'] > config[:max_temp]

      # Hurricane requires water
      if config[:requires_water]
        water_pct = terrain_cell&.dig('water_pct') || 0
        return false if water_pct < 50
      end

      true
    end

    def genesis_roll(cell, config)
      # Probability based on conditions exceeding minimums
      excess_instability = cell['instability'] - config[:min_instability]
      excess_humidity = cell['humidity'] - config[:min_humidity]

      probability = (excess_instability + excess_humidity) / 200.0
      probability = probability.clamp(0.01, 0.15) # 1-15% chance per tick

      rand < probability
    end

    def storm_nearby?(world, grid, x, y, type)
      storms = load_storms(world, grid)

      storms.any? do |storm|
        distance = Math.sqrt((x - storm['grid_x'])**2 + (y - storm['grid_y'])**2)
        min_distance = type == :tornado ? 5 : 10
        distance < min_distance
      end
    end

    def create_storm(type, x, y, cell, config)
      storm_id = "storm_#{SecureRandom.hex(8)}"
      name = type == :hurricane ? generate_storm_name : nil

      {
        'id' => storm_id,
        'type' => type.to_s,
        'name' => name,
        'grid_x' => x.to_f,
        'grid_y' => y.to_f,
        'heading' => cell['wind_dir'],
        'speed' => cell['wind_speed'] * 0.75,
        'intensity' => config[:base_intensity],
        'phase' => 'forming',
        'radius_cells' => config[:base_radius],
        'formed_at' => Time.now.iso8601,
        'ticks_in_phase' => 0,
        'phase_duration' => rand(config[:forming_duration])
      }
    end

    def generate_storm_name
      # Simple sequential naming
      STORM_NAMES.sample
    end

    # ========================================
    # Storm Update
    # ========================================

    def update_storm(storm, grid)
      storm = storm.dup
      storm['ticks_in_phase'] += 1

      # Move storm
      storm = move_storm(storm, grid)

      # Check phase transition
      if storm['ticks_in_phase'] >= storm['phase_duration']
        storm = transition_phase(storm)
      end

      # Update intensity based on phase
      storm = update_intensity(storm)

      storm
    end

    def move_storm(storm, grid)
      # Get wind at storm position
      x = storm['grid_x'].floor.clamp(0, GRID_SIZE - 1)
      y = storm['grid_y'].floor.clamp(0, GRID_SIZE - 1)
      idx = GridService.coords_to_index(x, y)
      cell = grid[:cells][idx]

      # Storm follows wind at 75% speed
      wind_speed = cell&.dig('wind_speed') || storm['speed']
      wind_dir = cell&.dig('wind_dir') || storm['heading']

      storm['heading'] = wind_dir
      storm['speed'] = wind_speed * 0.75

      # Move based on heading and speed
      # Speed is in kph, tick is 15 seconds, grid cell is ~150 miles
      # Simplify: move fraction of a cell per tick
      move_rate = storm['speed'] / 500.0 # Cells per tick

      radians = storm['heading'] * Math::PI / 180.0
      dx = Math.sin(radians) * move_rate
      dy = -Math.cos(radians) * move_rate

      storm['grid_x'] = (storm['grid_x'] + dx) % GRID_SIZE
      storm['grid_y'] = (storm['grid_y'] + dy) % GRID_SIZE

      storm
    end

    def transition_phase(storm)
      type_config = STORM_TYPES[storm['type'].to_sym]

      case storm['phase']
      when 'forming'
        storm['phase'] = 'mature'
        storm['ticks_in_phase'] = 0
        storm['phase_duration'] = rand(type_config[:mature_duration])
        storm['intensity'] = type_config[:base_intensity]
      when 'mature'
        storm['phase'] = 'dissipating'
        storm['ticks_in_phase'] = 0
        storm['phase_duration'] = rand(type_config[:dissipating_duration])
      when 'dissipating'
        storm['phase'] = 'dead'
      end

      storm
    end

    def update_intensity(storm)
      case storm['phase']
      when 'forming'
        # Intensity grows
        storm['intensity'] = [storm['intensity'] + 0.05, 1.0].min
      when 'mature'
        # Intensity stable with small fluctuations
        fluctuation = rand(-0.05..0.05)
        storm['intensity'] = (storm['intensity'] + fluctuation).clamp(0.3, 1.0)
      when 'dissipating'
        # Intensity decays
        storm['intensity'] = [storm['intensity'] - 0.1, 0.0].max
        storm['radius_cells'] = [storm['radius_cells'] - 0.1, 0.5].max
      end

      storm
    end

    # ========================================
    # Storm Effects
    # ========================================

    def apply_storm_to_cells(storm, cells)
      center_x = storm['grid_x']
      center_y = storm['grid_y']
      radius = storm['radius_cells']
      intensity = storm['intensity']

      # Affect cells within radius
      cells.each_with_index do |cell, i|
        x, y = GridService.index_to_coords(i)
        distance = Math.sqrt((x - center_x)**2 + (y - center_y)**2)

        next if distance > radius

        # Effect falloff from center
        falloff = 1.0 - (distance / radius)
        effect_strength = intensity * falloff

        # Apply storm effects
        cell = apply_storm_effects_to_cell(cell, storm, effect_strength)
        cells[i] = cell
      end

      cells
    end

    def apply_storm_effects_to_cell(cell, storm, strength)
      cell = cell.dup

      # Precipitation boost
      precip_boost = strength * precip_multiplier(storm['type']) * 10
      cell['precip_rate'] = (cell['precip_rate'] + precip_boost).clamp(0.0, 50.0)

      # Cloud cover to 100%
      cell['cloud_cover'] = [cell['cloud_cover'] + strength * 50, 100.0].min

      # Wind speed boost
      wind_boost = strength * wind_multiplier(storm['type']) * 30
      cell['wind_speed'] = (cell['wind_speed'] + wind_boost).clamp(0.0, 200.0)

      # Temperature effect (storms cool slightly)
      temp_change = strength * -2.0
      cell['temperature'] = (cell['temperature'] + temp_change).clamp(-60.0, 60.0)

      # High humidity
      cell['humidity'] = [cell['humidity'] + strength * 20, 100.0].min

      cell
    end

    def precip_multiplier(type)
      case type
      when 'hurricane' then 2.5
      when 'blizzard' then 2.0
      when 'thunderstorm' then 1.5
      when 'tornado' then 1.0
      else 1.0
      end
    end

    def wind_multiplier(type)
      case type
      when 'hurricane' then 3.0
      when 'tornado' then 4.0
      when 'blizzard' then 1.5
      when 'thunderstorm' then 1.0
      else 1.0
      end
    end
  end
end
