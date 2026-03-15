# frozen_string_literal: true

require 'set'
require 'vips'
require 'json'

# Syncs fire mask detections back into hex classifications so tactical data
# (hex types/hazards) matches animated fire effects.
class FireMaskHexSyncService
  FIRE_OVERLAP_THRESHOLD = 0.12
  FIRE_MIN_DANGER_LEVEL = 3
  FIRE_MIN_DAMAGE_PER_ROUND = 2
  HEX_SAMPLE_RADIUS_FACTOR = 0.45
  STRUCTURAL_TYPES = Set.new(%w[wall off_map door window]).freeze
  DEMOTABLE_TYPES = Set.new(%w[furniture cover concealed]).freeze
  DEMOTION_PRIORITY = { 'furniture' => 0, 'cover' => 1, 'concealed' => 2 }.freeze

  def self.sync_room!(room:, mask_path:)
    new(mask_path).sync_room!(room)
  end

  def self.sync_template!(template:, mask_path:)
    new(mask_path).sync_template!(template)
  end

  def initialize(mask_path, overlap_threshold: FIRE_OVERLAP_THRESHOLD)
    @mask_path = mask_path
    @overlap_threshold = overlap_threshold
  end

  def sync_room!(room)
    mask = load_mask
    return empty_result unless mask

    existing_hexes = room.room_hexes_dataset.all
    coords = HexGrid.hex_coords_for_records(room, hexes: existing_hexes)
    return empty_result if coords.empty?

    coord_lookup, hex_size = build_coord_lookup(coords, mask.width, mask.height)
    fire_coords = detect_fire_coords(coord_lookup, hex_size, mask)
    return empty_result if fire_coords.empty?

    by_coord = {}
    existing_hexes.each { |hex| by_coord[[hex.hex_x, hex.hex_y]] = hex }

    pending = {}
    fire_coords.each do |hx, hy|
      hex = by_coord[[hx, hy]]
      unless hex
        hex = RoomHex.new(
          room_id: room.id,
          hex_x: hx,
          hex_y: hy,
          hex_type: 'normal',
          traversable: true,
          danger_level: 0
        )
        by_coord[[hx, hy]] = hex
      end

      changed = apply_fire_to_room_hex(hex)
      next unless hex.new? || changed

      pending[[hx, hy]] = hex
    end

    punched_out = ensure_fire_reachable_room!(by_coord, fire_coords)
    punched_out.each { |coord| pending[coord] = by_coord[coord] }

    updated = 0
    pending.each_value do |hex|
      hex.save
      updated += 1
    end

    { marked_hexes: fire_coords.length, updated_hexes: updated, punched_out_hexes: punched_out.length }
  rescue StandardError => e
    warn "[FireMaskHexSyncService] Room sync failed for room #{room&.id}: #{e.message}"
    empty_result.merge(error: e.message)
  end

  def sync_template!(template)
    mask = load_mask
    return empty_result unless mask

    hexes = JSON.parse((template.hex_data || []).to_json)
    coords = template_coords(template, hexes)
    return empty_result if coords.empty?

    coord_lookup, hex_size = build_coord_lookup(coords, mask.width, mask.height)
    fire_coords = detect_fire_coords(coord_lookup, hex_size, mask)
    return empty_result if fire_coords.empty?

    by_coord = {}
    hexes.each { |hex| by_coord[[hex['hex_x'].to_i, hex['hex_y'].to_i]] = hex }

    changed_coords = Set.new
    fire_coords.each do |hx, hy|
      hex = by_coord[[hx, hy]]
      unless hex
        hex = {
          'hex_x' => hx,
          'hex_y' => hy,
          'hex_type' => 'normal',
          'traversable' => true
        }
        hexes << hex
        by_coord[[hx, hy]] = hex
      end

      changed_coords << [hx, hy] if apply_fire_to_template_hex(hex)
    end

    punched_out = ensure_fire_reachable_template!(by_coord, fire_coords)
    punched_out.each { |coord| changed_coords << coord }

    template.update(hex_data: Sequel.pg_jsonb_wrap(hexes)) if changed_coords.any?
    {
      marked_hexes: fire_coords.length,
      updated_hexes: changed_coords.length,
      punched_out_hexes: punched_out.length
    }
  rescue StandardError => e
    warn "[FireMaskHexSyncService] Template sync failed for template #{template&.id}: #{e.message}"
    empty_result.merge(error: e.message)
  end

  private

  def empty_result
    { marked_hexes: 0, updated_hexes: 0 }
  end

  def template_coords(template, hexes)
    width = template.respond_to?(:width_feet) ? template.width_feet.to_f : 0.0
    height = template.respond_to?(:height_feet) ? template.height_feet.to_f : 0.0
    generated = if width.positive? && height.positive?
                  HexGrid.hex_coords_for_room(0, 0, width, height)
                else
                  []
                end

    existing = hexes.filter_map do |h|
      next unless h.key?('hex_x') && h.key?('hex_y')
      [h['hex_x'].to_i, h['hex_y'].to_i]
    end

    (generated + existing).uniq
  end

  def apply_fire_to_room_hex(hex)
    changed = false
    changed = assign_if_changed(hex, :hazard_type, 'fire') || changed
    changed = assign_if_changed(hex, :danger_level, [hex.danger_level.to_i, FIRE_MIN_DANGER_LEVEL].max) || changed

    if hex.respond_to?(:hazard_damage_per_round=)
      current_damage = hex.respond_to?(:hazard_damage_per_round) ? hex.hazard_damage_per_round.to_i : 0
      changed = assign_if_changed(hex, :hazard_damage_per_round, [current_damage, FIRE_MIN_DAMAGE_PER_ROUND].max) || changed
    end

    unless STRUCTURAL_TYPES.include?(hex.hex_type.to_s)
      changed = assign_if_changed(hex, :hex_type, 'fire') || changed
      changed = assign_if_changed(hex, :traversable, true) || changed if hex.respond_to?(:traversable=)
    end

    changed
  end

  def apply_fire_to_template_hex(hex)
    changed = false

    if hex['hazard_type'] != 'fire'
      hex['hazard_type'] = 'fire'
      changed = true
    end

    danger_level = [hex['danger_level'].to_i, FIRE_MIN_DANGER_LEVEL].max
    if hex['danger_level'].to_i != danger_level
      hex['danger_level'] = danger_level
      changed = true
    end

    damage = [hex['hazard_damage_per_round'].to_i, FIRE_MIN_DAMAGE_PER_ROUND].max
    if hex['hazard_damage_per_round'].to_i != damage
      hex['hazard_damage_per_round'] = damage
      changed = true
    end

    unless STRUCTURAL_TYPES.include?(hex['hex_type'].to_s)
      if hex['hex_type'] != 'fire'
        hex['hex_type'] = 'fire'
        changed = true
      end
      if hex['traversable'] != true
        hex['traversable'] = true
        changed = true
      end
    end

    changed
  end

  def ensure_fire_reachable_room!(by_coord, fire_coords)
    changed_coords = []
    fire_coords.each do |coord|
      neighbors = HexGrid.hex_neighbors(coord[0], coord[1]).map { |nx, ny| by_coord[[nx, ny]] }.compact
      next if room_neighbor_accessible?(neighbors)

      candidate = select_demotable_room_neighbor(neighbors)
      next unless candidate

      demoted = demote_room_neighbor!(candidate)
      changed_coords << [candidate.hex_x, candidate.hex_y] if demoted
    end
    changed_coords.uniq
  end

  def ensure_fire_reachable_template!(by_coord, fire_coords)
    changed_coords = []
    fire_coords.each do |coord|
      neighbors = HexGrid.hex_neighbors(coord[0], coord[1]).map { |nx, ny| by_coord[[nx, ny]] }.compact
      next if template_neighbor_accessible?(neighbors)

      candidate = select_demotable_template_neighbor(neighbors)
      next unless candidate

      changed_coords << [candidate['hex_x'].to_i, candidate['hex_y'].to_i] if demote_template_neighbor!(candidate)
    end
    changed_coords.uniq
  end

  def room_neighbor_accessible?(neighbors)
    neighbors.any? { |neighbor| neighbor.traversable != false && !STRUCTURAL_TYPES.include?(neighbor.hex_type.to_s) }
  end

  def template_neighbor_accessible?(neighbors)
    neighbors.any? { |neighbor| neighbor['traversable'] != false && !STRUCTURAL_TYPES.include?(neighbor['hex_type'].to_s) }
  end

  def select_demotable_room_neighbor(neighbors)
    neighbors
      .select { |neighbor| DEMOTABLE_TYPES.include?(neighbor.hex_type.to_s) }
      .min_by { |neighbor| DEMOTION_PRIORITY.fetch(neighbor.hex_type.to_s, 9) }
  end

  def select_demotable_template_neighbor(neighbors)
    neighbors
      .select { |neighbor| DEMOTABLE_TYPES.include?(neighbor['hex_type'].to_s) }
      .min_by { |neighbor| DEMOTION_PRIORITY.fetch(neighbor['hex_type'].to_s, 9) }
  end

  def demote_room_neighbor!(hex)
    changed = false
    changed = assign_if_changed(hex, :hex_type, 'normal') || changed
    changed = assign_if_changed(hex, :traversable, true) || changed if hex.respond_to?(:traversable=)
    changed = assign_if_changed(hex, :difficult_terrain, true) || changed if hex.respond_to?(:difficult_terrain=)
    changed = assign_if_changed(hex, :has_cover, false) || changed if hex.respond_to?(:has_cover=)
    changed = assign_if_changed(hex, :cover_object, nil) || changed if hex.respond_to?(:cover_object=)
    changed
  end

  def demote_template_neighbor!(hex)
    changed = false
    if hex['hex_type'] != 'normal'
      hex['hex_type'] = 'normal'
      changed = true
    end
    if hex['traversable'] != true
      hex['traversable'] = true
      changed = true
    end
    if hex['difficult_terrain'] != true
      hex['difficult_terrain'] = true
      changed = true
    end
    if hex['has_cover'] != false
      hex['has_cover'] = false
      changed = true
    end
    if hex['cover_object']
      hex['cover_object'] = nil
      changed = true
    end
    changed
  end

  def assign_if_changed(record, attr, value)
    return false if record.public_send(attr) == value

    record.public_send("#{attr}=", value)
    true
  end

  def load_mask
    return nil if @mask_path.to_s.strip.empty? || !File.exist?(@mask_path)

    mask = Vips::Image.new_from_file(@mask_path)
    mask = mask.extract_band(0) if mask.bands > 1
    mask
  rescue StandardError => e
    warn "[FireMaskHexSyncService] Failed to load mask #{@mask_path}: #{e.message}"
    nil
  end

  def detect_fire_coords(coord_lookup, hex_size, mask)
    coords = []
    coord_lookup.each do |coord, info|
      overlap = compute_hex_overlap(info[:px], info[:py], hex_size, mask)
      coords << coord if overlap >= @overlap_threshold
    end
    coords
  end

  def compute_hex_overlap(px, py, hex_size, mask)
    radius = [(hex_size * HEX_SAMPLE_RADIUS_FACTOR).ceil, 1].max
    x0 = [px - radius, 0].max
    y0 = [py - radius, 0].max
    x1 = [px + radius, mask.width - 1].min
    y1 = [py + radius, mask.height - 1].min
    return 0.0 if x1 <= x0 || y1 <= y0

    patch = mask.crop(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    patch = patch.colourspace(:b_w)[0] if patch.bands > 1
    patch.avg / 255.0
  rescue StandardError => e
    warn "[FireMaskHexSyncService] Overlap sample failed at (#{px},#{py}): #{e.message}"
    0.0
  end

  # Mirrors the same hex→pixel mapping used by BattlemapV2::HexOverlayService.
  def build_coord_lookup(coords, img_width, img_height)
    min_x = coords.map(&:first).min
    min_y = coords.map(&:last).min

    all_xs = coords.map(&:first).uniq.sort
    all_ys = coords.map(&:last).uniq.sort
    num_cols = all_xs.max - all_xs.min
    num_visual_rows = ((all_ys.max - all_ys.min) / 4.0).floor + 1

    size_by_width = img_width.to_f / [num_cols * 1.5 + 2.0, 1].max
    size_by_height = img_height.to_f / [(num_visual_rows + 0.5) * Math.sqrt(3), 1].max
    hex_size = [size_by_width, size_by_height].max
    hex_height = hex_size * Math.sqrt(3)

    lookup = {}
    coords.each do |hx, hy|
      col = hx - min_x
      visual_row = ((hy - min_y) / 4.0).floor
      visual_row = (num_visual_rows - 1) - visual_row
      stagger = col.to_i.odd? ? -hex_height / 2.0 : 0

      px = (hex_size + col * hex_size * 1.5).round
      py = (hex_height / 2.0 + visual_row * hex_height + stagger).round
      lookup[[hx, hy]] = { px: px, py: py }
    end

    [lookup, hex_size]
  end
end
