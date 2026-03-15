# frozen_string_literal: true

module BattlemapV2
  # Applies hex grid overlay to battlemap and classifies hexes from object masks
  # and window data.
  #
  # Hex classification priority:
  #   1. Object masks (SAM2G): >50% overlap → object type (largest wins ties)
  #   2. Window mask: >50% overlap → window hex_type
  #   3. Everything else → floor (wall/door handled by pixel mask, not hex_type)
  #
  # Wall and door pixels are NOT converted to hex_type='wall' or hex_type='door'.
  # Instead, the pixel-level wall mask (WallMaskService) handles movement/LOS at
  # sub-hex precision. Hexes remain floor unless they contain an object or window.
  class HexOverlayService
    OVERLAP_THRESHOLD = 0.50  # 50% of hex must be inside mask
    WINDOW_OVERLAP_THRESHOLD = 0.50

    # Python debug visualization scripts (in lib/cv/)
    CV_DIR = File.expand_path('../../../lib/cv', __dir__)
    HEX_GRID_SCRIPT = File.join(CV_DIR, 'debug_hex_grid.py')
    HEX_CLASSIFIED_SCRIPT = File.join(CV_DIR, 'debug_hex_classified.py')

    # Shared type-to-color mapping for debug visualizations
    TYPE_COLORS = {
      'normal'            => [100, 200, 100],
      'wall'              => [50,  50,  50],
      'off_map'           => [20,  20,  20],
      'furniture'         => [255, 150, 50],
      'cover'             => [50,  200, 200],
      'water'             => [50,  100, 255],
      'fire'              => [255, 80,  0],
      'window'            => [180, 220, 240],
      'trap'              => [220, 0,   0],
      'difficult_terrain' => [200, 220, 100]
    }.freeze

    attr_reader :coord_lookup

    def initialize(room:, image_path:)
      @room = room
      @image_path = image_path
      @coord_lookup = {}
      @hex_size = nil
    end

    # Classify all hexes for the room.
    # @param object_masks [Hash] { type_name => { mask_path:, coverage:, ... } }
    # @param wall_mask_path [String, nil] RGB wall mask (for off_map detection)
    # @param window_mask_path [String, nil] binary window mask
    # @param l1_data [Hash] L1 scene analysis (for type properties)
    # @param type_properties [Hash] custom type properties
    # @return [Array<Hash>] hex data for persist_hex_data
    def classify_hexes(object_masks:, wall_mask_path: nil, window_mask_path: nil,
                       l1_data: {}, type_properties: {})
      require 'vips'

      hex_coords = generate_hex_coordinates
      return [] if hex_coords.empty?

      min_x = hex_coords.map { |x, _| x }.min
      min_y = hex_coords.map { |_, y| y }.min

      base = Vips::Image.new_from_file(@image_path)
      img_w = base.width
      img_h = base.height

      hex_pixel_map = build_hex_pixel_map(hex_coords, min_x, min_y, img_w, img_h)
      @hex_size = hex_pixel_map[:hex_size]

      @coord_lookup = {}
      hex_pixel_map.each do |key, info|
        next unless info.is_a?(Hash) && info[:hx]
        @coord_lookup[[info[:hx], info[:hy]]] = info
      end

      # Start with all hexes as floor — use symbol keys to match persist_hex_data expectations
      hex_data = hex_coords.map do |hx, hy|
        { x: hx, y: hy, hex_type: 'normal', label: 'open_floor' }
      end

      # Apply object masks (>50% overlap)
      apply_object_masks(hex_data, object_masks, type_properties)

      # Apply off_map detection (uses @image_path — no wall mask needed)
      apply_wall_mask_offmap(hex_data)

      # Apply window mask
      apply_window_mask(hex_data, window_mask_path) if window_mask_path

      # Mark floor hexes that a wall or door significantly crosses with a feature symbol.
      # If wall_mask_path is nil (pipeline runs this in parallel with wall analysis),
      # call apply_wall_features separately after wall analysis completes.
      apply_wall_feature_symbols(hex_data, wall_mask_path) if wall_mask_path

      # Ensure fire (and water) hexes are always reachable.
      # A fireplace SAM mask often covers the whole structure as furniture/cover,
      # with the fire mask only covering the interior — leaving fire hexes walled
      # in by blocking neighbours. Find any such trapped hazard hex and open the
      # cheapest adjacent blocking hex (furniture/cover → difficult_terrain).
      ensure_hazards_reachable(hex_data)

      hex_data
    end

    # Apply wall feature symbols to already-classified hex_data.
    # Call this after wall analysis when classify_hexes was run without a wall_mask_path.
    def apply_wall_features(hex_data, wall_mask_path:)
      apply_wall_feature_symbols(hex_data, wall_mask_path) if wall_mask_path
    end

    # Generate hex grid and classified-hex visualization images for the inspect page.
    # Must be called after classify_hexes (uses @coord_lookup and @hex_size).
    # Writes hex_grid.png, hex_classified.png, and (if object_masks given) hex_objects.png to output_dir.
    def generate_debug_images(hex_data, output_dir:, object_masks: {})
      return unless @coord_lookup.any? && @hex_size && @hex_size > 0

      require 'open3'
      generate_hex_grid_image(output_dir)
      generate_hex_classified_image(hex_data, output_dir)
      generate_hex_objects_image(hex_data, object_masks, output_dir) if object_masks.any?
    rescue StandardError => e
      warn "[HexOverlay] Debug image generation failed: #{e.message}"
    end

    private

    def generate_hex_coordinates
      room_w = (@room.max_x - @room.min_x).to_f
      room_h = (@room.max_y - @room.min_y).to_f
      HexGrid.hex_coords_for_room(0, 0, room_w, room_h)
    end

    # Build a mapping from hex coordinates to pixel positions on the image.
    # Calculates hex_size to fill the image, then places each hex center.
    def build_hex_pixel_map(hex_coords, min_x, min_y, img_w, img_h)
      all_xs = hex_coords.map { |x, _| x }.uniq.sort
      all_ys = hex_coords.map { |_, y| y }.uniq.sort
      num_cols = all_xs.max - all_xs.min
      num_visual_rows = ((all_ys.max - all_ys.min) / 4.0).floor + 1

      hex_size_by_width = img_w.to_f / [num_cols * 1.5 + 2.0, 1].max
      hex_size_by_height = img_h.to_f / [(num_visual_rows + 0.5) * Math.sqrt(3), 1].max
      hex_size = [hex_size_by_width, hex_size_by_height].max

      hex_height = hex_size * Math.sqrt(3)

      pixel_map = {}
      hex_coords.each do |hx, hy|
        col = hx - min_x
        visual_row = ((hy - min_y) / 4.0).floor
        # Y-flip: high hex Y = low pixel Y (north at top)
        visual_row = (num_visual_rows - 1) - visual_row
        stagger = col.to_i.odd? ? -hex_height / 2.0 : 0

        px = (hex_size + col * hex_size * 1.5).round
        py = (hex_height / 2.0 + visual_row * hex_height + stagger).round
        pixel_map[[hx, hy]] = { px: px, py: py, hx: hx, hy: hy }
      end
      pixel_map[:hex_size] = hex_size
      pixel_map
    end

    # SAM source priority: samg > lang_sam > sam2grounded > none/unknown
    SAM_SOURCE_PRIORITY = { samg: 3, lang_sam: 2, sam2grounded: 1 }.freeze

    # Hazard types always win over cover/furniture/etc. regardless of SAM source.
    # Fire and water are environmental facts that must not be obscured by object detection.
    HAZARD_TYPES = Set.new(%w[fire water puddle wading_water deep_water]).freeze

    # Lower overlap threshold for hazards: a fireplace doesn't need to fill half a hex
    # to be real. Using 25% avoids fire hexes being "locked out" by the 50% threshold.
    HAZARD_OVERLAP_THRESHOLD = 0.25

    # Apply object masks to hex data. Higher SAM source priority wins; ties broken by overlap.
    # Hazard types (fire, water) override all other types when they meet the lower threshold.
    def apply_object_masks(hex_data, object_masks, type_properties)
      return if object_masks.empty?

      require 'vips'
      # Load all masks into Vips images, preserving source model info
      loaded = {}
      object_masks.each do |type_name, info|
        path = info[:mask_path] || info['mask_path']
        next unless path && File.exist?(path)
        begin
          model = (info[:model] || info['model'])&.to_sym
          loaded[type_name] = { img: Vips::Image.new_from_file(path), priority: SAM_SOURCE_PRIORITY[model] || 0 }
        rescue StandardError => e
          warn "[HexOverlay] Failed to load mask for #{type_name}: #{e.message}"
        end
      end
      return if loaded.empty?

      hex_data.each do |hex|
        info = @coord_lookup[[hex[:x], hex[:y]]]
        next unless info

        best_type = nil
        best_overlap = 0.0
        best_priority = -1
        best_is_hazard = false

        loaded.each do |type_name, mask_info|
          is_hazard = HAZARD_TYPES.include?(type_name.to_s.strip.downcase.gsub(/\s+/, '_'))
          threshold = is_hazard ? HAZARD_OVERLAP_THRESHOLD : OVERLAP_THRESHOLD
          overlap = compute_hex_overlap(info[:px], info[:py], mask_info[:img])
          next unless overlap > threshold

          # Hazards beat non-hazards unconditionally.
          # Among hazards or among non-hazards: SAM source priority wins, then overlap.
          priority = mask_info[:priority]
          hazard_wins = is_hazard && !best_is_hazard
          non_hazard_loses = !is_hazard && best_is_hazard
          next if non_hazard_loses

          if hazard_wins || priority > best_priority || (priority == best_priority && overlap > best_overlap)
            best_overlap = overlap
            best_priority = priority
            best_type = type_name
            best_is_hazard = is_hazard
          end
        end

        if best_type
          # Normalize label for lookup: trim, downcase, collapse whitespace → underscores
          normalized_type = best_type.strip.downcase.gsub(/\s+/, '_')
          mapped = BattlemapV2::HexTypeMapping::SIMPLE_TYPE_TO_ROOM_HEX[normalized_type]
          if mapped
            hex.merge!(mapped)
          else
            # Custom type — use tactical properties from L1
            props = type_properties[normalized_type] || type_properties[best_type] || {}
            if props['provides_concealment']
              hex[:hex_type] = 'concealed'
              hex[:difficult_terrain] = true if props['difficult_terrain']
            elsif props['provides_cover']
              hex[:hex_type] = 'cover'
              hex[:has_cover] = true
            else
              hex[:hex_type] = 'furniture'
              hex[:has_cover] = false
            end
            hex[:cover_object] = best_type if props['provides_cover']
            hex[:difficult_terrain] = true if props['difficult_terrain']
            hex[:traversable] = props['traversable'] if props.key?('traversable')
          end
          hex[:label] = normalized_type
        end
      end
    end

    # Mark hexes as off_map if they're at the image border and appear white/blank
    # in the original image — indicating exterior canvas outside the room.
    def apply_wall_mask_offmap(hex_data)
      require 'vips'
      img = Vips::Image.new_from_file(@image_path)
      grey = img.bands > 1 ? img.colourspace(:b_w)[0] : img
      border_margin = @hex_size * 2

      hex_data.each do |hex|
        info = @coord_lookup[[hex[:x], hex[:y]]]
        next unless info

        # Don't override hexes already classified by object masks.
        # Hazard hexes (fire, water) are explicitly protected — they must never be
        # reclassified as off_map even if they sit at the image border.
        next if hex[:label] && hex[:label] != 'open_floor'
        next if HAZARD_TYPES.include?(hex[:hex_type].to_s)

        at_border = info[:px] < border_margin || info[:py] < border_margin ||
                    info[:px] > grey.width - border_margin || info[:py] > grey.height - border_margin
        next unless at_border

        brightness = compute_hex_overlap(info[:px], info[:py], grey)
        if brightness > 0.94  # ~240/255 — essentially white/blank exterior
          hex[:hex_type] = 'off_map'
          hex[:label] = 'off_map'
          hex[:traversable] = false
        end
      end
    rescue StandardError => e
      warn "[HexOverlay] Off-map detection failed: #{e.message}"
    end

    # Mark open_floor hexes that a wall or door cuts through a meaningful slice of.
    # Wall mask is RGB: red=wall, green=door, blue=window.
    # Uses the full hex bounding box rather than a center patch so thin walls
    # that cross a corner or edge are not missed.
    # Door takes priority over wall when both are present.
    def apply_wall_feature_symbols(hex_data, wall_mask_path)
      return unless wall_mask_path && File.exist?(wall_mask_path)
      require 'vips'
      mask = Vips::Image.new_from_file(wall_mask_path)
      return if mask.bands < 2

      wall_band = mask[0]  # red = wall
      door_band = mask[1]  # green = door

      half_w = (@hex_size).ceil
      half_h = (@hex_size * Math.sqrt(3) / 2).ceil

      hex_data.each do |hex|
        next unless hex[:hex_type] == 'normal'
        info = @coord_lookup[[hex[:x], hex[:y]]]
        next unless info

        px = info[:px]
        py = info[:py]

        x0 = [px - half_w, 0].max
        y0 = [py - half_h, 0].max
        x1 = [px + half_w, mask.width - 1].min
        y1 = [py + half_h, mask.height - 1].min
        next if x1 <= x0 || y1 <= y0

        w = x1 - x0 + 1
        h = y1 - y0 + 1

        door_coverage = door_band.crop(x0, y0, w, h).avg / 255.0
        if door_coverage > 0.05
          hex[:wall_feature] = 'door'
          next
        end

        wall_coverage = wall_band.crop(x0, y0, w, h).avg / 255.0
        hex[:wall_feature] = 'wall' if wall_coverage > 0.35
      end

      # Validate doors: a door feature with no wall-feature neighbours is a
      # floating detection (Gemini mislabelled something, or a wall section was
      # missed entirely). Remove it so it doesn't create a door into open space.
      feat_map = {}
      hex_data.each { |h| feat_map[[h[:x], h[:y]]] = h[:wall_feature] }
      hex_data.each do |hex|
        next unless hex[:wall_feature] == 'door'
        has_wall_nbr = HexGrid.hex_neighbors(hex[:x], hex[:y]).any? do |nx, ny|
          feat_map[[nx, ny]] == 'wall'
        end
        hex.delete(:wall_feature) unless has_wall_nbr
      end
    rescue StandardError => e
      warn "[HexOverlay] Wall feature symbols failed: #{e.message}"
    end

    # Ensure every hazard hex (fire, water) has at least one traversable neighbour.
    # Problem: a fireplace is often detected as one big furniture/cover SAM mask,
    # with the fire mask only covering the interior. This leaves fire hexes trapped
    # behind blocking furniture hexes with no way in.
    # Fix: for each trapped hazard hex, find the adjacent furniture/cover hex with
    # the lowest overlap (least structurally significant) and demote it to
    # difficult_terrain so there's always a path in.
    def ensure_hazards_reachable(hex_data)
      # Build lookup: (x,y) → hex
      hex_map = {}
      hex_data.each { |h| hex_map[[h[:x], h[:y]]] = h }

      # Types that block access but can be demoted to open the path
      demotable = Set.new(%w[furniture cover concealed])

      hex_data.each do |hex|
        next unless HAZARD_TYPES.include?(hex[:hex_type].to_s)

        nbrs = HexGrid.hex_neighbors(hex[:x], hex[:y]).map { |nx, ny| hex_map[[nx, ny]] }.compact
        next if nbrs.any? { |n| n[:traversable] != false && !%w[wall off_map].include?(n[:hex_type].to_s) }

        # Hex is trapped — find the most demotable neighbour (furniture preferred over cover)
        candidate = nbrs.select { |n| demotable.include?(n[:hex_type].to_s) }
                        .min_by { |n| n[:hex_type] == 'furniture' ? 0 : 1 }
        next unless candidate

        candidate[:hex_type]        = 'normal'
        candidate[:traversable]     = true
        candidate[:difficult_terrain] = true
        candidate[:has_cover]       = false
        candidate.delete(:cover_object)
      end
    rescue StandardError => e
      warn "[HexOverlay] ensure_hazards_reachable failed: #{e.message}"
    end

    # Apply window mask — hexes with >50% window overlap become window type
    def apply_window_mask(hex_data, window_mask_path)
      return unless window_mask_path && File.exist?(window_mask_path)
      require 'vips'
      window = Vips::Image.new_from_file(window_mask_path)

      hex_data.each do |hex|
        info = @coord_lookup[[hex[:x], hex[:y]]]
        next unless info

        overlap = compute_hex_overlap(info[:px], info[:py], window)
        if overlap > WINDOW_OVERLAP_THRESHOLD
          hex[:hex_type] = 'window'
          hex[:label] = 'glass_window'
          hex[:traversable] = false
        end
      end
    rescue StandardError => e
      warn "[HexOverlay] Window mask failed: #{e.message}"
    end

    def generate_hex_grid_image(output_dir)
      out_path = File.join(output_dir, 'hex_grid.png')
      points = @coord_lookup.map { |(_hx, _hy), info| { 'px' => info[:px], 'py' => info[:py] } }
      return if points.empty?

      Open3.capture3('python3', HEX_GRID_SCRIPT, @image_path, points.to_json, @hex_size.to_s, out_path)
    rescue StandardError => e
      warn "[HexOverlay] Hex grid image failed: #{e.message}"
    end

    def generate_hex_classified_image(hex_data, output_dir)
      out_path = File.join(output_dir, 'hex_classified.png')
      items = hex_data.filter_map do |hex|
        info = @coord_lookup[[hex[:x], hex[:y]]]
        next unless info
        { 'px' => info[:px], 'py' => info[:py],
          'hex_type' => hex[:hex_type].to_s,
          'label' => (hex[:label] || hex[:hex_type]).to_s }
      end
      return if items.empty?

      Open3.capture3('python3', HEX_CLASSIFIED_SCRIPT, @image_path, items.to_json,
                     @hex_size.to_s, TYPE_COLORS.to_json, out_path)
    rescue StandardError => e
      warn "[HexOverlay] Hex classified image failed: #{e.message}"
    end

    HEX_OBJECTS_SCRIPT = File.join(CV_DIR, 'debug_hex_objects.py')

    def generate_hex_objects_image(hex_data, object_masks, output_dir)
      out_path = File.join(output_dir, 'hex_objects.png')
      palette = [
        [255, 80, 80], [80, 200, 80], [80, 80, 255], [255, 200, 0],
        [255, 80, 255], [0, 200, 200], [255, 140, 0], [140, 0, 255],
        [0, 200, 140], [255, 0, 140], [140, 220, 0], [0, 140, 255]
      ]
      mask_entries = {}
      object_masks.each_with_index do |(type_name, info), idx|
        path = info[:mask_path] || info['mask_path']
        next unless path && File.exist?(path)
        mask_entries[type_name] = { 'path' => path, 'color' => palette[idx % palette.length] }
      end

      items = hex_data.filter_map do |hex|
        info = @coord_lookup[[hex[:x], hex[:y]]]
        next unless info
        { 'px' => info[:px], 'py' => info[:py], 'hex_type' => hex[:hex_type].to_s }
      end

      Open3.capture3('python3', HEX_OBJECTS_SCRIPT, @image_path,
                     mask_entries.to_json, items.to_json,
                     @hex_size.to_s, TYPE_COLORS.to_json, out_path)
    rescue StandardError => e
      warn "[HexOverlay] Hex objects image failed: #{e.message}"
    end

    # Compute fraction of hex area overlapping with a binary mask
    def compute_hex_overlap(px, py, mask)
      r = [(@hex_size * 0.45).ceil, 1].max

      x0 = [px - r, 0].max
      y0 = [py - r, 0].max
      x1 = [px + r, mask.width - 1].min
      y1 = [py + r, mask.height - 1].min

      return 0.0 if x1 <= x0 || y1 <= y0

      patch = mask.crop(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
      patch = patch.colourspace(:b_w)[0] if patch.bands > 1
      patch.avg / 255.0
    rescue StandardError => e
      warn "[HexOverlay] Failed overlap at (#{px},#{py}): #{e.message}"
      0.0
    end
  end
end
