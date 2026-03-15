# frozen_string_literal: true

require 'faraday'
require 'json'
require 'fileutils'

# DynamicLightingService orchestrates per-fight lighting by calling
# the Python lighting microservice.  All methods are class-level;
# there is no instance state.
#
# The microservice renders a lit version of the room's battle map
# based on environmental conditions (time, weather, moon phase),
# light sources in the room, window openings, and character positions.
#
class DynamicLightingService
  @fire_source_inference_cache = {}

  def self.lighting_service_url
    ENV.fetch('LIGHTING_SERVICE_URL', 'http://localhost:18942')
  end

  class << self
    # Main entry point.  Builds params, POSTs to the lighting service,
    # saves the resulting WebP to tmp/fights/{fight_id}/lit_battlemap.webp,
    # and updates fight.lit_battle_map_url.
    #
    # @param fight [Fight] the fight to render lighting for
    # @return [String, nil] path to the lit image, or nil on failure
    # @side_effect Updates fight.lit_battle_map_url with the public URL of the rendered image.
    def render_for_fight(fight)
      room = fight.room
      return nil unless room
      return nil unless room.has_battle_map

      battlemap_path = resolve_battlemap_path(room)
      return nil unless battlemap_path && File.exist?(battlemap_path)

      img_w, img_h = image_dimensions(battlemap_path)
      return nil unless img_w && img_h && img_w > 0 && img_h > 0

      # Start the lighting service if it's not running; use unlit map if it can't start
      unless LightingServiceManager.ensure_running
        warn "[DynamicLightingService] Lighting service unavailable, using unlit map"
        return nil
      end

      snapshot = fight.lighting_snapshot
      snapshot = build_lighting_snapshot(room) if snapshot.nil? || snapshot.empty?

      # Prefer SAM window mask; fall back to extracting windows from wall mask.
      sam_window_mask_path = resolve_window_mask_path(room, battlemap_path)

      payload = build_render_payload(
        room: room,
        battlemap_path: battlemap_path,
        snapshot: snapshot,
        light_sources: gather_light_sources(room, fight, img_w, img_h),
        characters: gather_character_positions(fight, img_w, img_h),
        depth_map_path: room.depth_map_path ? File.expand_path(room.depth_map_path) : nil,
        zone_map_path: zone_map_path ? File.expand_path(zone_map_path) : nil,
        sam_window_mask_path: sam_window_mask_path
      )

      conn = build_connection
      response = conn.post('/render-lighting', payload.to_json, 'Content-Type' => 'application/json')

      unless response.success?
        warn "[DynamicLightingService] Lighting service returned #{response.status}"
        return nil
      end

      # Save the returned WebP image
      output_dir = File.join('tmp', 'fights', fight.id.to_s)
      FileUtils.mkdir_p(output_dir)
      output_path = File.join(output_dir, 'lit_battlemap.webp')
      File.binwrite(output_path, response.body)

      # Update fight with URL for the lit image
      url = "/api/fights/#{fight.id}/lit_battlemap.webp"
      fight.update(lit_battle_map_url: url)

      LightingServiceManager.mark_used
      output_path
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      warn "[DynamicLightingService] Connection error: #{e.message}"
      nil
    rescue StandardError => e
      warn "[DynamicLightingService] render_for_fight failed: #{e.message}"
      nil
    end

    # Render a lit preview image for the battle map editor.
    # Uses the same Python pipeline as in-game fight rendering, but without characters.
    #
    # @param room [Room]
    # @param hour [Numeric, nil] optional hour override (0.0-24.0)
    # @return [String, nil] public URL to the lit preview image, or nil on failure
    def render_preview_for_room(room, hour: nil)
      return nil unless room
      return nil unless room.has_battle_map

      battlemap_path = resolve_battlemap_path(room)
      return nil unless battlemap_path && File.exist?(battlemap_path)

      img_w, img_h = image_dimensions(battlemap_path)
      return nil unless img_w && img_h && img_w > 0 && img_h > 0

      unless LightingServiceManager.ensure_running
        warn '[DynamicLightingService] Lighting service unavailable for editor preview'
        return nil
      end

      snapshot = build_lighting_snapshot(room)
      unless hour.nil?
        hour_value = hour.to_f % 24.0
        snapshot[:hour] = hour_value.to_i
        snapshot[:time_of_day] = time_of_day_for_hour(hour_value)
        snapshot[:sun_altitude] = (Math.sin((hour_value - 6.0) / 12.0 * Math::PI) * 70.0).clamp(-30.0, 70.0)
        snapshot[:sun_azimuth] = sun_azimuth_for_hour(hour_value)
      end

      # Prefer SAM window mask; fall back to extracting windows from wall mask.
      sam_window_mask_path = resolve_window_mask_path(room, battlemap_path)

      payload = build_render_payload(
        room: room,
        battlemap_path: battlemap_path,
        snapshot: snapshot,
        light_sources: gather_light_sources(room, nil, img_w, img_h),
        characters: [],
        sam_window_mask_path: sam_window_mask_path
      )

      conn = build_connection
      response = conn.post('/render-lighting', payload.to_json, 'Content-Type' => 'application/json')

      unless response.success?
        warn "[DynamicLightingService] Editor preview lighting service returned #{response.status}"
        return nil
      end

      output_dir = File.join('public', 'uploads', 'battle_maps')
      FileUtils.mkdir_p(output_dir)
      output_name = "room_#{room.id}_editor_lit_preview.webp"
      output_path = File.join(output_dir, output_name)
      File.binwrite(output_path, response.body)

      LightingServiceManager.mark_used
      "/uploads/battle_maps/#{output_name}"
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      warn "[DynamicLightingService] Editor preview connection error: #{e.message}"
      nil
    rescue StandardError => e
      warn "[DynamicLightingService] render_preview_for_room failed: #{e.message}"
      nil
    end

    # Capture the current environmental state for lighting calculations.
    #
    # @param room [Room] the room to snapshot
    # @return [Hash] environmental lighting parameters
    def build_lighting_snapshot(room)
      location = room.location
      forced_indoor_night = room.forced_indoor_night_lighting?
      hour = forced_indoor_night ? 0 : GameTimeService.hour(location)
      time_of_day = forced_indoor_night ? 'night' : GameTimeService.time_of_day(location).to_s

      # Sun position — simple sine curve peaking at noon
      sun_altitude = (Math.sin((hour - 6.0) / 12.0 * Math::PI) * 70.0).clamp(-30.0, 70.0)
      sun_azimuth = sun_azimuth_for_hour(hour)

      # Moon
      moon_phase = MoonPhaseService.current_phase
      moon_illumination = moon_phase.illumination
      moon_phase_name = moon_phase.name

      # Season
      season_detail = GameTimeService.season_detail(location)
      season = season_detail[:season].to_s
      season_progress = season_detail[:progress]

      # Weather
      weather = location ? (Weather.for_location(location) rescue nil) : nil
      weather_condition = weather&.condition || 'clear'
      cloud_cover = weather&.cloud_cover || 0

      # Indoor/outdoor
      indoor = forced_indoor_night || !room.outdoor_room?

      {
        time_of_day: time_of_day,
        hour: hour,
        sun_altitude: sun_altitude,
        sun_azimuth: sun_azimuth,
        moon_illumination: moon_illumination,
        moon_phase: moon_phase_name,
        season: season,
        season_progress: season_progress,
        weather: weather_condition,
        cloud_cover: cloud_cover,
        indoor: indoor
      }
    end

    # Merge stored light sources with dynamic fire hexes.
    #
    # @param room [Room] the room
    # @param fight [Fight] the fight (for arena dimensions)
    # @param img_w [Integer] battlemap image width in pixels
    # @param img_h [Integer] battlemap image height in pixels
    # @return [Array<Hash>] light source entries
    def gather_light_sources(room, fight, img_w, img_h)
      sources = []

      # Stored light sources from AI detection (already have pixel coords)
      stored = normalize_light_sources_for_image(room, room.detected_light_sources, img_w, img_h)
      if stored.respond_to?(:each)
        stored.each { |s| sources << s }
      end

      # Dynamic fire hexes — convert hex coords to pixel coords
      arena_w, arena_h = fight ? [fight.arena_width, fight.arena_height] : room_arena_dimensions_for_preview(room)

      room.room_hexes_dataset.where(hex_type: 'fire').each do |hex|
        px, py = if fight
                   hex_to_image_pixel(hex.hex_x, hex.hex_y, fight, img_w, img_h)
                 else
                   hex_to_image_pixel_with_dims(hex.hex_x, hex.hex_y, arena_w, arena_h, img_w, img_h)
                 end
        sources << {
          'type' => 'fire',
          'center_x' => px,
          'center_y' => py,
          'intensity' => 0.8,
          'color' => [1.0, 0.7, 0.3],
          'radius_px' => [img_w, img_h].min / 8
        }
      end

      sources
    end

    # Normalize and sanitize stored light sources in pixel space.
    # This repairs legacy bad data (e.g. fire at 0,0) by inferring a
    # fire centroid from the fire mask when possible.
    #
    # @param entity [Room, BattleMapTemplate]
    # @param raw_sources [Array<Hash>, nil]
    # @param img_w [Integer]
    # @param img_h [Integer]
    # @return [Array<Hash>]
    def normalize_light_sources_for_image(entity, raw_sources, img_w, img_h)
      return [] unless raw_sources.respond_to?(:map)

      default_radius = ([img_w.to_f, img_h.to_f].min / 8.0).round
      raw_sources.map do |src|
        s = src.respond_to?(:to_hash) ? src.to_hash.dup : src.dup
        s = stringify_hash_keys(s)

        source_type = (s['source_type'] || s['type'] || '').to_s
        cx = s['center_x'].to_f
        cy = s['center_y'].to_f
        radius = s['radius_px'].to_f

        pos_out_of_bounds = cx < 0.0 || cy < 0.0 || cx >= img_w.to_f || cy >= img_h.to_f
        pos_zero_origin = cx <= 1.0 && cy <= 1.0

        if source_type == 'fire' && (pos_out_of_bounds || pos_zero_origin)
          inferred = infer_fire_source_from_mask(entity, img_w, img_h)
          if inferred
            cx = inferred[:center_x]
            cy = inferred[:center_y]
            radius = [radius, inferred[:radius_px].to_f].max
          elsif pos_out_of_bounds
            cx = cx.clamp(0.0, img_w.to_f - 1.0)
            cy = cy.clamp(0.0, img_h.to_f - 1.0)
          end
        elsif pos_out_of_bounds
          cx = cx.clamp(0.0, img_w.to_f - 1.0)
          cy = cy.clamp(0.0, img_h.to_f - 1.0)
        end

        radius = default_radius if radius <= 0.0

        s['source_type'] = source_type if source_type != '' && s['source_type'].nil?
        s['center_x'] = cx.round(2)
        s['center_y'] = cy.round(2)
        s['radius_px'] = radius.round(2)
        s
      end
    rescue StandardError => e
      warn "[DynamicLightingService] normalize_light_sources_for_image failed: #{e.message}"
      raw_sources.map { |src| src.respond_to?(:to_hash) ? src.to_hash : src }
    end

    # Windows are extracted from SAM masks on the Python side.
    # The sam_window_mask_path is derived from the battlemap path
    # (e.g. battlemap_abc.webp → battlemap_abc_sam_glass_window.png).
    # Maps without windows simply won't have a SAM mask file.

    # Map fight participants to pixel positions and sizes.
    #
    # @param fight [Fight] the fight
    # @param img_w [Integer] battlemap image width in pixels
    # @param img_h [Integer] battlemap image height in pixels
    # @return [Array<Hash>] participant position data
    def gather_character_positions(fight, img_w, img_h)
      fight.fight_participants_dataset.where(is_knocked_out: false).all.map do |participant|
        px, py = hex_to_image_pixel(participant.hex_x, participant.hex_y, fight, img_w, img_h)
        size = if participant.respond_to?(:monster) && participant.monster
                 participant.monster.size || 'medium'
               else
                 'medium'
               end
        {
          id: participant.id,
          pixel_x: px,
          pixel_y: py,
          size: size
        }
      end
    end

    # Remove temporary lit battlemap files for a fight.
    #
    # @param fight [Fight] the fight to clean up
    def cleanup_fight_lighting(fight)
      dir = File.join('tmp', 'fights', fight.id.to_s)
      FileUtils.rm_rf(dir) if File.directory?(dir)
      fight.update(lit_battle_map_url: nil) if fight.lit_battle_map_url
    rescue StandardError => e
      warn "[DynamicLightingService] cleanup_fight_lighting failed: #{e.message}"
    end

    private

    # Build the JSON payload for the /render-lighting endpoint.
    # Extracts the zone map path from the depth map automatically.
    def build_render_payload(room:, battlemap_path:, snapshot:, light_sources:, characters:, sam_window_mask_path:)
      zone_map_path = nil
      if room.depth_map_path
        candidate = room.depth_map_path.sub(/(\.\w+)$/, '_zone_map.png')
        zone_map_path = candidate if File.exist?(candidate)
      end

      {
        battlemap_path: File.expand_path(battlemap_path),
        environment: snapshot,
        light_sources: light_sources,
        characters: characters,
        depth_map_path: room.depth_map_path ? File.expand_path(room.depth_map_path) : nil,
        zone_map_path: zone_map_path ? File.expand_path(zone_map_path) : nil,
        sam_window_mask_path: sam_window_mask_path
      }
    end

    # Convert hex grid coordinates to pixel coordinates on the battlemap image.
    # Uses proportional mapping based on arena dimensions.
    #
    # @param hex_x [Integer] hex column index
    # @param hex_y [Integer] hex row coordinate (even values in HexGrid)
    # @param fight [Fight] the fight (for arena dimensions)
    # @param img_w [Integer] image width in pixels
    # @param img_h [Integer] image height in pixels
    # @return [Array<Integer>] [pixel_x, pixel_y]
    def hex_to_image_pixel(hex_x, hex_y, fight, img_w, img_h)
      arena_w = fight.arena_width || 10
      arena_h = fight.arena_height || 10
      hex_to_image_pixel_with_dims(hex_x, hex_y, arena_w, arena_h, img_w, img_h)
    end

    def hex_to_image_pixel_with_dims(hex_x, hex_y, arena_w, arena_h, img_w, img_h)
      safe_w = [arena_w.to_i, 1].max
      safe_h = [arena_h.to_i, 1].max

      # hex_x is a column index (0 to arena_w-1)
      px = ((hex_x.to_f + 0.5) / safe_w * img_w).round.clamp(0, img_w - 1)

      # hex_y uses HexGrid even-y convention; max_y = (arena_h - 1) * 4 + 2
      hex_max_y = [(safe_h - 1) * 4 + 2, 1].max
      py = ((hex_y.to_f + 1.0) / (hex_max_y + 2.0) * img_h).round.clamp(0, img_h - 1)

      [px, py]
    end

    def room_arena_dimensions_for_preview(room)
      hexes = room.room_hexes_dataset.select(:hex_x, :hex_y).all
      if hexes.any?
        max_x = hexes.map(&:hex_x).compact.max || 0
        max_y = hexes.map(&:hex_y).compact.max || 0
        return [max_x + 1, (max_y / 4.0).ceil + 1]
      end

      hex_size_feet = defined?(HexGrid::HEX_SIZE_FEET) ? HexGrid::HEX_SIZE_FEET.to_f : 4.0
      room_width_feet = if room.min_x && room.max_x
                          (room.max_x - room.min_x).abs
                        else
                          40
                        end
      room_height_feet = if room.min_y && room.max_y
                           (room.max_y - room.min_y).abs
                         else
                           40
                         end

      arena_w = [(room_width_feet / hex_size_feet).ceil, 1].max
      arena_h = [(room_height_feet / hex_size_feet).ceil, 1].max
      [arena_w, arena_h]
    rescue StandardError => e
      warn "[DynamicLightingService] room_arena_dimensions_for_preview failed: #{e.message}"
      [10, 10]
    end

    def time_of_day_for_hour(hour)
      return 'dawn' if hour >= 5.0 && hour < 7.0
      return 'day' if hour >= 7.0 && hour < 17.0
      return 'dusk' if hour >= 17.0 && hour < 19.0

      'night'
    end

    # Compass-style azimuth: 0=N, 90=E, 180=S, 270=W.
    # We treat 06:00 as east, 12:00 as south, 18:00 as west.
    #
    # @param hour [Numeric]
    # @return [Float]
    def sun_azimuth_for_hour(hour)
      ((hour.to_f % 24.0) / 24.0) * 360.0
    end

    # Read image dimensions without loading the full image.
    #
    # @param path [String] filesystem path to the image
    # @return [Array<Integer, Integer>, Array<nil, nil>] [width, height] or [nil, nil]
    def image_dimensions(path)
      require 'vips'
      img = Vips::Image.new_from_file(path, access: :sequential)
      [img.width, img.height]
    rescue StandardError => e
      warn "[DynamicLightingService] Failed to read image dimensions: #{e.message}"
      [nil, nil]
    end

    # Build a Faraday connection to the lighting microservice.
    #
    # @return [Faraday::Connection]
    def build_connection
      Faraday.new(url: DynamicLightingService.lighting_service_url) do |f|
        f.options.timeout = 60
        f.options.open_timeout = 10
      end
    end

    # Resolve the filesystem path to the room's battle map image.
    #
    # @param room [Room] the room
    # @return [String, nil] filesystem path or nil
    def resolve_battlemap_path(room)
      url = room.battle_map_image_url
      return nil if url.nil? || url.strip.empty?

      # URL is typically "/uploads/battle_maps/..." — resolve to public/
      if url.start_with?('/')
        path = File.expand_path(File.join('public', url))
        allowed_dir = File.expand_path('public')
        # Reject path traversal attempts that escape public/
        return nil unless path.start_with?("#{allowed_dir}/")
        return path if File.exist?(path)
      end

      nil
    end

    # Resolve a window mask path for the lighting service.
    #
    # Priority:
    # 1) SAM window mask adjacent to battlemap file (*_sam_glass_window.png)
    # 2) Derived binary mask from RGB wall mask (blue channel = windows)
    #
    # @param room [Room]
    # @param battlemap_path [String]
    # @return [String, nil] absolute path to window mask
    def resolve_window_mask_path(room, battlemap_path)
      if battlemap_path
        candidate = battlemap_path.sub(/(\.\w+)$/, '_sam_glass_window.png')
        return File.expand_path(candidate) if File.exist?(candidate)
      end

      wall_mask_url = room.respond_to?(:battle_map_wall_mask_url) ? room.battle_map_wall_mask_url : nil
      return nil if wall_mask_url.nil? || wall_mask_url.to_s.strip.empty?

      wall_mask_path = resolve_public_asset_path(wall_mask_url)
      return nil unless wall_mask_path && File.exist?(wall_mask_path)

      derive_window_mask_from_wall_mask(wall_mask_path, room.id)
    end

    # Convert RGB wall mask to a binary SAM-style window mask.
    # Wall mask encoding: wall=(255,0,0), door=(0,255,0), window=(0,0,255).
    #
    # @param wall_mask_path [String]
    # @param room_id [Integer]
    # @return [String, nil] absolute path to generated binary window mask
    def derive_window_mask_from_wall_mask(wall_mask_path, room_id)
      output_dir = File.join('tmp', 'lighting_window_masks')
      FileUtils.mkdir_p(output_dir)
      output_path = File.join(output_dir, "room_#{room_id}_sam_glass_window.png")

      # Reuse cached extraction while wall mask is unchanged.
      if File.exist?(output_path) &&
         File.size(output_path) > 512 &&
         File.mtime(output_path) >= File.mtime(wall_mask_path)
        return File.expand_path(output_path)
      end

      require 'vips'
      img = Vips::Image.new_from_file(wall_mask_path)
      return nil if img.bands < 3

      blue = img.extract_band(2)
      binary = (blue > 127).ifthenelse(255, 0).cast(:uchar)
      return nil if binary.avg <= 0.0

      temp_path = "#{output_path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      binary.pngsave(temp_path)
      return nil unless File.exist?(temp_path) && File.size(temp_path) > 512

      FileUtils.mv(temp_path, output_path, force: true)
      return nil unless File.exist?(output_path) && File.size(output_path) > 512

      File.expand_path(output_path)
    rescue StandardError => e
      warn "[DynamicLightingService] derive_window_mask_from_wall_mask failed: #{e.message}"
      nil
    ensure
      if defined?(temp_path) && temp_path && File.exist?(temp_path)
        FileUtils.rm_f(temp_path)
      end
    end

    # Resolve a public URL (e.g. /uploads/foo.png) to local absolute path.
    #
    # @param url [String]
    # @return [String, nil]
    def resolve_public_asset_path(url)
      return nil unless url.is_a?(String)
      return nil unless url.start_with?('/')

      path = File.expand_path(File.join('public', url))
      public_root = File.expand_path('public')
      return nil unless path.start_with?("#{public_root}/")

      path
    end

    def infer_fire_source_from_mask(entity, img_w, img_h)
      fire_mask_url =
        if entity.respond_to?(:battle_map_fire_mask_url) && !entity.battle_map_fire_mask_url.to_s.strip.empty?
          entity.battle_map_fire_mask_url
        elsif entity.respond_to?(:fire_mask_url) && !entity.fire_mask_url.to_s.strip.empty?
          entity.fire_mask_url
        end
      return nil unless fire_mask_url

      fire_mask_path = resolve_public_asset_path(fire_mask_url)
      return nil unless fire_mask_path && File.exist?(fire_mask_path)

      cache_key = [
        fire_mask_path,
        File.mtime(fire_mask_path).to_i,
        img_w.to_i,
        img_h.to_i
      ].join(':')
      cached = @fire_source_inference_cache[cache_key]
      return cached if cached

      require 'vips'
      img = Vips::Image.new_from_file(fire_mask_path, access: :sequential)
      band = img.bands >= 3 ? img.extract_band(0) : img
      band = band.cast(:uchar) unless band.format == :uchar
      buffer = band.write_to_memory
      width = band.width
      height = band.height

      count = 0
      sum_x = 0.0
      sum_y = 0.0
      min_x = width
      min_y = height
      max_x = 0
      max_y = 0
      idx = 0

      buffer.each_byte do |value|
        if value > 16
          x = idx % width
          y = idx / width
          count += 1
          sum_x += x
          sum_y += y
          min_x = x if x < min_x
          min_y = y if y < min_y
          max_x = x if x > max_x
          max_y = y if y > max_y
        end
        idx += 1
      end
      return nil if count.zero?

      cx = sum_x / count
      cy = sum_y / count
      bbox_w = [max_x - min_x + 1, 1].max
      bbox_h = [max_y - min_y + 1, 1].max
      inferred_radius = [[bbox_w, bbox_h].max * 1.75, [img_w, img_h].min / 3.0].min
      result = {
        center_x: (cx / width.to_f) * img_w.to_f,
        center_y: (cy / height.to_f) * img_h.to_f,
        radius_px: [inferred_radius, [img_w, img_h].min / 12.0].max
      }

      @fire_source_inference_cache[cache_key] = result
      result
    rescue StandardError => e
      warn "[DynamicLightingService] infer_fire_source_from_mask failed: #{e.message}"
      nil
    end

    def stringify_hash_keys(hash)
      return {} unless hash.is_a?(Hash)

      out = {}
      hash.each do |k, v|
        out[k.to_s] = v
      end
      out
    end
  end
end
