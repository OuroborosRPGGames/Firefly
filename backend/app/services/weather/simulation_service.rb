# frozen_string_literal: true

module WeatherGrid
  # SimulationService - Core weather simulation tick loop
  #
  # Runs every 15 seconds to update the 64×64 macro weather grid.
  # Each tick simulates realistic weather physics:
  #
  # 1. Solar heating (time of day, season, latitude, clouds)
  # 2. Pressure calculation (temperature + altitude)
  # 3. Wind derivation (pressure gradient + Coriolis)
  # 4. Advection (wind moves temp/humidity)
  # 5. Terrain effects (evaporation, orographic lift)
  # 6. Diffusion (smoothing)
  # 7. Cloud formation (humidity → clouds)
  # 8. Precipitation (clouds → rain/snow)
  # 9. Instability calculation (storm potential)
  #
  # Usage:
  #   WeatherGrid::SimulationService.tick(world)     # Run one simulation tick
  #   WeatherGrid::SimulationService.tick_all        # Tick all active worlds
  #
  module SimulationService
    extend self

    GRID_SIZE = GridService::GRID_SIZE

    # Physical constants
    LAPSE_RATE = 6.5 / 1000.0       # °C per meter of altitude
    BASE_PRESSURE = 1013.25         # hPa at sea level
    PRESSURE_ALTITUDE_FACTOR = 0.12 # hPa per meter
    ADVECTION_RATE = 0.15           # How much temp/humidity moves per tick
    DIFFUSION_RATE = 0.05           # How much values spread per tick
    CLOUD_FORMATION_THRESHOLD = 70  # Humidity % to form clouds
    PRECIPITATION_THRESHOLD = 85    # Humidity % to precipitate
    MAX_SOLAR_HEATING = 2.0         # Max °C per tick from sun
    NIGHT_COOLING_RATE = 0.5        # °C per tick at night
    INSTABILITY_TEMP_FACTOR = 0.3   # Instability from temp differentials
    INSTABILITY_HUMIDITY_FACTOR = 0.5 # Instability from high humidity

    # Run one simulation tick for a world
    #
    # @param world [World] The world to simulate
    # @return [Boolean] True if tick completed successfully
    def tick(world)
      return false unless world&.id

      # Acquire lock to prevent concurrent simulation
      unless GridService.acquire_lock(world, ttl: 15)
        warn "[WeatherGrid::SimulationService] Could not acquire lock for world #{world.id}"
        return false
      end

      begin
        # Load current state
        grid = GridService.load(world)
        unless grid
          GridService.release_lock(world)
          return false
        end

        terrain = TerrainService.load_or_aggregate(world)
        cells = grid[:cells]
        meta = grid[:meta] || {}

        # Get world time for solar calculations
        world_time = world_time(world, meta)

        # Run simulation steps
        cells = step_solar_heating(cells, terrain, world_time)
        cells = step_pressure_calculation(cells, terrain)
        cells = step_wind_derivation(cells)
        cells = step_advection(cells)
        cells = step_terrain_effects(cells, terrain)
        cells = step_diffusion(cells)
        cells = step_cloud_formation(cells)
        cells = step_precipitation(cells)
        cells = step_instability(cells, terrain)

        # Update metadata
        meta['last_tick_at'] = Time.now.iso8601
        meta['tick_count'] = (meta['tick_count'] || 0) + 1
        meta['world_time'] = world_time

        # Save updated grid
        GridService.save(world, { cells: cells, meta: meta })

        true
      ensure
        GridService.release_lock(world)
      end
    rescue StandardError => e
      warn "[WeatherGrid::SimulationService] Tick failed for world #{world&.id}: #{e.message}"
      GridService.release_lock(world)
      false
    end

    # Tick all worlds with grid weather enabled
    #
    # @return [Hash] Results by world_id
    def tick_all
      results = {}

      query = if World.columns.include?(:use_grid_weather)
                World.where(use_grid_weather: true)
              else
                # If column doesn't exist, check for GridService existence
                World.all.select { |w| GridService.exists?(w) }
              end

      query.each do |world|
        results[world.id] = tick(world)
      end

      results
    rescue StandardError => e
      warn "[WeatherGrid::SimulationService] Tick all failed: #{e.message}"
      {}
    end

    private

    # ========================================
    # Step 1: Solar Heating
    # ========================================

    def step_solar_heating(cells, terrain, world_time)
      # Calculate solar angle based on time of day
      hour = world_time[:hour] || 12
      solar_factor = calculate_solar_factor(hour)

      cells.map.with_index do |cell, i|
        x, y = GridService.index_to_coords(i)
        terrain_cell = terrain_at(terrain, i)

        # Latitude effect: grid_y maps to latitude (-90° at y=0 south pole,
        # +90° at y=63 north pole, equator at y=32). The latitude_factor
        # scales solar heating: 1.0 at the equator, ~0.5 at the poles.
        latitude_factor = 1.0 - (2.0 * (y - GRID_SIZE / 2).abs.to_f / GRID_SIZE).abs * 0.5

        # Cloud cover reduces heating
        cloud_factor = 1.0 - (cell['cloud_cover'] / 100.0) * 0.6

        # Albedo: higher albedo = less heat absorption
        albedo = terrain_cell&.dig('albedo') || 0.25
        absorption = 1.0 - albedo

        if solar_factor > 0
          # Daytime heating
          heating = MAX_SOLAR_HEATING * solar_factor * latitude_factor * cloud_factor * absorption
          cell['temperature'] = clamp_temp(cell['temperature'] + heating)
        else
          # Nighttime cooling (faster in clear skies)
          clear_sky_factor = 1.0 + (1.0 - cell['cloud_cover'] / 100.0) * 0.5
          cooling = NIGHT_COOLING_RATE * clear_sky_factor * solar_factor.abs
          cell['temperature'] = clamp_temp(cell['temperature'] - cooling)
        end

        cell
      end
    end

    def calculate_solar_factor(hour)
      # Returns -1 to 1: negative at night, positive during day
      # Peaks at noon (hour 12)
      angle = (hour - 6) * Math::PI / 12.0
      Math.sin(angle).clamp(-1.0, 1.0)
    end

    # ========================================
    # Step 2: Pressure Calculation
    # ========================================

    def step_pressure_calculation(cells, terrain)
      cells.map.with_index do |cell, i|
        terrain_cell = terrain_at(terrain, i)
        altitude = terrain_cell&.dig('avg_altitude') || 0

        # Base pressure from altitude
        altitude_effect = altitude * PRESSURE_ALTITUDE_FACTOR / 100.0
        base = BASE_PRESSURE - altitude_effect

        # Temperature effect: warmer = lower pressure
        temp_deviation = cell['temperature'] - 15.0 # deviation from 15°C
        temp_effect = temp_deviation * 0.3

        cell['pressure'] = (base - temp_effect).clamp(920.0, 1080.0).round(1)
        cell
      end
    end

    # ========================================
    # Step 3: Wind Derivation
    # ========================================

    def step_wind_derivation(cells)
      new_cells = cells.map(&:dup)

      cells.each_with_index do |cell, i|
        x, y = GridService.index_to_coords(i)
        neighbors = cell_neighbors(cells, x, y)

        # Calculate pressure gradient (steepest descent)
        max_diff = 0.0
        gradient_dir = 0

        neighbors.each do |dir, neighbor|
          next unless neighbor

          diff = cell['pressure'] - neighbor['pressure']
          if diff.abs > max_diff.abs
            max_diff = diff
            gradient_dir = direction_to_degrees(dir)
          end
        end

        # Wind flows perpendicular to gradient due to Coriolis effect.
        # grid_y maps to latitude: y=0 → -90° (south pole), y=32 → 0° (equator),
        # y=63 → +90° (north pole). latitude_factor is -1.0 at south pole,
        # 0.0 at equator, +1.0 at north pole. Coriolis deflection is weaker
        # near the equator (latitude_factor ≈ 0) and strongest at the poles.
        latitude_factor = (y - GRID_SIZE / 2).to_f / (GRID_SIZE / 2)
        coriolis_rotation = 90 * (1 - latitude_factor.abs * 0.3) # Less at equator

        if max_diff > 0
          # High to low pressure direction + Coriolis
          new_cells[i]['wind_dir'] = ((gradient_dir + coriolis_rotation) % 360).round.to_i
          new_cells[i]['wind_speed'] = (max_diff.abs * 3.0).clamp(0.0, 150.0).round(1)
        else
          # Light variable winds when no gradient
          new_cells[i]['wind_speed'] = [new_cells[i]['wind_speed'] * 0.9, 2.0].max.round(1)
        end
      end

      new_cells
    end

    # ========================================
    # Step 4: Advection (wind transport)
    # ========================================

    def step_advection(cells)
      new_cells = cells.map(&:dup)

      cells.each_with_index do |cell, i|
        x, y = GridService.index_to_coords(i)
        wind_speed = cell['wind_speed']
        wind_dir = cell['wind_dir']

        next if wind_speed < 5.0 # Light winds don't advect much

        # Find upwind cell (opposite of wind direction)
        upwind_dir = opposite_direction(wind_dir)
        upwind_x, upwind_y = neighbor_coords(x, y, upwind_dir)

        next unless GridService.valid_coords?(upwind_x, upwind_y)

        upwind_idx = GridService.coords_to_index(upwind_x, upwind_y)
        upwind = cells[upwind_idx]

        # Transfer rate based on wind speed
        rate = (wind_speed / 100.0 * ADVECTION_RATE).clamp(0.0, 0.2)

        # Advect temperature and humidity from upwind
        new_cells[i]['temperature'] = lerp(cell['temperature'], upwind['temperature'], rate)
        new_cells[i]['humidity'] = lerp(cell['humidity'], upwind['humidity'], rate)
      end

      new_cells
    end

    # ========================================
    # Step 5: Terrain Effects
    # ========================================

    def step_terrain_effects(cells, terrain)
      cells.map.with_index do |cell, i|
        terrain_cell = terrain_at(terrain, i)
        next cell unless terrain_cell

        # Evaporation from water bodies
        evap_rate = terrain_cell['evaporation_rate'] || 0.5
        if evap_rate > 1.0
          humidity_add = (evap_rate - 1.0) * 2.0
          cell['humidity'] = (cell['humidity'] + humidity_add).clamp(0.0, 100.0)
        end

        # Orographic effect (mountains force air up → cooling → precipitation)
        mountain_pct = terrain_cell['mountain_pct'] || 0.0
        if mountain_pct > 20 && cell['humidity'] > 60
          # Orographic lift causes precipitation on windward side
          precip_boost = mountain_pct / 100.0 * (cell['humidity'] / 100.0) * 5.0
          cell['precip_rate'] = (cell['precip_rate'] + precip_boost).clamp(0.0, 50.0)
          # Drops humidity (rain shadow effect)
          cell['humidity'] = (cell['humidity'] - precip_boost * 2).clamp(0.0, 100.0)
        end

        # Roughness affects wind speed
        roughness = terrain_cell['roughness'] || 0.5
        wind_reduction = roughness * 0.15
        cell['wind_speed'] = (cell['wind_speed'] * (1.0 - wind_reduction)).clamp(0.0, 150.0).round(1)

        # Altitude temperature adjustment (lapse rate)
        altitude = terrain_cell['avg_altitude'] || 0
        if altitude > 500
          temp_adjustment = (altitude / 1000.0) * LAPSE_RATE * 1000 * 0.1
          cell['temperature'] = (cell['temperature'] - temp_adjustment).clamp(-60.0, 60.0)
        end

        cell
      end
    end

    # ========================================
    # Step 6: Diffusion (smoothing)
    # ========================================

    def step_diffusion(cells)
      new_cells = cells.map(&:dup)

      cells.each_with_index do |cell, i|
        x, y = GridService.index_to_coords(i)
        neighbors = cell_neighbors(cells, x, y)
        neighbor_count = neighbors.values.compact.count

        next if neighbor_count == 0

        # Calculate average of neighbors
        avg_temp = neighbors.values.compact.sum { |n| n['temperature'] } / neighbor_count
        avg_humidity = neighbors.values.compact.sum { |n| n['humidity'] } / neighbor_count
        avg_clouds = neighbors.values.compact.sum { |n| n['cloud_cover'] } / neighbor_count

        # Diffuse towards average
        new_cells[i]['temperature'] = lerp(cell['temperature'], avg_temp, DIFFUSION_RATE)
        new_cells[i]['humidity'] = lerp(cell['humidity'], avg_humidity, DIFFUSION_RATE)
        new_cells[i]['cloud_cover'] = lerp(cell['cloud_cover'], avg_clouds, DIFFUSION_RATE * 0.5)
      end

      new_cells
    end

    # ========================================
    # Step 7: Cloud Formation
    # ========================================

    def step_cloud_formation(cells)
      cells.map do |cell|
        humidity = cell['humidity']

        if humidity > CLOUD_FORMATION_THRESHOLD
          # Cloud formation: humidity above threshold → clouds
          excess = humidity - CLOUD_FORMATION_THRESHOLD
          cloud_increase = excess * 0.3
          cell['cloud_cover'] = (cell['cloud_cover'] + cloud_increase).clamp(0.0, 100.0)
        elsif cell['cloud_cover'] > 10
          # Cloud dissipation when humidity is low
          dissipation = (CLOUD_FORMATION_THRESHOLD - humidity) * 0.1
          cell['cloud_cover'] = (cell['cloud_cover'] - dissipation).clamp(0.0, 100.0)
        end

        cell
      end
    end

    # ========================================
    # Step 8: Precipitation
    # ========================================

    def step_precipitation(cells)
      cells.map do |cell|
        humidity = cell['humidity']
        cloud_cover = cell['cloud_cover']

        if humidity > PRECIPITATION_THRESHOLD && cloud_cover > 50
          # Precipitation occurs
          excess = humidity - PRECIPITATION_THRESHOLD
          precip_intensity = excess * (cloud_cover / 100.0) * 0.5
          cell['precip_rate'] = (cell['precip_rate'] + precip_intensity).clamp(0.0, 50.0)

          # Precipitation removes humidity from air
          cell['humidity'] = (humidity - precip_intensity * 0.8).clamp(0.0, 100.0)
        else
          # Precipitation diminishes
          cell['precip_rate'] = (cell['precip_rate'] * 0.7).round(2)
          cell['precip_rate'] = 0.0 if cell['precip_rate'] < 0.1
        end

        cell
      end
    end

    # ========================================
    # Step 9: Instability Calculation
    # ========================================

    def step_instability(cells, terrain)
      cells.map.with_index do |cell, i|
        x, y = GridService.index_to_coords(i)
        neighbors = cell_neighbors(cells, x, y)

        # Temperature differential with neighbors
        neighbor_temps = neighbors.values.compact.map { |n| n['temperature'] }
        if neighbor_temps.any?
          temp_diff = neighbor_temps.map { |t| (t - cell['temperature']).abs }.max
        else
          temp_diff = 0
        end

        # Instability factors
        temp_instability = temp_diff * INSTABILITY_TEMP_FACTOR * 5
        humidity_instability = [cell['humidity'] - 60, 0].max * INSTABILITY_HUMIDITY_FACTOR

        # Total instability
        instability = temp_instability + humidity_instability

        # High instability with high humidity = storm potential
        if cell['humidity'] > 75
          instability *= 1.3
        end

        cell['instability'] = instability.clamp(0.0, 100.0).round(1)
        cell
      end
    end

    # ========================================
    # Helper Methods
    # ========================================

    def world_time(world, meta)
      # Try to get world time, fall back to real time
      if world.respond_to?(:current_time) && world.current_time
        time = world.current_time
        { hour: time.hour, day: time.day, month: time.month }
      elsif meta['world_time']
        meta['world_time']
      else
        now = Time.now
        { hour: now.hour, day: now.day, month: now.month }
      end
    end

    def terrain_at(terrain, index)
      return nil unless terrain.is_a?(Array)

      terrain[index]
    end

    def cell_neighbors(cells, x, y)
      {
        n: neighbor_cell(cells, x, y - 1),
        ne: neighbor_cell(cells, x + 1, y - 1),
        se: neighbor_cell(cells, x + 1, y + 1),
        s: neighbor_cell(cells, x, y + 1),
        sw: neighbor_cell(cells, x - 1, y + 1),
        nw: neighbor_cell(cells, x - 1, y - 1)
      }
    end

    def neighbor_cell(cells, x, y)
      # Wrap around edges (toroidal topology)
      x = x % GRID_SIZE
      y = y % GRID_SIZE
      cells[GridService.coords_to_index(x, y)]
    end

    def neighbor_coords(x, y, direction)
      case direction
      when :n then [x, y - 1]
      when :ne then [x + 1, y - 1]
      when :se then [x + 1, y + 1]
      when :s then [x, y + 1]
      when :sw then [x - 1, y + 1]
      when :nw then [x - 1, y - 1]
      else [x, y]
      end.map { |c| c % GRID_SIZE }
    end

    def direction_to_degrees(dir)
      case dir
      when :n then 0
      when :ne then 60
      when :se then 120
      when :s then 180
      when :sw then 240
      when :nw then 300
      else 0
      end
    end

    def opposite_direction(degrees)
      case (degrees / 60) % 6
      when 0 then :s   # N → S
      when 1 then :sw  # NE → SW
      when 2 then :nw  # SE → NW
      when 3 then :n   # S → N
      when 4 then :ne  # SW → NE
      when 5 then :se  # NW → SE
      else :s
      end
    end

    def lerp(a, b, t)
      a + (b - a) * t
    end

    def clamp_temp(temp)
      temp.clamp(-60.0, 60.0).round(2)
    end
  end
end
