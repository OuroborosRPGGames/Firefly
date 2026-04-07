# frozen_string_literal: true

require 'digest'
require 'set'

class HexDescriptionService
  # Direction labels for natural prose
  DIRECTION_NAMES = {
    'n' => 'north', 'ne' => 'northeast', 'se' => 'southeast',
    's' => 'south', 'sw' => 'southwest', 'nw' => 'northwest'
  }.freeze

  # Feature type labels for prose
  FEATURE_LABELS = {
    'road' => 'A road', 'highway' => 'A highway', 'street' => 'A street',
    'trail' => 'A trail', 'river' => 'A river', 'canal' => 'A canal',
    'railway' => 'A railway'
  }.freeze

  # Altitude thresholds (meters)
  FLAT_MAX = 200
  HILL_MAX = 600

  # Visibility bonuses (hex units, ~5km each)
  BASE_RANGE = 2
  HILL_VIEWER_BONUS = 2
  MOUNTAIN_VIEWER_BONUS = 4
  MOUNTAIN_TARGET_BONUS = 4
  CITY_TARGET_BONUS = 2
  LARGE_ZONE_BONUS = 1
  LARGE_ZONE_AREA_THRESHOLD = 50

  # Distance descriptors
  DISTANCE_DESCRIPTORS = {
    near: 'in the distance',     # 3-5 hexes
    far: 'far away',             # 6-9 hexes
    horizon: 'on the horizon'    # 10+ hexes
  }.freeze

  # Notable zone subtypes for distant scanning
  NOTABLE_SUBTYPES = %w[mountain mountain_range volcano].freeze

  class << self
    # Generate a description for a world hex.
    # Returns template immediately; LLM-smoothed version on cache hit or after async job.
    #
    # @param world_hex [WorldHex] the hex to describe
    # @return [Hash] { template:, description:, cached: }
    def describe(world_hex)
      return { template: '', description: '', cached: false } unless world_hex

      template = build_template(world_hex)
      template_hash = Digest::SHA256.hexdigest(template)

      # Check cache
      cached = HexDescriptionCache.find_by_hash(template_hash)
      if cached
        return { template: template, description: cached.description, cached: true }
      end

      # Cache miss: return template as fallback, enqueue async smoothing
      enqueue_smoothing(template, template_hash)

      { template: template, description: template, cached: false }
    end

    private

    # Build the full template from all layers
    def build_template(hex)
      parts = []
      parts << build_current_hex_layer(hex)
      parts << build_zone_layer(hex)

      ring_hexes = []
      parts << build_nearby_layer(hex, ring_hexes)
      parts << build_distant_layer(hex, ring_hexes)
      parts.compact.reject(&:empty?).join(' ')
    end

    # Layer 1: Current hex terrain + features
    def build_current_hex_layer(hex)
      parts = []
      parts << "You stand in #{hex.terrain_description.downcase}."

      # Group directional features by type for natural prose
      features = hex.directional_features
      unless features.empty?
        by_type = {}
        features.each do |dir, types|
          types.each do |type|
            (by_type[type] ||= []) << dir
          end
        end

        by_type.each do |type, dirs|
          label = FEATURE_LABELS[type] || "A #{type}"
          dir_names = dirs.map { |d| DIRECTION_NAMES[d] }.compact
          if dir_names.length == 1
            parts << "#{label} stretches to the #{dir_names.first}."
          elsif dir_names.length > 1
            parts << "#{label} stretches to the #{dir_names[0..-2].join(', ')} and #{dir_names.last}."
          end
        end
      end

      # River from procedural generation
      river_desc = hex.river_description
      parts << river_desc + '.' if river_desc && !river_desc.end_with?('.')
      parts << river_desc if river_desc&.end_with?('.')

      parts.join(' ')
    end

    # Layer 2: Zone context — find smallest area zone containing this hex
    def build_zone_layer(hex)
      zones = Zone.where(world_id: hex.world_id, zone_type: 'area', active: true).all
      containing = zones.select do |z|
        z.world_scale? && z.has_polygon? && z.contains_point?(hex.longitude, hex.latitude)
      end

      return nil if containing.empty?

      # Pick the smallest zone (most specific)
      zone = containing.min_by(&:polygon_area)

      subtype_desc = zone.zone_subtype ? ", a #{zone.zone_subtype.tr('_', ' ')} region" : ''
      "This is part of #{zone.name}#{subtype_desc}."
    end

    # Layer 3: Nearby terrain rings (batched queries)
    # Ring 1 always, ring 2 if hills, ring 3 if mountain
    # @param ring_hexes_out [Array] populated with ring hex data for Layer 4 LOS
    def build_nearby_layer(hex, ring_hexes_out)
      viewer_alt = hex.altitude || 0
      max_rings = if viewer_alt > HILL_MAX then 3
                  elsif viewer_alt > FLAT_MAX then 2
                  else 1
                  end

      # Collect all hex data by ring using batched queries
      visited_ids = Set.new([hex.globe_hex_id])
      all_ring_hexes = []     # [{hex:, ring:}]
      current_ring_hexes = [hex]

      (1..max_rings).each do |ring|
        # Collect neighbor IDs from current ring, subtract visited
        next_ids = Set.new
        current_ring_hexes.each do |h|
          ids = h.neighbor_globe_hex_ids
          next unless ids
          ids.each { |id| next_ids.add(id) unless visited_ids.include?(id) }
        end
        break if next_ids.empty?

        visited_ids.merge(next_ids)

        # Single batched query per ring
        ring_hexes = WorldHex.where(world_id: hex.world_id, globe_hex_id: next_ids.to_a).all
        ring_hexes.each { |h| all_ring_hexes << { hex: h, ring: ring } }
        current_ring_hexes = ring_hexes
      end

      return nil if all_ring_hexes.empty?

      # Store ring hexes for Layer 4 LOS check (via out parameter)
      ring_hexes_out.concat(all_ring_hexes)

      # Group by terrain type, excluding same-as-center
      by_terrain = {}
      all_ring_hexes.each do |entry|
        h = entry[:hex]
        next if h.terrain_type == hex.terrain_type

        dir = WorldHex.direction_between_hexes(hex, h)
        next unless dir

        (by_terrain[h.terrain_type] ||= Set.new).add(dir)
      end

      return nil if by_terrain.empty?

      # Build prose
      parts = by_terrain.map do |terrain, dirs|
        desc = terrain_phrase(terrain)
        dir_names = dirs.map { |d| DIRECTION_NAMES[d] }.compact.sort
        if dir_names.length == 1
          "#{desc} to the #{dir_names.first}"
        else
          "#{desc} to the #{dir_names[0..-2].join(', ')} and #{dir_names.last}"
        end
      end

      parts.join('. ') + '.'
    end

    # Human-readable terrain phrases for Layer 3
    def terrain_phrase(terrain)
      phrases = {
        'ocean' => 'Ocean waters lie',
        'lake' => 'Lake waters stretch',
        'rocky_coast' => 'Rocky coastline extends',
        'sandy_coast' => 'Sandy beach stretches',
        'grassy_plains' => 'Open grassland spreads',
        'rocky_plains' => 'Rocky flatlands extend',
        'light_forest' => 'Scattered woodland lies',
        'dense_forest' => 'Dense forest lies',
        'jungle' => 'Thick jungle grows',
        'swamp' => 'Swampland stretches',
        'mountain' => 'Mountains rise',
        'mountain_peak' => 'Mountain peaks tower',
        'grassy_hills' => 'Grassy hills roll',
        'rocky_hills' => 'Rocky hills rise',
        'tundra' => 'Frozen tundra stretches',
        'desert' => 'Desert sands spread',
        'volcanic' => 'Volcanic terrain lies',
        'urban' => 'Urban development sprawls',
        'light_urban' => 'Suburban areas extend'
      }
      phrases[terrain] || "#{terrain.tr('_', ' ').capitalize} lies"
    end

    # Layer 4: Distant notable features (cities, mountains, volcanoes)
    # @param ring_hexes [Array] ring hex data from Layer 3 for LOS checks
    def build_distant_layer(hex, ring_hexes)
      viewer_alt = hex.altitude || 0

      # Query notable zones: cities + zones with notable subtypes
      candidates = Zone.where(world_id: hex.world_id, active: true)
        .where(
          Sequel.|(
            { zone_type: 'city' },
            Sequel.~(zone_subtype: nil)
          )
        ).all

      return nil if candidates.empty?

      # Calculate viewer bonus
      viewer_bonus = if viewer_alt > HILL_MAX
                       MOUNTAIN_VIEWER_BONUS
                     elsif viewer_alt > FLAT_MAX
                       HILL_VIEWER_BONUS
                     else
                       0
                     end

      # Ring hexes from Layer 3 (passed via parameter for LOS)
      ring_hexes ||= []

      visible = []
      candidates.each do |zone|
        # Get zone's location as lat/lon
        target_hex = if zone.globe_hex_id
                       WorldHex.find_by_globe_hex(hex.world_id, zone.globe_hex_id)
                     end

        next unless target_hex

        # Calculate distance in hex units
        dist_rad = WorldHex.great_circle_distance_rad(
          hex.latitude, hex.longitude,
          target_hex.latitude, target_hex.longitude
        )
        dist_hexes = (dist_rad * 6371.0 / 5.0).round

        # Skip if within ring scan range (already covered by Layer 3)
        next if dist_hexes <= (viewer_alt > HILL_MAX ? 3 : (viewer_alt > FLAT_MAX ? 2 : 1))

        # Calculate target bonus
        target_bonus = 0
        target_bonus += MOUNTAIN_TARGET_BONUS if NOTABLE_SUBTYPES.include?(zone.zone_subtype)
        target_bonus += CITY_TARGET_BONUS if zone.zone_type == 'city'
        target_bonus += LARGE_ZONE_BONUS if zone.polygon_area > LARGE_ZONE_AREA_THRESHOLD

        max_range = BASE_RANGE + viewer_bonus + target_bonus
        next if dist_hexes > max_range

        # Simplified LOS: check if any ring hex in the target direction blocks sight
        direction = WorldHex.direction_between_hexes(hex, target_hex)
        next unless direction

        blocked = ring_hexes.any? do |entry|
          rh = entry[:hex]
          rh_dir = WorldHex.direction_between_hexes(hex, rh)
          rh_dir == direction && rh.blocks_sight? && (rh.altitude || 0) >= viewer_alt
        end
        next if blocked

        # Determine distance descriptor
        descriptor = case dist_hexes
                     when 3..5 then DISTANCE_DESCRIPTORS[:near]
                     when 6..9 then DISTANCE_DESCRIPTORS[:far]
                     else DISTANCE_DESCRIPTORS[:horizon]
                     end

        visible << { zone: zone, direction: direction, descriptor: descriptor, distance: dist_hexes }
      end

      return nil if visible.empty?

      # Sort by distance (closest first), limit to 3 most notable
      visible.sort_by! { |v| v[:distance] }
      visible = visible.first(3)

      # Build prose
      parts = visible.map do |v|
        zone = v[:zone]
        dir_name = DIRECTION_NAMES[v[:direction]]
        type_hint = case zone.zone_subtype
                    when 'mountain', 'mountain_range' then "the peaks of #{zone.name}"
                    when 'volcano' then "the volcanic #{zone.name}"
                    else zone.name
                    end
        if zone.zone_type == 'city'
          "#{v[:descriptor].capitalize} to the #{dir_name}, #{zone.name} can be seen."
        else
          "#{v[:descriptor].capitalize} to the #{dir_name}, #{type_hint} #{v[:distance] > 5 ? 'is visible' : 'can be seen'}."
        end
      end

      parts.join(' ')
    end

    # Fire-and-forget LLM smoothing in a background thread
    def enqueue_smoothing(template, template_hash)
      Thread.new do
        smooth_template(template, template_hash)
      rescue StandardError => e
        warn "[HexDescriptionService] Async smoothing failed: #{e.message}"
      end
    end

    # Call LLM to smooth the template and store in cache
    def smooth_template(template, template_hash)
      # Double-check cache (another thread may have beaten us)
      return if HexDescriptionCache.find_by_hash(template_hash)

      prompt = GamePrompts.get_safe('hex_description.smooth', template: template)
      return unless prompt

      result = LLM::TextGenerationService.generate(
        prompt: prompt,
        provider: 'google',
        options: { max_tokens: 300, temperature: 0.7 }
      )

      if result[:success] && result[:text] && !result[:text].strip.empty?
        HexDescriptionCache.store(
          template: template,
          hash: template_hash,
          description: result[:text].strip
        )
      else
        warn "[HexDescriptionService] LLM smoothing returned no text: #{result[:error]}"
      end
    end
  end
end
