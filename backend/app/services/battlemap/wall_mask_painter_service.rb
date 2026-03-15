# frozen_string_literal: true

require 'vips'
require 'fileutils'

# Paints rectangles into an entity's wall mask PNG.
# Works with both Room and BattleMapTemplate entities.
# Rectangles are specified as normalized fractions (0.0–1.0) of entity width/height.
# RGB encoding: wall=(255,0,0), door=(0,255,0), window=(0,0,255), black=floor.
class WallMaskPainterService
  MASK_COLORS = {
    'wall'   => [255, 0, 0],
    'door'   => [0, 255, 0],
    'window' => [0, 0, 255]
  }.freeze

  DEFAULT_MASK_SIZE = 1024

  def initialize(entity)
    @entity = entity
    @is_template = entity.is_a?(BattleMapTemplate)
  end

  # Paint a rectangle onto the wall mask.
  # @param frac_x1/y1/x2/y2 [Float] normalized 0.0–1.0 fractions of entity dimensions
  # @param mask_type [String] 'wall', 'door', or 'window'
  # @return [Hash] { success:, mask_url:, mask_width:, mask_height: } or { success: false, error: }
  def paint_rect(frac_x1, frac_y1, frac_x2, frac_y2, mask_type)
    color = MASK_COLORS[mask_type.to_s]
    return { success: false, error: "Unknown mask_type: #{mask_type}" } unless color

    img = load_or_create_mask
    w, h = img.width, img.height

    px1 = (frac_x1.to_f * w).round.clamp(0, w - 1)
    py1 = (frac_y1.to_f * h).round.clamp(0, h - 1)
    px2 = (frac_x2.to_f * w).round.clamp(0, w - 1)
    py2 = (frac_y2.to_f * h).round.clamp(0, h - 1)

    left   = [px1, px2].min
    top    = [py1, py2].min
    width  = ([px1, px2].max - left) + 1
    height = ([py1, py2].max - top) + 1

    # copy_memory gives a mutable in-memory image; draw_rect returns the modified image
    img = img.copy_memory
    img = img.draw_rect(color, left, top, width, height, fill: true)

    # save_mask MUST run before recompute: WallMaskService reads the mask URL
    save_mask(img)
    recompute_wall_hexes_in_pixel_rect(left, top, left + width - 1, top + height - 1, img.width, img.height) unless @is_template

    { success: true, mask_url: mask_url, mask_width: img.width, mask_height: img.height }
  rescue StandardError => e
    warn "[WallMaskPainterService] paint_rect failed for #{entity_label}: #{e.message}"
    { success: false, error: e.message }
  end

  # Clear the wall mask — reset to all-black (all floor).
  def clear!
    path = mask_file_path
    FileUtils.rm(path) if File.exist?(path)
    @entity.update(
      mask_url_column => nil,
      mask_width_column => nil,
      mask_height_column => nil
    )
    unless @is_template
      RoomHex.where(room_id: @entity.id, hex_type: 'wall')
             .update(passable_edges: nil, majority_floor: false)
    end
    { success: true }
  rescue StandardError => e
    warn "[WallMaskPainterService] clear! failed for #{entity_label}: #{e.message}"
    { success: false, error: e.message }
  end

  # Recompute decorative wall/door feature symbols from the wall mask.
  # For rooms: updates RoomHex.wall_feature records.
  # For templates: updates wall_feature in the hex_data JSONB.
  #
  # @return [Hash] { success:, updated_hexes:, marked_hexes:, total_hexes: } or { success: false, error: }
  def regenerate_wall_features!
    wall_mask_path = resolve_path(read_mask_url)
    return { success: false, error: 'No wall mask available' } unless wall_mask_path

    image_path = resolve_path(read_image_url)
    return { success: false, error: 'No battle map image available' } unless image_path

    unless defined?(BattlemapV2::HexOverlayService)
      require_relative '../battlemap_v2/hex_overlay_service'
    end

    # HexOverlayService expects an object with min_x/max_x/min_y/max_y.
    # For templates, synthesize one from width_feet/height_feet.
    room_proxy = @is_template ? build_template_room_proxy : @entity

    overlay = BattlemapV2::HexOverlayService.new(room: room_proxy, image_path: image_path)
    hex_coords = overlay.send(:generate_hex_coordinates)
    return { success: false, error: 'No valid hex coordinates' } if hex_coords.empty?

    base = Vips::Image.new_from_file(image_path, access: :sequential)
    min_x = hex_coords.map(&:first).min
    min_y = hex_coords.map(&:last).min
    pixel_map = overlay.send(:build_hex_pixel_map, hex_coords, min_x, min_y, base.width, base.height)

    coord_lookup = {}
    pixel_map.each_value do |info|
      next unless info.is_a?(Hash) && info[:hx]
      coord_lookup[[info[:hx], info[:hy]]] = info
    end
    overlay.instance_variable_set(:@coord_lookup, coord_lookup)
    overlay.instance_variable_set(:@hex_size, pixel_map[:hex_size])

    @is_template ? regenerate_template_wall_features(overlay, wall_mask_path) : regenerate_room_wall_features(overlay, wall_mask_path)
  rescue StandardError => e
    warn "[WallMaskPainterService] regenerate_wall_features! failed for #{entity_label}: #{e.message}"
    { success: false, error: e.message }
  end

  private

  # --- Wall feature regeneration (room vs template) ---

  def regenerate_room_wall_features(overlay, wall_mask_path)
    room_hexes = @entity.room_hexes_dataset.select(:id, :hex_x, :hex_y, :hex_type, :wall_feature).all
    return { success: true, updated_hexes: 0, marked_hexes: 0, total_hexes: 0 } if room_hexes.empty?

    hex_data = room_hexes.map do |h|
      {
        id: h.id,
        x: h.hex_x,
        y: h.hex_y,
        hex_type: h.hex_type,
        wall_feature: h.hex_type == 'normal' ? nil : h.wall_feature
      }
    end
    overlay.apply_wall_features(hex_data, wall_mask_path: wall_mask_path)

    current_by_id = room_hexes.each_with_object({}) { |h, acc| acc[h.id] = h }
    updated_hexes = 0
    hex_data.each do |h|
      existing = current_by_id[h[:id]]
      next unless existing
      new_feature = h[:wall_feature]
      old_feature = existing.wall_feature
      next if old_feature.to_s == new_feature.to_s
      RoomHex.where(id: existing.id).update(wall_feature: new_feature)
      updated_hexes += 1
    end

    marked_hexes = hex_data.count { |h| !h[:wall_feature].nil? && !h[:wall_feature].to_s.empty? }
    { success: true, updated_hexes: updated_hexes, marked_hexes: marked_hexes, total_hexes: room_hexes.length }
  end

  def regenerate_template_wall_features(overlay, wall_mask_path)
    raw_hexes = JSON.parse(@entity.hex_data.to_json)
    return { success: true, updated_hexes: 0, marked_hexes: 0, total_hexes: 0 } if raw_hexes.empty?

    hex_data = raw_hexes.map do |h|
      hex_type = h['hex_type'] || 'normal'
      {
        x: h['hex_x'],
        y: h['hex_y'],
        hex_type: hex_type,
        wall_feature: hex_type == 'normal' ? nil : h['wall_feature']
      }
    end
    overlay.apply_wall_features(hex_data, wall_mask_path: wall_mask_path)

    # Write wall_feature back into the JSONB hex_data
    feature_map = {}
    hex_data.each { |h| feature_map[[h[:x], h[:y]]] = h[:wall_feature] }

    updated_hexes = 0
    raw_hexes.each do |h|
      new_feature = feature_map[[h['hex_x'], h['hex_y']]]
      old_feature = h['wall_feature']
      next if old_feature.to_s == new_feature.to_s
      h['wall_feature'] = new_feature
      updated_hexes += 1
    end

    if updated_hexes > 0
      BattleMapTemplate.where(id: @entity.id)
                       .update(hex_data: Sequel.pg_jsonb_wrap(raw_hexes))
    end

    marked_hexes = hex_data.count { |h| !h[:wall_feature].nil? && !h[:wall_feature].to_s.empty? }
    { success: true, updated_hexes: updated_hexes, marked_hexes: marked_hexes, total_hexes: raw_hexes.length }
  end

  # Lightweight struct that quacks like a Room for HexOverlayService
  def build_template_room_proxy
    Struct.new(:min_x, :max_x, :min_y, :max_y).new(
      0.0, @entity.width_feet.to_f,
      0.0, @entity.height_feet.to_f
    )
  end

  # --- Column name mapping ---

  def mask_url_column
    @is_template ? :wall_mask_url : :battle_map_wall_mask_url
  end

  def mask_width_column
    @is_template ? :wall_mask_width : :battle_map_wall_mask_width
  end

  def mask_height_column
    @is_template ? :wall_mask_height : :battle_map_wall_mask_height
  end

  def read_mask_url
    @is_template ? @entity.wall_mask_url : @entity.battle_map_wall_mask_url
  end

  def read_image_url
    @is_template ? @entity.image_url : @entity.battle_map_image_url
  end

  def entity_label
    @is_template ? "template #{@entity.id}" : "room #{@entity.id}"
  end

  def file_prefix
    @is_template ? 'template' : 'room'
  end

  # --- Mask I/O ---

  def load_or_create_mask
    url = read_mask_url
    if url
      path = resolve_path(url)
      if path
        img = Vips::Image.new_from_file(path)
        return img.bands >= 3 ? img.extract_band(0, n: 3) : img
      end
    end
    w, h = detect_image_dimensions
    Vips::Image.black(w, h, bands: 3)
  end

  def save_mask(img)
    path = mask_file_path
    FileUtils.mkdir_p(File.dirname(path))
    img.write_to_file(path)
    @entity.update(
      mask_url_column => mask_url,
      mask_width_column => img.width,
      mask_height_column => img.height
    )
  end

  def mask_file_path
    File.join('public', 'uploads', 'battle_maps', "#{file_prefix}_#{@entity.id}_wall_mask.png")
  end

  def mask_url
    "/uploads/battle_maps/#{file_prefix}_#{@entity.id}_wall_mask.png"
  end

  def detect_image_dimensions
    url = read_image_url
    if url
      path = resolve_path(url)
      if path
        img = Vips::Image.new_from_file(path)
        return [img.width, img.height]
      end
    end
    [DEFAULT_MASK_SIZE, DEFAULT_MASK_SIZE]
  rescue Vips::Error
    [DEFAULT_MASK_SIZE, DEFAULT_MASK_SIZE]
  end

  # After painting, recompute passable_edges + majority_floor for all hexes
  # whose hex centers fall within the painted pixel rect. (Rooms only)
  def recompute_wall_hexes_in_pixel_rect(px1, py1, px2, py2, mask_w, mask_h)
    return unless @entity.respond_to?(:min_x) && @entity.min_x && @entity.max_x &&
                  @entity.min_y && @entity.max_y

    room_w = (@entity.max_x - @entity.min_x).to_f
    room_h = (@entity.max_y - @entity.min_y).to_f
    buf    = HexGrid::HEX_SIZE_FEET.to_f

    x1_ft = @entity.min_x + (px1.to_f / mask_w) * room_w - buf
    y1_ft = @entity.min_y + (py1.to_f / mask_h) * room_h - buf
    x2_ft = @entity.min_x + (px2.to_f / mask_w) * room_w + buf
    y2_ft = @entity.min_y + (py2.to_f / mask_h) * room_h + buf

    hx1, hy1 = HexGrid.feet_to_hex(x1_ft, y1_ft, @entity.min_x, @entity.min_y)
    hx2, hy2 = HexGrid.feet_to_hex(x2_ft, y2_ft, @entity.min_x, @entity.min_y)
    min_hx, max_hx = [hx1, hx2].minmax
    min_hy, max_hy = [hy1, hy2].minmax

    wall_hexes = RoomHex
      .where(room_id: @entity.id)
      .where { hex_x >= min_hx }.where { hex_x <= max_hx }
      .where { hex_y >= min_hy }.where { hex_y <= max_hy }
      .all

    mask_svc = WallMaskService.new(@entity)
    wall_hexes.each do |hex|
      edges  = mask_svc.compute_passable_edges(hex.hex_x, hex.hex_y)
      px, py = mask_svc.hex_to_pixel(hex.hex_x, hex.hex_y)
      majority = !mask_svc.wall_pixel?(px, py)
      hex.update(passable_edges: edges, majority_floor: majority)
    end
  end

  # Mirrors WallMaskService#resolve_path — path traversal safe.
  def resolve_path(url)
    return nil if url.nil? || url.strip.empty? || !url.start_with?('/')
    path    = File.expand_path(File.join('public', url))
    allowed = File.expand_path('public')
    return nil unless path.start_with?("#{allowed}/")
    File.exist?(path) ? path : nil
  end
end
