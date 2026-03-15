#!/usr/bin/env ruby
# frozen_string_literal: true

# Battle Map Pipeline Inspector
# ==============================
# Runs the real image generation + processing pipeline step by step,
# saving intermediate results and producing an HTML inspection page.
#
# Usage:
#   cd backend
#   bundle exec ruby tmp/battlemap_inspect.rb <room_id> [--skip-generate] [--cv]
#
# Output: tmp/battlemap_inspect/room_<id>/index.html

$stdout.sync = true
require 'fileutils'
require 'base64'
require 'json'
require 'vips'

# Boot the application
require_relative '../../config/room_type_config'
Dir[File.join(__dir__, '../../app/lib/*.rb')].each { |f| require f }
require_relative '../../config/application'

class BattleMapInspector
  # Expose private methods from the real service
  class InspectService < AIBattleMapGeneratorService
    public :generate_battlemap_image, :calculate_image_dimensions,
           :build_image_prompt, :capped_room_dimensions,
           :generate_hex_coordinates, :build_hex_pixel_map,
           :upscale_if_needed, :run_overview_pass,
           :build_spatial_chunks, :generate_local_edge_map, :generate_shadow_aware_edge_map,
           :map_results_to_room_hex, :normalize_v3,
           :norm_v3_off_map_flood, :norm_v3_object_clearing, :norm_v3_zone_validation, :norm_v3_border_walls, :norm_v3_shape_snap, :norm_v3_flat_shape_snap, :norm_v3_object_flood,
           :norm_v3_wall_flood, :norm_v3_elevation_fix, :norm_v3_elevated_objects,
           :norm_v3_terrain_color_pass, :norm_v3_sam_features,
           :norm_v3_exit_guided_doors, :norm_v3_wall_door_detection, :norm_v3_door_join,
           :norm_v3_passthrough, :norm_v3_lockoff_detection, :norm_v3_cleanup_errant, :norm_v3_inaccessible,
           :extract_hex_features,
           :crop_image_for_chunk, :overlay_sequential_labels_on_crop,
           :build_sequential_labels, :build_grouped_chunk_prompt,
           :build_chunk_tool, :parse_grouped_chunk, :types_for_chunk,
           :crop_border_with_image, :filter_partial_edge_hexes,
           :validate_battlemap_image, :check_battlemap_shadows, :remove_battlemap_shadows,
           :categorize_types_for_sam, :map_sam_masks_to_hexes, :map_type_masks_to_hexes,
           :map_depth_to_elevation, :detect_wall_hexes_via_skeleton, :type_category,
           :generate_zone_map, :build_hex_zone_map, :build_hex_depth_map,
           :classify_hexes_with_overlap

    attr_reader :coord_lookup

    def setup_coord_lookup(hex_pixel_map)
      @coord_lookup = {}
      hex_pixel_map.each do |_label, info|
        next unless info.is_a?(Hash) && info[:hx]
        @coord_lookup[[info[:hx], info[:hy]]] = info
      end
    end
  end

  attr_reader :room, :svc, :out_dir, :steps

  def initialize(room_id, skip_generate: false, grid_only: false, hex_only: false, use_gemini: false, cv_mode: false, fake_exits: nil)
    @room = Room[room_id]
    raise "Room #{room_id} not found" unless @room
    @svc = InspectService.new(@room, debug: true)
    @out_dir = File.join(__dir__, 'battlemap_inspect', "room_#{room_id}")
    FileUtils.mkdir_p(@out_dir)
    @steps = []
    @skip_generate = skip_generate
    @grid_only = grid_only
    @hex_only = hex_only
    @use_gemini = use_gemini
    @cv_mode = cv_mode
    @fake_exits = fake_exits  # Array of direction symbols for testing exit-guided doors
    @file_mutex = Mutex.new
  end

  def run
    @pipeline_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @stage_timings = []
    log "Pipeline Inspector for: #{room.name} (Room #{room.id})"
    log "Room bounds: #{room.min_x},#{room.min_y} -> #{room.max_x},#{room.max_y}"
    log "Output: #{out_dir}/index.html"
    puts

    timed_stage("Room Info") { step_room_info }
    timed_stage("Image Prompt") { step_image_prompt }
    timed_stage("Image Generation") { step_generate_image }
    timed_stage("Trim + Upscale") { step_trim_borders }
    timed_stage("Hex Grid") { step_hex_grid }

    # --- Parallel fan-out: edge, depth, and classification are independent ---
    parallel_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    parallel_threads = []

    # Thread 1: Edge detection (local shadow-aware + Sobel, ~1-2s)
    parallel_threads << Thread.new { timed_stage("Edge Detection") { step_edge_detection } }

    # Thread 2: Depth estimation (Replicate API, ~20s)
    parallel_threads << Thread.new { timed_stage("Depth Estimation") { step_depth_estimation } }

    # Thread 3 (experiment): SAM2 auto-segmentation to inspect output format
    parallel_threads << Thread.new { timed_stage("SAM2 Experiment") { step_sam2_experiment } }

    if @cv_mode
      # CV mode: overview needed for classification
      parallel_threads << Thread.new { timed_stage("Overview") { step_overview } }
    else
      # Grid classification L1→L2→L3 (Gemini, ~55s; also starts SAM after L1)
      parallel_threads << Thread.new { timed_stage("Grid Classification") { step_grid_classification } } unless @hex_only
      # Overview for chunk path
      parallel_threads << Thread.new { timed_stage("Overview") { step_overview } } unless @grid_only
    end

    parallel_threads.each(&:join)
    # Join background Replicate edge comparison thread if it's still running
    @replicate_edge_thread&.join

    parallel_dur = Process.clock_gettime(Process::CLOCK_MONOTONIC) - parallel_t0
    @file_mutex.synchronize { @stage_timings << ["  (parallel wall-clock)", parallel_dur] }

    # Zone map needs both edge + depth (both now complete)
    timed_stage("Zone Map") { step_zone_map }
    timed_stage("Depth Shapes") { step_depth_shapes }

    if @cv_mode
      timed_stage("CV Classification") { step_cv_classification }
      timed_stage("CV Normalization") { step_cv_normalization }
    else
      timed_stage("Chunk Classification") { step_classification } unless @grid_only
      # Grid classification already ran in parallel above
      timed_stage("Normalization") { step_normalization }
    end

    timed_stage("Type Mapping") { step_type_mapping }
    timed_stage("Crop Border") { step_crop_border }

    total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @pipeline_start
    puts
    log "=== Pipeline Timing ==="
    @stage_timings.each { |name, dur| log "  %-25s %6.1fs" % [name, dur] }
    log "  %-25s %6.1fs" % ["TOTAL", total]
    log "========================"

    write_html
    log "\nDone! Open: #{out_dir}/index.html"
  end

  private

  def log(msg)
    puts msg
  end

  def timed_stage(name)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    dur = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    @file_mutex.synchronize { @stage_timings << [name, dur] }
  end

  def add_step(title, content: nil, image: nil, code: nil, data: nil)
    step = { title: title, content: content, image: image, code: code, data: data }
    @file_mutex.synchronize do
      @steps << step
      log "  [#{@steps.length}] #{title}"
    end
  end

  def save_image(vips_image, name)
    path = File.join(out_dir, name)
    vips_image.write_to_file(path)
    path
  end

  def copy_image(src, name)
    dst = File.join(out_dir, name)
    FileUtils.cp(src, dst)
    dst
  end

  # --- Step: Room Info ---
  def step_room_info
    dims = svc.capped_room_dimensions
    img_dims = svc.calculate_image_dimensions
    hex_coords = svc.generate_hex_coordinates

    add_step "Room Info",
      data: {
        "Name" => room.name,
        "Room ID" => room.id,
        "Bounds" => "#{room.min_x},#{room.min_y} -> #{room.max_x},#{room.max_y}",
        "Capped dimensions" => "#{dims[0]} x #{dims[1]} ft",
        "Target image" => "#{img_dims[:width]} x #{img_dims[:height]} px",
        "Hex count" => hex_coords.length
      }
  end

  # --- Step: Image Prompt ---
  def step_image_prompt
    prompt = svc.build_image_prompt
    add_step "Image Generation Prompt",
      code: prompt
  end

  # --- Step: Generate Image ---
  def step_generate_image
    # Check for existing image we can reuse
    existing = Dir.glob(File.join(out_dir, '01_raw_image.*')).max_by { |f| File.mtime(f) }
    if @skip_generate && existing
      @raw_image_path = existing
      add_step "Image Generation (cached)",
        content: "Reusing cached image: #{File.basename(existing)}",
        image: File.basename(existing)
      return
    end

    prompt = svc.build_image_prompt
    aspect_ratio = svc.send(:calculate_aspect_ratio)
    dims = svc.send(:calculate_image_dimensions)

    max_attempts = 3
    result = nil
    validation = nil

    max_attempts.times do |attempt|
      tier = attempt < 2 ? :default : :high_quality
      tier_name = tier == :default ? 'flash 3.1' : 'pro'
      log "  Generating image via Gemini #{tier_name} (attempt #{attempt + 1}/#{max_attempts})..."

      result = LLM::ImageGenerationService.generate(
        prompt: prompt,
        options: { aspect_ratio: aspect_ratio, dimensions: dims, tier: tier }
      )
      unless result[:success]
        add_step "Image Generation FAILED (attempt #{attempt + 1})", content: "Error: #{result[:error]}"
        next
      end

      src = "public/#{result[:local_url]}"
      validation = svc.validate_battlemap_image(src)
      if validation[:pass]
        log "    Validation passed: #{validation[:reason]}"

        # Check for shadows and remove them
        shadow_check = svc.check_battlemap_shadows(src)
        if shadow_check[:has_shadows]
          log "    Shadows detected: #{shadow_check[:reason]}"
          add_step "Shadow Detection",
            content: "Shadows found: #{shadow_check[:reason]}\nAttempting shadow removal..."
          @shadowed_image_path = src  # Keep shadowed version for depth estimation
          shadow_result = svc.remove_battlemap_shadows(src)
          if shadow_result[:success]
            log "    Shadows removed successfully"
            result[:local_url] = shadow_result[:local_path].sub(%r{^public/?}, '')
            add_step "Shadow Removal",
              content: "Successfully regenerated without shadows"
          else
            log "    Shadow removal failed: #{shadow_result[:error]}, using original"
            @shadowed_image_path = nil
            add_step "Shadow Removal FAILED",
              content: "Error: #{shadow_result[:error]}\nUsing original image"
          end
        else
          log "    No significant shadows: #{shadow_check[:reason]}"
        end

        break
      end

      log "    Validation failed: #{validation[:reason]}"
      add_step "Image Validation FAILED (attempt #{attempt + 1})",
        content: "Tier: #{tier_name}\n#{validation[:reason]}"
      File.delete(src) if File.exist?(src)
      result = nil
    end

    unless result&.dig(:success)
      add_step "Image Generation FAILED", content: "All #{max_attempts} attempts failed"
      raise "Image generation failed after #{max_attempts} attempts"
    end

    src = "public/#{result[:local_url]}"
    raw = Vips::Image.new_from_file(src)
    fname = "01_raw_image#{File.extname(src)}"
    copy_image(src, fname)
    @raw_image_path = File.join(out_dir, fname)

    tier_used = validation && !validation[:pass] ? 'last attempt' : (result[:provider_used] || 'unknown')
    add_step "Image Generation",
      content: "#{raw.width} x #{raw.height} px, #{File.size(src)} bytes\nValidation: #{validation&.dig(:reason) || 'n/a'}",
      image: fname
  end

  # --- Step: Trim Borders ---
  def step_trim_borders
    return unless @raw_image_path

    # When skipping generation, reuse cached processed image only if newer than raw
    if @skip_generate
      existing_processed = Dir.glob(File.join(out_dir, '02_processed.*')).max_by { |f| File.mtime(f) }
      if existing_processed && File.mtime(existing_processed) >= File.mtime(@raw_image_path)
        @processed_image_path = existing_processed
        img = Vips::Image.new_from_file(existing_processed)
        add_step "Trim + Upscale + Convert",
          content: "Reusing cached processed image: #{File.basename(existing_processed)}\n#{img.width} x #{img.height}",
          image: File.basename(existing_processed)
        return
      end
    end

    # Work on a copy so we preserve the raw
    trimmed_path = File.join(out_dir, "02_trimmed#{File.extname(@raw_image_path)}")
    FileUtils.cp(@raw_image_path, trimmed_path)

    before = Vips::Image.new_from_file(trimmed_path)
    before_dims = "#{before.width} x #{before.height}"

    MapSvgRenderService.trim_image_borders(trimmed_path)

    after = Vips::Image.new_from_file(trimmed_path)
    after_dims = "#{after.width} x #{after.height}"

    # Upscale check
    upscaled_path = svc.upscale_if_needed(trimmed_path)
    upscaled = Vips::Image.new_from_file(upscaled_path)
    upscaled_dims = "#{upscaled.width} x #{upscaled.height}"

    # Convert to webp
    webp_path = MapSvgRenderService.convert_to_webp(upscaled_path)
    @processed_image_path = webp_path
    processed_name = "02_processed#{File.extname(webp_path)}"
    FileUtils.cp(webp_path, File.join(out_dir, processed_name))

    add_step "Trim + Upscale + Convert",
      content: "Before trim: #{before_dims}\nAfter trim: #{after_dims}\nAfter upscale: #{upscaled_dims}\nFinal: #{File.extname(webp_path)}, #{File.size(webp_path)} bytes",
      image: processed_name
  end

  # --- Step: Hex Grid ---
  def step_hex_grid
    return unless @processed_image_path

    base = Vips::Image.new_from_file(@processed_image_path)
    hex_coords = svc.generate_hex_coordinates
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min

    # Use the LARGER hex size so the grid fills the full image in both dimensions.
    # build_hex_pixel_map uses min(width_fit, height_fit), which leaves a gap.
    # We override with max so hexes cover the entire image. Some hexes may extend
    # beyond the image boundary — those get classified as off_map by normalization.
    @hex_pixel_map = svc.build_hex_pixel_map(hex_coords, min_x, min_y, base.width, base.height)
    hex_size_w = base.width.to_f / [((hex_coords.map { |x, _| x }.uniq.sort.max - hex_coords.map { |x, _| x }.uniq.sort.min) * 1.5 + 2.0), 1].max
    hex_size_h = base.height.to_f / [((((hex_coords.map { |_, y| y }.uniq.sort.max - hex_coords.map { |_, y| y }.uniq.sort.min) / 4.0).floor + 1) + 0.5) * Math.sqrt(3), 1].max
    if (hex_size_w - hex_size_h).abs > 0.5
      # Rebuild with the larger hex size so grid covers full image
      bigger_size = [hex_size_w, hex_size_h].max
      offset_x = @hex_pixel_map[:offset_x] || 0
      offset_y = @hex_pixel_map[:offset_y] || 0
      pixel_map = {}
      hex_coords.each do |hx, hy|
        label = svc.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
        px, py = svc.send(:hex_to_pixel, hx, hy, min_x, min_y, bigger_size, offset_x, offset_y)
        pixel_map[label] = { px: px, py: py, hx: hx, hy: hy }
      end
      pixel_map[:hex_size] = bigger_size
      pixel_map[:offset_x] = offset_x
      pixel_map[:offset_y] = offset_y
      @hex_pixel_map = pixel_map
      svc.instance_variable_set(:@analysis_hex_size, bigger_size)
      log "  Hex size: #{bigger_size.round(1)}px (overridden from #{[hex_size_w, hex_size_h].min.round(1)}px to fill image)"
    end
    svc.setup_coord_lookup(@hex_pixel_map)
    @hex_coords = hex_coords
    @min_x = min_x
    @min_y = min_y
    @base_image = base

    hex_size = @hex_pixel_map[:hex_size]

    # Render hex grid overlay as SVG on image
    svg_hexes = hex_coords.map do |hx, hy|
      info = svc.coord_lookup[[hx, hy]]
      next unless info
      points = hexagon_points(info[:px], info[:py], hex_size)
      "<polygon points='#{points}' fill='none' stroke='cyan' stroke-width='0.5' opacity='0.4'/>"
    end.compact.join("\n")

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{base.width}" height="#{base.height}">
        #{svg_hexes}
      </svg>
    SVG

    overlay = Vips::Image.svgload_buffer(svg)
    overlay = overlay.resize(base.width.to_f / overlay.width, vscale: base.height.to_f / overlay.height) if overlay.width != base.width

    # Flatten base (ensure RGBA) + composite overlay
    base_rgba = base.bands >= 4 ? base : base.bandjoin(255)
    overlay_rgba = overlay.bands >= 4 ? overlay : overlay.bandjoin(255)
    composite = base_rgba.composite(overlay_rgba, :over)

    fname = "03_hex_grid.png"
    save_image(composite, fname)

    add_step "Hex Grid Overlay",
      content: "#{hex_coords.length} hexes, hex_size=#{hex_size.round(1)}px\nGrid: x=#{hex_coords.map(&:first).minmax.join('..')}, y=#{hex_coords.map(&:last).minmax.join('..')}",
      image: fname
  end

  # --- Step: Overview ---
  def step_overview
    return unless @processed_image_path

    log "  Running overview pass..."
    @overview = svc.run_overview_pass(@processed_image_path)
    unless @overview
      add_step "Overview FAILED", content: "Overview pass returned nil"
      return
    end

    type_names = (@overview['present_types'] || []).map { |t| t['type_name'] }
    regional = @overview['regional_types'] || []

    add_step "Overview Pass",
      content: "Scene: #{@overview['scene_description']}\n\nLayout: #{@overview['map_layout']}",
      data: {
        "Types found" => type_names.join(', '),
        "Regional types" => regional.map { |r| "#{r['region']}: #{(r['types'] || []).join(', ')}" }.join("\n")
      },
      code: JSON.pretty_generate(@overview)
  end

  # --- Step: Edge Detection ---
  # Shadow-aware CLAHE+Canny is primary (local, fast).
  # Local Sobel is fallback. Replicate Canny is background comparison only.
  def step_edge_detection
    return unless @base_image

    log "  Running edge detection..."
    @edge_map = nil

    # Primary: Shadow-aware CLAHE+Canny (local, ~1-2s)
    shadow_edge = svc.generate_shadow_aware_edge_map(@processed_image_path)
    if shadow_edge
      @edge_map = shadow_edge
      fname = "04_edge_shadow_aware.png"
      save_image(shadow_edge, fname)
      shadow_avg = shadow_edge.extract_band(0).avg
      add_step "Edge Detection (Shadow-Aware CLAHE+Canny)",
        content: "#{shadow_edge.width} x #{shadow_edge.height}, avg brightness: #{shadow_avg.round(1)}\nPrimary edge map for normalization.",
        image: fname
    end

    # Fallback: Local Sobel
    local_edge = svc.generate_local_edge_map(@base_image)
    if local_edge
      @edge_map ||= local_edge
      fname = "04_edge_sobel.png"
      save_image(local_edge, fname)
      local_avg = local_edge.extract_band(0).avg
      add_step "Edge Detection (Local Sobel)",
        content: "#{local_edge.width} x #{local_edge.height}, avg brightness: #{local_avg.round(1)}#{@edge_map == local_edge ? "\nUsed as fallback (shadow-aware failed)." : "\nShown for comparison only."}",
        image: fname
    end

    # Background comparison: Replicate Canny (non-blocking, visual comparison only)
    @replicate_edge_thread = Thread.new do
      next unless ReplicateEdgeDetectionService.available?
      result = ReplicateEdgeDetectionService.detect(@processed_image_path, mode: :canny)
      if result[:success] && result[:edge_map_path] && File.exist?(result[:edge_map_path])
        candidate = Vips::Image.new_from_file(result[:edge_map_path])
        avg = candidate.extract_band(0).avg
        if avg > 5 && avg < 250
          if candidate.width != @base_image.width || candidate.height != @base_image.height
            candidate = candidate.resize(@base_image.width.to_f / candidate.width,
                                          vscale: @base_image.height.to_f / candidate.height)
          end
          fname = "04_edge_replicate.png"
          @file_mutex.synchronize { save_image(candidate, fname) }
          add_step "Edge Detection (Replicate Canny)",
            content: "#{candidate.width} x #{candidate.height}, avg brightness: #{avg.round(1)}\nBackground comparison only — not used for normalization.",
            image: fname
        end
      end
    rescue StandardError => e
      warn "[EdgeDetect] Replicate comparison failed: #{e.message}"
    end
  end

  # --- Step: Depth Estimation (Replicate API, runs in parallel) ---
  def step_depth_estimation
    return unless @base_image

    log "  Running depth estimation..."
    @depth_map = nil
    @depth_path = nil

    if ReplicateDepthService.available?
      depth_source = @shadowed_image_path || @processed_image_path
      depth_result = ReplicateDepthService.estimate(depth_source)
      if depth_result[:success] && depth_result[:depth_path] && File.exist?(depth_result[:depth_path])
        @depth_path = depth_result[:depth_path]
        @depth_map = Vips::Image.new_from_file(depth_result[:depth_path])
        @depth_map = @depth_map.extract_band(0) if @depth_map.bands > 1
        if @depth_map.width != @base_image.width || @depth_map.height != @base_image.height
          @depth_map = @depth_map.resize(@base_image.width.to_f / @depth_map.width,
                                          vscale: @base_image.height.to_f / @depth_map.height)
        end

        fname = "04_depth.png"
        @file_mutex.synchronize { save_image(@depth_map, fname) }
        add_step "Depth Estimation (Replicate)",
          content: "#{@depth_map.width} x #{@depth_map.height}",
          image: fname
        log "    Depth: loaded (#{@depth_map.width}x#{@depth_map.height})"
      else
        add_step "Depth Estimation", content: "Failed: #{depth_result[:error]}"
      end
    else
      add_step "Depth Estimation", content: "Replicate API key not configured"
    end
  end

  # --- Step: SAM2 Auto-Segmentation Experiment ---
  # Calls rehbbea/sam2 with both output_format modes to inspect the raw output structure.
  # Results are saved to sam2_overlay.png and sam2_raw_output.json in the out_dir.
  def step_sam2_experiment
    return unless @processed_image_path && File.exist?(@processed_image_path)

    log "  Running SAM2 auto-segmentation experiment (meta/sam-2)..."

    # Use ReplicateDepthService as the client proxy (it extends ReplicateClientHelper)
    rc = ReplicateDepthService
    api_key = rc.send(:replicate_api_key)
    unless api_key && !api_key.empty?
      add_step "SAM2 Experiment", content: "Replicate API key not configured"
      return
    end

    mime = rc.send(:detect_mime_type, @processed_image_path)
    data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(@processed_image_path))}"
    conn = rc.send(:build_connection, api_key, timeout: 300)

    version = rc.send(:resolve_model_version, conn, 'meta/sam-2')
    unless version
      add_step "SAM2 Experiment", content: "Could not resolve meta/sam-2 model version"
      return
    end
    log "    meta/sam-2 version: #{version[0..7]}..."

    # Submit prediction — meta/sam-2 output: { combined_mask: url, individual_masks: [url, ...] }
    resp = conn.post('predictions') do |req|
      req.headers['Prefer'] = 'wait=60'
      req.body = {
        version: version,
        input: {
          image: data_uri,
          points_per_side: 16,
          pred_iou_thresh: 0.80,
          stability_score_thresh: 0.92,
        }
      }
    end

    unless resp.success?
      add_step "SAM2 Experiment", content: "Replicate API error: HTTP #{resp.status}: #{resp.body[0..200]}"
      return
    end

    result = JSON.parse(resp.body)
    on_done = ->(r) { { success: true, output: r['output'] } }

    prediction = case result['status']
    when 'succeeded'
      on_done.call(result)
    when 'starting', 'processing'
      rc.send(:poll_prediction,
        status_url: result['urls']&.dig('get'),
        api_key: api_key,
        max_attempts: 80,
        poll_interval: 3,
        timeout_error: 'meta/sam-2 polling timed out after 4 minutes',
        on_success: on_done,
        on_failed:   ->(r) { { success: false, error: r['error'].to_s } },
        on_canceled: ->(r) { { success: false, error: 'prediction canceled' } }
      )
    when 'failed'
      { success: false, error: result['error'].to_s }
    else
      { success: false, error: "Unexpected status: #{result['status']}" }
    end

    unless prediction[:success]
      add_step "SAM2 Experiment", content: "Prediction failed: #{prediction[:error]}"
      return
    end

    output = prediction[:output]
    summary = ["version: #{version[0..7]}...", "output keys: #{output.is_a?(Hash) ? output.keys.join(', ') : output.class}"]

    # Download combined mask for display
    combined_image = nil
    combined_url = output.is_a?(Hash) ? output['combined_mask'] : nil
    if combined_url&.start_with?('http')
      img_resp = Faraday.get(combined_url)
      if img_resp.success?
        path = File.join(out_dir, 'sam2_combined_mask.png')
        File.binwrite(path, img_resp.body)
        combined_image = 'sam2_combined_mask.png'
        summary << "combined_mask: #{img_resp.body.bytesize} bytes"
        log "    SAM2 combined mask: saved"
      end
    end

    # Download individual masks and analyse them
    individual_urls = output.is_a?(Hash) ? Array(output['individual_masks']) : []
    summary << "individual_masks: #{individual_urls.length} URLs"
    log "    SAM2: #{individual_urls.length} individual masks"

    # Download all masks to a dedicated subdirectory using the naming convention
    # expected by build_sam2_shapes: mask_NNNN.png
    sam2_masks_subdir = File.join(out_dir, 'sam2_masks')
    FileUtils.rm_rf(sam2_masks_subdir)
    FileUtils.mkdir_p(sam2_masks_subdir)
    mask_stats = []
    download_threads = individual_urls.each_with_index.map do |url, i|
      Thread.new do
        mask_resp = Faraday.get(url)
        next unless mask_resp.success?
        path = File.join(sam2_masks_subdir, "mask_#{i.to_s.rjust(4, '0')}.png")
        File.binwrite(path, mask_resp.body)
        img = Vips::Image.new_from_file(path)
        img = img.extract_band(0) if img.bands > 1
        white_px = (img.avg / 255.0 * img.width * img.height).round
        mask_stats << { i: i, white_px: white_px, w: img.width, h: img.height }
      rescue StandardError => e
        mask_stats << { i: i, error: e.message }
      end
    end
    download_threads.each(&:join)

    @sam2_masks_dir = sam2_masks_subdir  # expose for step_depth_shapes to use

    mask_stats.sort_by! { |s| s[:i] }
    if mask_stats.any?
      areas = mask_stats.filter_map { |s| s[:white_px] }
      summary << "downloaded #{mask_stats.length}/#{individual_urls.length} masks → #{sam2_masks_subdir}"
      summary << "pixel areas: min=#{areas.min} max=#{areas.max} mean=#{areas.sum / areas.length}" if areas.any?
      code_preview = mask_stats.first(20).map { |s|
        s[:error] ? "mask #{s[:i]}: ERROR #{s[:error]}" : "mask #{s[:i]}: #{s[:white_px]} px (#{s[:w]}x#{s[:h]})"
      }.join("\n")
      code_preview += "\n... (#{mask_stats.length - 20} more)" if mask_stats.length > 20
    end

    # Save URL list for reference
    File.write(File.join(out_dir, 'sam2_mask_urls.json'),
               JSON.pretty_generate({ version: version, individual_masks: individual_urls }))

    add_step "SAM2 Experiment (meta/sam-2)",
      content: summary.join("\n"),
      image: combined_image,
      code: code_preview
  rescue StandardError => e
    add_step "SAM2 Experiment", content: "Error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
  end

  # --- Step: Zone Map (needs edge + depth, runs after both complete) ---
  def step_zone_map
    return unless @depth_map && @edge_map

    log "  Generating zone map..."
    @zone_map = nil

    @zone_map = svc.generate_zone_map(@depth_path, @edge_map,
                                      debug_dir: out_dir)
    if @zone_map
      if @zone_map.width != @base_image.width || @zone_map.height != @base_image.height
        @zone_map = @zone_map.resize(@base_image.width.to_f / @zone_map.width,
                                      vscale: @base_image.height.to_f / @zone_map.height,
                                      kernel: :nearest)
      end

      zone_debug_images = {
        'zone_depth_gradient.png'      => 'Zone: Depth Gradient (Sobel on depth)',
        'zone_depth_edges.png'         => 'Zone: Depth Edges (thresholded gradient)',
        'zone_structural_boundary.png' => 'Zone: Structural Boundary (depth edges only)',
        'zone_wall_elevation.png'      => 'Zone: Wall Elevation (top-hat, constrained to border band)',
        'zone_obj_edges_thresholded.png' => 'Zone: Object Edges (Sobel threshold)',
        'zone_obj_contours_filled.png' => 'Zone: Object Contours (filled, area filtered)',
        'zone_off_map.png'             => 'Zone: Off-Map Regions (border flood fill)',
        'zone_wall.png'                => 'Zone: Wall Band (between off_map and interior)',
        'zone_object.png'              => 'Zone: Object Regions (contours intersected with interior)',
        'zone_colorized.png'           => 'Zone Map (final) — off_map(gray) wall(red) floor(tan) object(green)'
      }
      zone_debug_images.each do |filename, title|
        path = File.join(out_dir, filename)
        next unless File.exist?(path)
        add_step title,
          content: "#{@zone_map.width} x #{@zone_map.height}",
          image: filename
      end
      log "    Zone map: generated (#{@zone_map.width}x#{@zone_map.height})"
    else
      add_step "Zone Map", content: "Generation failed"
    end
  end

  def step_depth_shapes
    return unless @depth_path && @hex_pixel_map && @zone_map

    log "  Extracting depth shapes via pixel classification..."
    hex_size = @hex_pixel_map[:hex_size]

    zone_map_path = @depth_path.sub(/(\.\w+)$/, '_zone_map.png')
    return unless File.exist?(zone_map_path)

    svc.setup_coord_lookup(@hex_pixel_map) unless svc.coord_lookup&.any?

    # Use SAM2 masks if available (downloaded by step_sam2_experiment)
    sam2_dir = @sam2_masks_dir if @sam2_masks_dir && Dir.exist?(@sam2_masks_dir.to_s)
    result = svc.classify_hexes_with_overlap(
      zone_map_path, hex_size,
      depth_path: @depth_path,
      image_path: sam2_dir ? nil : @processed_image_path,
      sam2_masks_dir: sam2_dir,
      debug_dir: out_dir
    )

    if result
      @pixel_hex_zones = result[:hex_zones]
      @pixel_hex_shapes = result[:hex_shapes] || {}
      @pixel_hex_image_shapes = result[:hex_image_shapes] || {}

      zone_dist = @pixel_hex_zones.values.tally
      shape_count = @pixel_hex_shapes.values.uniq.length
      image_shape_count = @pixel_hex_image_shapes.values.uniq.length

      add_step "Pixel Hex Classification",
        content: "#{@pixel_hex_zones.length} hexes classified (#{zone_dist}), #{shape_count} depth shapes, #{image_shape_count} image shapes",
        image: 'hex_classify_overlay.png'

      if File.exist?(File.join(out_dir, 'depth_shapes.png'))
        add_step "Depth Shapes",
          content: "#{shape_count} contiguous elevated regions from depth map",
          image: 'depth_shapes.png'
      end

      log "    Pixel classification: #{@pixel_hex_zones.length} hexes (#{zone_dist})"
      log "    Depth shapes: #{shape_count} shapes covering #{@pixel_hex_shapes.length} hexes"
    else
      log "    Pixel classification failed, will fall back to center sampling"
    end
  end

  # --- Step: CV Classification (SAM + Depth) ---
  def step_cv_classification
    return unless @processed_image_path && @overview && @hex_coords && @hex_pixel_map

    hex_size = @hex_pixel_map[:hex_size]
    return unless hex_size

    svc.setup_coord_lookup(@hex_pixel_map) unless svc.coord_lookup&.any?
    all_coords = Set.new(@hex_coords)

    # 1. Get type names from overview
    present_types = @overview['present_types'] || []
    type_names = present_types.map { |t| t['type_name'] }
    type_names.delete('open_floor')
    type_names.delete('other')
    type_names.delete('off_map')
    type_names.uniq!

    add_step "CV: Types to Segment",
      data: { 'types' => type_names }
    log "  CV: #{type_names.length} types to segment: #{type_names.join(', ')}"

    # 2. Fire one SAM call per type + depth in parallel
    t0 = Time.now
    threads = {}

    type_names.each do |type_name|
      threads["sam_#{type_name}"] = Thread.new do
        ReplicateSamService.segment(@processed_image_path, type_name, suffix: "_sam_#{type_name}")
      end
    end

    # Use shadowed image for depth if available (shadows help depth models)
    depth_source = @shadowed_image_path || @processed_image_path
    threads[:depth] = Thread.new do
      ReplicateDepthService.estimate(depth_source)
    end

    log "  CV: Waiting for #{threads.length} parallel Replicate calls (#{type_names.length} SAM + 1 depth)..."
    threads.each { |_, t| t.join(120) }
    elapsed = Time.now - t0
    log "  CV: All calls completed in #{elapsed.round(1)}s"

    # 3. Collect per-type SAM masks and render overlays
    sam_type_masks = {}
    cat_colors = {
      structure: [255, 50, 50], furniture: [50, 150, 255],
      terrain: [50, 200, 50], hazards: [255, 165, 0], elevation: [200, 50, 200]
    }
    # Vary hue within category for individual types
    type_hue_shift = 0

    type_names.each do |type_name|
      result = threads["sam_#{type_name}"]&.value
      if result&.dig(:success) && result[:mask_path] && File.exist?(result[:mask_path])
        mask_img = Vips::Image.new_from_file(result[:mask_path])

        # Resize mask to match base image if needed
        if mask_img.width != @base_image.width || mask_img.height != @base_image.height
          mask_img = mask_img.resize(@base_image.width.to_f / mask_img.width,
                                      vscale: @base_image.height.to_f / mask_img.height)
        end

        sam_type_masks[type_name] = mask_img
        fname = "cv_sam_#{type_name}.png"
        save_image(mask_img, fname)

        # Create overlay of mask on base image
        gray = mask_img.bands > 1 ? mask_img.colourspace(:b_w).extract_band(0) : mask_img
        mask_alpha = (gray > 30).ifthenelse(180, 0).cast(:uchar)
        category = svc.type_category(type_name)
        base_rgb_vals = cat_colors[category] || [255, 255, 0]
        # Shift hue slightly per type so overlapping types are distinguishable
        rgb = base_rgb_vals.map { |c| [(c + type_hue_shift * 30) % 256, 255].min }
        type_hue_shift += 1

        # Create highly visible overlay: darken base, highlight mask in bright color
        base_img = @base_image
        base_img = base_img.extract_band(0, n: 3) if base_img.bands > 3
        base_img = base_img.bandjoin([base_img, base_img]) if base_img.bands == 1
        # Resize mask alpha to match base if needed
        alpha_f = (gray > 30).ifthenelse(1.0, 0.0)
        if alpha_f.width != base_img.width || alpha_f.height != base_img.height
          alpha_f = alpha_f.resize(base_img.width.to_f / alpha_f.width,
                                    vscale: base_img.height.to_f / alpha_f.height)
        end
        # Darken non-mask areas to 30%, keep mask areas bright with color tint
        tint = base_img.new_from_image(rgb).cast(:uchar)
        darkened = (base_img * 0.3).cast(:uchar)
        # Mask area: 60% original + 40% bright color
        highlighted = (base_img * 0.6 + tint * 0.4).cast(:uchar)
        composite = alpha_f.ifthenelse(highlighted, darkened)
        overlay_fname = "cv_sam_#{type_name}_overlay.png"
        save_image(composite, overlay_fname)

        coverage = (gray.avg / 255.0 * 100).round(1)
        add_step "CV: SAM Mask (#{type_name})",
          content: "Prompt: \"#{type_name}\" [#{category}]\nMask: #{mask_img.width}x#{mask_img.height}, coverage: #{coverage}%",
          image: overlay_fname
        log "    SAM #{type_name}: mask #{mask_img.width}x#{mask_img.height}, #{coverage}% coverage"
      elsif result&.dig(:no_detections)
        add_step "CV: SAM Mask (#{type_name})",
          content: "No detections (nothing matched \"#{type_name}\")"
        log "    SAM #{type_name}: no detections"
      else
        add_step "CV: SAM Mask (#{type_name})",
          content: "FAILED: #{result&.dig(:error) || 'timeout'}"
        log "    SAM #{type_name}: FAILED (#{result&.dig(:error) || 'timeout'})"
      end
    end

    # 4. Collect depth map
    @cv_depth_map = nil
    depth_result = threads[:depth]&.value
    if depth_result&.dig(:success) && depth_result[:depth_path] && File.exist?(depth_result[:depth_path])
      @cv_depth_map = Vips::Image.new_from_file(depth_result[:depth_path])

      # Resize depth map to match base image if needed
      if @cv_depth_map.width != @base_image.width || @cv_depth_map.height != @base_image.height
        @cv_depth_map = @cv_depth_map.resize(@base_image.width.to_f / @cv_depth_map.width,
                                              vscale: @base_image.height.to_f / @cv_depth_map.height)
      end

      fname = "cv_depth.png"
      save_image(@cv_depth_map, fname)
      add_step "CV: Depth Map",
        content: "#{@cv_depth_map.width}x#{@cv_depth_map.height}",
        image: fname
      log "    Depth: loaded (#{@cv_depth_map.width}x#{@cv_depth_map.height})"
    else
      add_step "CV: Depth Map",
        content: "FAILED: #{depth_result&.dig(:error) || 'timeout'}"
      log "    Depth: FAILED (#{depth_result&.dig(:error) || 'timeout'})"
    end

    # 5. Map per-type masks to hex types
    typed_map = svc.map_type_masks_to_hexes(sam_type_masks, hex_size, all_coords)
    log "  CV: #{typed_map.length} hexes classified from #{sam_type_masks.length} type masks"

    # Render raw SAM classification overlay
    render_typed_map_overlay(typed_map, "cv_sam_raw.png", "CV: Raw SAM Classification")
    add_step "CV: Raw SAM Classification",
      content: "#{typed_map.length} hexes classified from #{sam_type_masks.length} type masks",
      image: "cv_sam_raw.png",
      data: type_dist(typed_map)

    # 6. Assign off_map for unclassified hexes
    all_coords.each do |coord|
      typed_map[coord] = 'off_map' unless typed_map.key?(coord)
    end

    render_typed_map_overlay(typed_map, "cv_sam_with_offmap.png", "CV: With Off-Map")
    add_step "CV: With Off-Map Assignment",
      content: "All #{all_coords.length} hexes now have types",
      image: "cv_sam_with_offmap.png",
      data: type_dist(typed_map)

    # 7. Map depth to elevation
    @cv_elevations = {}
    if @cv_depth_map
      @cv_elevations = svc.map_depth_to_elevation(@cv_depth_map, typed_map, hex_size)
      log "  CV: #{@cv_elevations.length} hexes with elevation from depth map"

      if @cv_elevations.any?
        add_step "CV: Depth-Based Elevation",
          content: "#{@cv_elevations.length} hexes with non-zero elevation",
          data: @cv_elevations.values.tally.sort_by { |k, _| k }.to_h.transform_keys { |k| "#{k}ft" }
      end
    end

    # Store for downstream normalization + type_mapping
    @cv_typed_map = typed_map
    @all_coords = all_coords
  end

  # --- Step: CV Normalization (simplified — passthrough + lockoff only) ---
  def step_cv_normalization
    return unless @cv_typed_map && @all_coords

    hex_size = @hex_pixel_map[:hex_size]
    return unless hex_size

    typed_map = @cv_typed_map
    all_coords = @all_coords
    before_dist = type_dist(typed_map)
    render_typed_map_overlay(typed_map, "cv_norm_00_input.png", "CV Norm Input")
    add_step "CV Norm Input",
      content: "#{typed_map.length} hexes before normalization",
      image: "cv_norm_00_input.png",
      data: before_dist

    # Pass 1: Door/window passthrough
    passthroughs = svc.norm_v3_passthrough(typed_map, all_coords)
    passthroughs.each { |coord, type| typed_map[coord] = type }
    render_typed_map_overlay(typed_map, "cv_norm_01_passthrough.png", "CV Norm: Passthrough")
    add_step "CV Norm: Door/Window Passthrough",
      content: "#{passthroughs.length} hexes converted through wall thickness",
      image: "cv_norm_01_passthrough.png",
      data: type_dist(typed_map)

    # Pass 2: Lockoff detection
    lock_gaps = svc.norm_v3_lockoff_detection(typed_map, all_coords, hex_zones: hex_zones)
    lock_gaps.each { |coord, type| typed_map[coord] = type }
    render_typed_map_overlay(typed_map, "cv_norm_02_lockoff.png", "CV Norm: Lockoff")
    add_step "CV Norm: Lockoff Detection",
      content: "#{lock_gaps.length} gaps punched to connect inaccessible areas",
      image: "cv_norm_02_lockoff.png",
      data: type_dist(typed_map)

    # Assemble final normalized results
    @all_chunk_results = typed_map.map do |(hx, hy), hex_type|
      r = { 'x' => hx, 'y' => hy, 'hex_type' => hex_type }
      r['elevation'] = @cv_elevations[[hx, hy]] if @cv_elevations&.dig([hx, hy])
      r
    end

    @normalized = @all_chunk_results

    add_step "CV Normalization Complete",
      content: "#{@normalized.length} hexes total",
      data: type_dist(typed_map)
  end

  # --- Step: Classification ---
  def step_classification
    return unless @overview && @hex_coords

    present_types = @overview['present_types'] || []
    type_names = present_types.map { |t| t['type_name'] }
    type_names.delete('open_floor')
    type_names.delete('other')
    type_names.delete('off_map')
    type_names.uniq!

    # Filter non-tactical custom types (same logic as production)
    standard_types = AIBattleMapGeneratorService::SIMPLE_HEX_TYPES.to_set
    present_types.reject! do |t|
      name = t['type_name']
      next false if standard_types.include?(name)
      t['traversable'] && !t['provides_cover'] && !t['provides_concealment'] &&
        !t['is_wall'] && !t['is_exit'] && !t['difficult_terrain'] &&
        (t['elevation'] || 0).zero? && (t['hazards'].nil? || t['hazards'].empty?)
    end
    type_names = present_types.map { |t| t['type_name'] }
    type_names.delete('off_map')
    type_names.uniq!

    scene_description = @overview['scene_description'] || ''
    map_layout = @overview['map_layout'] || ''

    chunks = svc.build_spatial_chunks(@hex_coords, AIBattleMapGeneratorService::CHUNK_SIZE)
    model_name = @use_gemini ? 'Gemini' : 'Anthropic'

    log "  Classifying #{chunks.length} chunks via #{model_name} (parallel)..."
    t0 = Time.now
    @all_chunk_results = []
    @chunk_details = Array.new(chunks.length)

    # Prepare all chunk data (image crops, labels, prompts) before parallel LLM calls
    prepared = chunks.each_with_index.filter_map do |chunk_info, idx|
      chunk = chunk_info[:coords]
      grid_pos = chunk_info[:grid_pos]
      visible_chunk = svc.filter_partial_edge_hexes(chunk, @base_image.width, @base_image.height)
      next if visible_chunk.empty?

      seq = svc.build_sequential_labels(visible_chunk)
      hex_list_str = visible_chunk.sort_by { |hx, hy| [hy, hx] }.map { |hx, hy| seq[:labels][[hx, hy]] }.join(', ')

      crop_result = svc.crop_image_for_chunk(@base_image, visible_chunk, @hex_pixel_map, @base_image.width, @base_image.height)
      labeled_crop = svc.overlay_sequential_labels_on_crop(crop_result, visible_chunk, seq[:labels])
      cropped_base64 = Base64.strict_encode64(labeled_crop)

      chunk_tools = svc.build_chunk_tool(type_names)
      prompt = svc.build_grouped_chunk_prompt(hex_list_str, scene_description, type_names,
                                               grid_pos: grid_pos, map_layout: map_layout)

      # Save chunk image
      chunk_img_name = "chunk_#{idx}.png"
      File.write(File.join(out_dir, chunk_img_name), labeled_crop)

      { idx: idx, grid_pos: grid_pos, visible_chunk: visible_chunk, seq: seq,
        base64: cropped_base64, tools: chunk_tools, prompt: prompt, image: chunk_img_name }
    end

    # Parallel LLM calls
    results_mutex = Mutex.new
    run_parallel(prepared) do |prep, _|
      response = llm_classify(prep[:base64], prep[:prompt], prep[:tools])

      detail = {
        idx: prep[:idx], grid_pos: prep[:grid_pos], hex_count: prep[:visible_chunk].length,
        types_available: type_names, image: prep[:image], prompt: prep[:prompt]
      }

      if response[:tool_calls]&.any?
        args = response[:tool_calls].first[:arguments]
        chunk_results = svc.parse_grouped_chunk(args.to_json, prep[:seq][:reverse], allowed_types: type_names)
        results_mutex.synchronize { @all_chunk_results.concat(chunk_results) }
        detail[:raw_response] = args
        detail[:parsed] = chunk_results
        detail[:area_desc] = args['area_description']
        log "    Chunk #{prep[:idx] + 1}/#{chunks.length}: #{chunk_results.length} classified (#{prep[:grid_pos]})"
      else
        detail[:error] = response[:error] || 'no tool call'
        log "    Chunk #{prep[:idx] + 1}/#{chunks.length}: FAILED (#{detail[:error]})"
      end

      @chunk_details[prep[:idx]] = detail
    end

    @chunk_details.compact!
    elapsed = Time.now - t0
    log "  Chunks done in #{elapsed.round(1)}s"

    # Type distribution
    dist = @all_chunk_results.each_with_object(Hash.new(0)) { |r, h| h[r['hex_type']] += 1 }
      .sort_by { |_, v| -v }.to_h

    add_step "Classification Summary",
      content: "#{@all_chunk_results.length} hexes classified from #{chunks.length} chunks",
      data: dist

    # Visualize raw classification
    render_classification_overlay(@all_chunk_results, "06_classify_raw.png", "Raw Classification")
  end

  # --- Step: Grid Classification ---
  def step_grid_classification
    return unless @hex_coords && @base_image
    log "  Running grid classification..."

    # Initialize grid details
    @grid_details = { l1: nil, l2: [], l3: [] }

    # --- Detect small rooms ---
    total_pixels = @base_image.width * @base_image.height
    pixels_per_hex = total_pixels.to_f / @hex_coords.length
    @is_small_room = pixels_per_hex < SMALL_ROOM_THRESHOLD

    l1_grid_n = @is_small_room ? 4 : 3
    log "  Room size: #{total_pixels} pixels, #{@hex_coords.length} hexes, #{pixels_per_hex.round(1)} px/hex → #{@is_small_room ? 'SMALL (4x4 L1)' : 'normal (3x3 L1)'}"

    # --- Level 1: Overview + NxN Grid (discovers types like the overview pass) ---
    log "  [Grid L1] Full image #{l1_grid_n}x#{l1_grid_n} (with thinking)..."
    t0_l1 = Time.now
    l1_result = overlay_square_grid(@base_image, l1_grid_n)
    l1_cells = l1_result[:cells]

    l1_img_name = "grid_l1.png"
    save_image(l1_result[:image], l1_img_name)

    l1_base64 = Base64.strict_encode64(File.binread(File.join(out_dir, l1_img_name)))
    l1_prompt = grid_l1_prompt(l1_grid_n)

    response = LLM::Adapters::GeminiAdapter.generate(
      messages: [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/png', data: l1_base64 },
        { type: 'text', text: l1_prompt }
      ]}],
      model: 'gemini-3.1-pro-preview',
      api_key: AIProviderService.api_key_for('google_gemini'),
      response_schema: grid_l1_schema,
      options: { max_tokens: 32768, timeout: 300, temperature: 0, thinking_level: 'MEDIUM' }
    )

    l1_data = nil
    l1_text = response[:text] || response[:content]
    if l1_text
      l1_data = JSON.parse(l1_text) rescue nil
      if l1_data
        squares = l1_data['squares'] || []
        # standard_types_present is now [{type_name:, visual_description:}, ...]
        @grid_standard_types = l1_data['standard_types_present'] || []
        standard = @grid_standard_types.map { |t| t['type_name'] }
        @grid_custom_types = l1_data['custom_types'] || []
        custom = @grid_custom_types.map { |c| c['type_name'] }
        # Combine standard + custom visual descriptions for passing down
        @grid_type_visuals = {}
        @grid_standard_types.each { |t| @grid_type_visuals[t['type_name']] = t['visual_description'] }
        @grid_custom_types.each { |c| @grid_type_visuals[c['type_name']] = c['visual_description'] }
        @grid_wall_visual = l1_data['wall_visual'] || ''
        @grid_floor_visual = l1_data['floor_visual'] || ''
        @grid_lighting = l1_data['lighting_direction'] || ''
        feature_types = @grid_feature_types = (standard + custom).uniq
        scene_description = l1_data['scene_description'] || ''
        log "    L1: #{squares.length} squares, #{feature_types.length} types (#{(Time.now - t0_l1).round(1)}s)"
        log "    Standard: #{standard.join(', ')}"
        log "    Custom: #{custom.join(', ')}" if custom.any?
        log "    Walls: #{@grid_wall_visual}" if @grid_wall_visual && !@grid_wall_visual.empty?
        log "    Floor: #{@grid_floor_visual}" if @grid_floor_visual && !@grid_floor_visual.empty?
        log "    Lighting: #{@grid_lighting}" if @grid_lighting && !@grid_lighting.empty?
      else
        log "    L1: FAILED - could not parse JSON: #{l1_text&.slice(0, 200)}"
      end
    else
      log "    L1: FAILED - #{response[:error] || 'empty response'}"
    end

    # Fallback if L1 failed
    unless l1_data
      feature_types = @grid_feature_types = []
      scene_description = ''
      squares = []
    end

    # All squares go to L2 (no off_map filtering needed)
    non_empty_l1 = squares || []

    @grid_details[:l1] = { cells: l1_cells, data: l1_data, image: l1_img_name, prompt: l1_prompt }

    add_step "Grid L1: Full Image #{l1_grid_n}x#{l1_grid_n}",
      content: "#{(squares || []).length} squares classified, #{non_empty_l1.length} non-empty\nFeature types: #{feature_types.join(', ')}\nScene: #{scene_description}",
      image: l1_img_name,
      code: JSON.pretty_generate(l1_data || {})

    # --- Pre-fire SAM queries (runs in background while L2/L3 proceed) ---
    @sam_threads = {}
    if @processed_image_path && ReplicateSamService.available?
      sam_window_types = %w[glass_window open_window window]
      sam_water_types = %w[puddle wading_water deep_water water stream river pond fountain pool]
      has_windows = (feature_types & sam_window_types).any?
      has_water = (feature_types & sam_water_types).any?

      if has_windows
        @sam_threads['glass_window'] = Thread.new do
          ReplicateSamService.segment(@processed_image_path, 'window . glass . transparent panel', suffix: '_sam_glass_window')
        end
      end
      if has_water
        @sam_threads['water'] = Thread.new do
          ReplicateSamService.segment(@processed_image_path, 'water . river . stream . pond . pool', suffix: '_sam_water')
        end
      end
      log "    SAM queries started in background: #{@sam_threads.keys.join(', ')}" if @sam_threads.any?
    end

    # --- Level 2 (or skip for small rooms) ---
    if @is_small_room
      # Small rooms: L1 4x4 → L3 directly (skip L2)
      actionable_as_l2 = non_empty_l1.filter_map do |sq|
        l1_cell = l1_cells[sq['square']]
        next unless l1_cell
        {
          l1_square: sq['square'], l1_cell: l1_cell,
          l2_square: 1, l2_cell: l1_cell, data: sq,
          l1_has_walls: !!sq['has_walls'],
          l2_blur_origin_x: 0, l2_blur_origin_y: 0
        }
      end
      actionable = actionable_as_l2.select { |s| s[:data]['has_walls'] || (s[:data]['objects'] || []).any? }
      log "  Small room: #{actionable.length}/#{non_empty_l1.length} L1 cells → L3 directly"
      step_grid_l3(actionable, feature_types)
    else
      step_grid_l2(non_empty_l1, l1_cells, feature_types)
    end
  end

  # --- LLM call helper (supports Gemini and Anthropic) ---
  # For Gemini: uses response_schema for guaranteed JSON output (no tool calling failures).
  # For Anthropic: uses tool calling as before.
  # `tools` is the Anthropic-style tool array; `response_schema` is the Gemini JSON schema.
  def llm_classify(image_base64, prompt, tools, use_gemini: @use_gemini, response_schema: nil)
    if use_gemini
      opts = {
        messages: [{ role: 'user', content: [
          { type: 'image', mime_type: 'image/png', data: image_base64 },
          { type: 'text', text: prompt }
        ]}],
        model: 'gemini-3-flash-preview',
        api_key: AIProviderService.api_key_for('google_gemini'),
        options: { max_tokens: 32768, timeout: 300, temperature: 0 }
      }
      if response_schema
        opts[:response_schema] = response_schema
      elsif tools
        opts[:tools] = tools
      end
      LLM::Adapters::GeminiAdapter.generate(**opts)
    else
      LLM::Adapters::AnthropicAdapter.generate(
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/png', data: image_base64 } },
          { type: 'text', text: prompt }
        ]}],
        model: AIBattleMapGeneratorService::CLASSIFICATION_MODEL,
        api_key: AIProviderService.api_key_for('anthropic'),
        tools: tools,
        options: { max_tokens: 8192, timeout: 300, temperature: 0 }
      )
    end
  end

  # Submit LLM classification calls via Sidekiq batch queue.
  # Each item must respond to [:base64], [:prompt], and will get a schema via the block.
  # Returns array of parsed JSON responses (nil for failures).
  def run_batch_classify(items, &schema_block)
    return [] if items.empty?

    requests = items.map do |item|
      schema = schema_block.call(item)
      messages = [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/png', data: item[:base64] },
        { type: 'text', text: item[:prompt] }
      ]}]

      {
        messages: messages,
        provider: 'google_gemini',
        model: 'gemini-3.1-flash-lite-preview',
        options: { max_tokens: 4096, timeout: 300, temperature: 0, thinking_budget: 0 },
        response_schema: schema,
        context: { index: items.index(item) }
      }
    end

    batch = LLM::Client.batch_submit(requests)
    log "    Submitted #{requests.length} requests via batch queue, waiting..."
    completed = batch.wait!(timeout: 300)
    unless completed
      log "    WARNING: Batch timed out after 300s"
    end

    # Map results back by index (context stored the original index)
    results = Array.new(items.length)
    batch.results.each do |req|
      ctx = req.parsed_context
      idx = ctx['index'] || ctx[:index]
      next unless idx

      if req.completed?
        text = req.response_text
        parsed = text ? (JSON.parse(text) rescue nil) : nil
        results[idx] = { success: true, parsed: parsed, text: text }
      else
        results[idx] = { success: false, error: req.error_message }
      end
    end

    results
  end

  # Legacy thread-based parallel execution for non-LLM tasks
  MAX_CONCURRENT = 120
  SMALL_ROOM_THRESHOLD = 16  # pixels_per_hex below this = small room

  def run_parallel(items, &block)
    return [] if items.empty?
    results = Array.new(items.length)
    queue = SizedQueue.new(MAX_CONCURRENT)
    MAX_CONCURRENT.times { queue.push(:slot) }

    threads = items.each_with_index.map do |item, idx|
      Thread.new do
        queue.pop  # wait for slot
        begin
          results[idx] = block.call(item, idx)
        ensure
          queue.push(:slot)
        end
      end
    end

    threads.each { |t| t.join(300) }
    results
  end

  # --- Grid response schemas (for Gemini structured output) ---
  def grid_l1_schema
    {
      type: 'OBJECT',
      properties: {
        scene_description: { type: 'STRING' },
        wall_visual: { type: 'STRING', description: 'Brief description of what walls look like on this map (color, material, texture)' },
        floor_visual: { type: 'STRING', description: 'Brief description of what the floor looks like (color, material, texture)' },
        lighting_direction: { type: 'STRING', description: 'Direction shadows are cast (e.g. "shadows fall to the southeast") or "no visible shadows"' },
        standard_types_present: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: {
              type_name: { type: 'STRING' },
              visual_description: { type: 'STRING', description: 'What this type looks like on this specific map (color, shape, material)' }
            },
            required: %w[type_name visual_description]
          },
          description: 'Standard types visible on this map, each with a visual description'
        },
        custom_types: {
          type: 'ARRAY',
          description: 'Custom types are ALWAYS traversable. If something blocks movement, use wall instead.',
          items: {
            type: 'OBJECT',
            properties: {
              type_name: { type: 'STRING' },
              visual_description: { type: 'STRING' },
              provides_cover: { type: 'BOOLEAN', description: 'Does this provide cover from ranged attacks?' },
              is_exit: { type: 'BOOLEAN', description: 'Is this a door, gate, or passage?' },
              difficult_terrain: { type: 'BOOLEAN', description: 'Does this slow movement?' },
              elevation: { type: 'INTEGER', description: 'Height in feet above floor (0 for floor-level objects)' },
              hazards: { type: 'ARRAY', items: { type: 'STRING' }, description: 'Hazard types if any: fire, acid, cold, lightning, poison, necrotic, radiant, psychic, thunder, force' }
            },
            required: %w[type_name visual_description provides_cover is_exit difficult_terrain elevation hazards]
          }
        },
        squares: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: {
              square: { type: 'INTEGER' },
              description: { type: 'STRING' },
              has_walls: { type: 'BOOLEAN' },
              wall_description: { type: 'STRING' },
              has_interior_walls: { type: 'BOOLEAN' },
              interior_wall_description: { type: 'STRING' },
              objects: { type: 'ARRAY', items: {
                type: 'OBJECT',
                properties: {
                  type: { type: 'STRING' },
                  count: { type: 'INTEGER' },
                  location: { type: 'STRING' }
                },
                required: %w[type count location]
              }}
            },
            required: %w[square description has_walls wall_description has_interior_walls interior_wall_description objects]
          }
        }
      },
      required: %w[scene_description wall_visual floor_visual lighting_direction standard_types_present custom_types squares]
    }
  end

  def grid_l2_schema(feature_list)
    sub_props = {
      square: { type: 'INTEGER' },
      description: { type: 'STRING' },
      has_walls: { type: 'BOOLEAN' },
      wall_pct: { type: 'INTEGER', description: 'Percentage of subsquare area covered by wall structures (0-100)' },
      floor_pct: { type: 'INTEGER', description: 'Percentage of subsquare area that is open floor (0-100)' }
    }
    sub_required = %w[square description has_walls wall_pct floor_pct]

    if feature_list.any?
      sub_props[:objects] = { type: 'ARRAY', items: {
        type: 'OBJECT',
        properties: {
          type: { type: 'STRING', enum: feature_list },
          count: { type: 'INTEGER' },
          location: { type: 'STRING' },
          coverage_pct: { type: 'INTEGER', description: 'Percentage of subsquare area this object takes up (0-100)' }
        },
        required: %w[type count location coverage_pct]
      }}
      sub_required << 'objects'
    end

    {
      type: 'OBJECT',
      properties: {
        subsquares: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: sub_props,
            required: sub_required
          }
        }
      },
      required: %w[subsquares]
    }
  end

  def grid_l3_schema(feature_list, allow_walls: true)
    props = { area_description: { type: 'STRING' } }
    req = %w[area_description]

    if allow_walls
      props[:walls] = { type: 'ARRAY', items: { type: 'INTEGER' } }
      req << 'walls'
    end

    if feature_list.any?
      feat_props = {
        type: { type: 'STRING', enum: feature_list },
        description: { type: 'STRING' },
        cells: { type: 'ARRAY', items: { type: 'INTEGER' } }
      }
      feat_required = %w[type description cells]

      # Add direction field if staircases or ladders are in the feature list
      if feature_list.any? { |f| %w[staircase ladder].include?(f) }
        feat_props[:ascending_direction] = {
          type: 'STRING',
          enum: %w[north south east west northeast northwest southeast southwest],
          description: 'Direction the staircase/ladder ascends toward (only for staircase/ladder features)'
        }
      end

      props[:features] = {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: feat_props,
          required: feat_required
        }
      }
      req << 'features'
    end
    {
      type: 'OBJECT',
      properties: props,
      required: req
    }
  end

  # --- Grid L1 Tool ---
  def grid_l1_tool(feature_types)
    [{
      name: 'classify_grid',
      description: 'Classify contents of each numbered square in the battle map grid',
      parameters: {
        type: 'object',
        properties: {
          squares: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                square: { type: 'integer', description: 'Square number (1-9)' },
                description: { type: 'string', description: 'What is in this square' },
                has_interior_walls: { type: 'boolean', description: 'Impassable wall structures inside this square' },
                features: {
                  type: 'array', items: { type: 'string', enum: feature_types },
                  description: 'Feature types present in this square'
                }
              },
              required: %w[square description has_interior_walls features]
            }
          }
        },
        required: %w[squares]
      }
    }]
  end

  STANDARD_FEATURE_TYPES = AIBattleMapGeneratorService::SIMPLE_HEX_TYPES.reject { |t|
    %w[wall off_map open_floor other].include?(t)
  }.freeze

  # --- Grid L1 Prompt ---
  def grid_l1_prompt(grid_n = 3)
    total_squares = grid_n * grid_n
    <<~PROMPT
      Analyze this top-down battle map divided into a #{grid_n}x#{grid_n} numbered grid (1-#{total_squares}, left to right, top to bottom).

      STEP 1 — Describe the scene in one sentence (scene_description).

      STEP 2 — Visual descriptions for downstream classification:
      - wall_visual: what walls look like (color, material, texture — e.g. "thick dark grey stone blocks")
      - floor_visual: what the floor looks like (color, material, texture — e.g. "warm brown wooden planks", "grey stone tiles")
      - lighting_direction: which direction shadows are cast (e.g. "shadows fall to the southeast") or "no visible shadows"
      These help distinguish walls from floor and shadows in zoomed-in sections.

      STEP 3 — Identify feature types.

      List which of these STANDARD types are visible on the map (standard_types_present). For each one, include a brief visual_description of what it looks like ON THIS SPECIFIC MAP (color, shape, material — e.g. "dark brown rectangular wooden tables", "small grey metal circles"):
      #{STANDARD_FEATURE_TYPES.join(', ')}

      Pay special attention to:
      - Doors, archways, gates, and any gaps or openings in walls that allow passage. These are small but critically important.
      - Staircases and ladders — note which DIRECTION they go up toward (north, south, east, west, etc.) in the visual_description.
      - Tree trunks (treetrunk) — thick individual tree trunks that block movement.
      - Tree branches/canopy (treebranch) — overhead foliage/canopy that provides cover but is traversable.
      - Shrubbery includes bushes, hedges, low foliage, and undergrowth — things you can hide inside for concealment.
      - Pillars — structural columns that block movement.

      Then, if there are objects that don't match any standard type above, add them as custom_types.
      Custom types are ALWAYS TRAVERSABLE — if something blocks movement entirely, use "wall" instead.
      Custom types need: type_name (snake_case), visual_description, and tactical properties.
      Only create custom types for things that affect the floor tactically.
      Wall-mounted objects (weapon displays, shelves, mounted decorations) are part of the wall — do NOT list them.

      STEP 4 — For each numbered square (ALL #{total_squares}), describe what's in it:
      - has_walls: TRUE if this square contains areas where characters CANNOT stand or walk through. This includes room perimeter walls, structural dividers, thick pillars that are part of the wall structure, and any impassable barrier. Think of "wall" as any part of the map image that is not playable floor or a feature object.
      - wall_description: describe the walls (e.g. "stone walls along north and west edges"). Empty string if none.
      - has_interior_walls: are there partition walls INSIDE the room dividing the space? (not the room perimeter)
      - interior_wall_description: describe interior walls if present. Empty string if none.
      - objects: list each distinct object or cluster with its type, count, and location within the square (e.g. "3 barrels in the northwest corner", "1 table in the center"). For staircases/ladders, include which direction they ascend in the location (e.g. "1 staircase ascending northward in the east").

      Include ALL #{total_squares} squares even if they are just open floor — describe them as such with empty objects list.
    PROMPT
  end

  # --- Grid L2: Per-square 3x3 refinement ---
  def step_grid_l2(non_empty_l1, l1_cells, feature_types)
    log "  [Grid L2] Refining #{non_empty_l1.length} non-empty L1 squares (parallel)..."
    t0 = Time.now

    # Prepare all L2 data: crop with 25% blur buffer, overlay grid, build prompts
    l2_prepared = non_empty_l1.filter_map do |l1_square|
      sq_num = l1_square['square']
      cell = l1_cells[sq_num]
      next unless cell

      blur_result = crop_cell_with_blur(@base_image, cell, blur_pct: 0.25)
      inset = { x: blur_result[:inner_x], y: blur_result[:inner_y],
                w: blur_result[:inner_w], h: blur_result[:inner_h] }
      l2_result = overlay_square_grid(blur_result[:image], 2, inset: inset)
      l2_img_name = "grid_l2_sq#{sq_num}.png"
      save_image(l2_result[:image], l2_img_name)

      l2_base64 = Base64.strict_encode64(File.binread(File.join(out_dir, l2_img_name)))

      # Build per-square feature list for schema enum
      sq_types = (l1_square['objects'] || []).map { |o| o['type'] }.uniq
      prompt = grid_l2_prompt(l1_square, @grid_custom_types || [])

      # Track origin of blurred crop for coordinate mapping
      { sq_num: sq_num, cell: cell, l1_square: l1_square, cells: l2_result[:cells],
        base64: l2_base64, image: l2_img_name, sq_types: sq_types, prompt: prompt,
        l1_has_walls: !!l1_square['has_walls'],
        blur_origin_x: blur_result[:origin_x], blur_origin_y: blur_result[:origin_y] }
    end

    # Batch LLM calls via Sidekiq queue
    all_l2_subsquares = []
    l2_gallery = []
    failed = 0

    batch_results = run_batch_classify(l2_prepared) do |prep|
      grid_l2_schema(prep[:sq_types].uniq)
    end

    l2_prepared.each_with_index do |prep, idx|
      result = batch_results[idx]
      parsed = result&.dig(:parsed) if result&.dig(:success)

      if parsed
        subsquares = parsed['subsquares'] || []
        log "    L2 sq#{prep[:sq_num]}: #{subsquares.length} subsquares"

        subsquares.each do |sub|
          l2_cell = prep[:cells][sub['square']]
          next unless l2_cell
          sub['has_walls'] = false unless prep[:l1_has_walls]
          all_l2_subsquares << {
            l1_square: prep[:sq_num], l1_cell: prep[:cell],
            l2_square: sub['square'], l2_cell: l2_cell, data: sub,
            l1_has_walls: prep[:l1_has_walls],
            l2_blur_origin_x: prep[:blur_origin_x], l2_blur_origin_y: prep[:blur_origin_y]
          }
        end
        l2_gallery << { l1_square: prep[:sq_num], image: prep[:image],
                        l1_data: prep[:l1_square], data: parsed, prompt: prep[:prompt] }
      else
        fail_reason = result&.dig(:error) || 'no response'
        log "    L2 sq#{prep[:sq_num]}: FAILED - #{fail_reason}"
        failed += 1
        l2_gallery << { l1_square: prep[:sq_num], image: prep[:image],
                        l1_data: prep[:l1_square], data: nil, prompt: prep[:prompt] }
      end
    end

    elapsed = Time.now - t0
    log "  L2 done in #{elapsed.round(1)}s (#{l2_prepared.length} squares, #{failed} failed)"

    @grid_details[:l2] = l2_gallery.sort_by { |g| g[:l1_square] }

    add_step "Grid L2: Per-square 2x2 Refinement",
      content: "#{all_l2_subsquares.length} subsquares from #{non_empty_l1.length} L1 squares (#{elapsed.round(1)}s, #{failed} failed)",
      code: JSON.pretty_generate(all_l2_subsquares.map { |s| { l1: s[:l1_square], l2: s[:l2_square], data: s[:data] } })

    # Filter: skip pure floor subsquares (no walls, no objects)
    actionable = all_l2_subsquares.select do |s|
      d = s[:data]
      d['has_walls'] || (d['objects'] || []).any?
    end
    skipped = all_l2_subsquares.length - actionable.length
    log "  #{actionable.length} need LLM, #{skipped} pure floor skipped"

    step_grid_l3(actionable, feature_types)
  end

  # --- Grid L2 Tool ---
  def grid_l2_tool(feature_types)
    [{
      name: 'classify_subsquares',
      description: 'Sort features into subsquares',
      parameters: {
        type: 'object',
        properties: {
          subsquares: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                square: { type: 'integer', description: 'Subsquare number (1-4)' },
                description: { type: 'string', description: 'What is in this subsquare' },
                walls: { type: 'boolean', description: 'Interior wall structures present' },
                features: {
                  type: 'array', items: { type: 'string', enum: feature_types },
                  description: 'Feature types in this subsquare'
                }
              },
              required: %w[square description walls features]
            }
          }
        },
        required: %w[subsquares]
      }
    }]
  end

  # --- Grid L2 Prompt ---
  def grid_l2_prompt(l1_square, custom_types = [])
    # Build context from what L1 identified in THIS square
    context = ["This section contains: #{l1_square['description']}"]

    wall_visual = @grid_wall_visual || ''
    if l1_square['has_walls']
      desc = l1_square['wall_description']
      wall_info = desc && !desc.empty? ? desc : 'present along edges'
      wall_info += " (#{wall_visual})" if !wall_visual.empty?
      context << "Walls: #{wall_info}"
    else
      context << "No walls in this section."
    end

    if l1_square['has_interior_walls']
      desc = l1_square['interior_wall_description']
      context << "Interior partition walls: #{desc && !desc.empty? ? desc : 'present'}"
    end

    objects = l1_square['objects'] || []
    if objects.any?
      obj_list = objects.map { |o| "#{o['count']} #{o['type']}#{o['count'] > 1 ? 's' : ''} (#{o['location']})" }.join(', ')
      context << "Objects: #{obj_list}"
    end

    # Only list the feature types that L1 said are in this square
    square_types = objects.map { |o| o['type'] }.uniq

    # Include visual descriptions for all types in this square (standard + custom)
    type_visuals = (@grid_type_visuals || {}).select { |k, _| square_types.include?(k) }
    if type_visuals.any?
      type_info = type_visuals.map { |name, desc| "- #{name}: #{desc}" }.join("\n")
      context << "What each type looks like:\n#{type_info}"
    end

    <<~PROMPT
      This section of a battle map is divided into a 2x2 numbered grid (1-4, left to right, top to bottom):

       1 | 2
      -------
       3 | 4

      #{context.join("\n")}

      For ALL 4 subsquares, describe what is in each one:
      - has_walls: TRUE if any part of this subsquare is an area where characters CANNOT stand or walk through — room perimeter walls, structural barriers, thick impassable borders. "Wall" means any non-playable, impassable part of the map image.#{l1_square['has_walls'] ? '' : ' The parent section has NO walls, so has_walls should be false for all subsquares.'}
      - wall_pct: percentage of the subsquare covered by wall/impassable structures (0 if no walls)
      - floor_pct: percentage of the subsquare that is open walkable floor (100 if empty)
      - objects: list each distinct object or cluster with type, count, location, and coverage_pct (how much of the subsquare it takes up, 0-100). For staircases/ladders, include which direction they ascend (e.g. "ascending northward").
      #{square_types.any? ? "\nObject types to place: #{square_types.join(', ')}. ONLY use these types — do not invent new ones." : "\nNo objects in this section — all subsquares should have empty objects lists."}

      Include ALL 4 subsquares. Subsquares that are just open floor should have empty objects, has_walls false, wall_pct 0, floor_pct 100.
      When in doubt, leave has_walls as false — it is better to under-classify than over-classify.
    PROMPT
  end

  # --- Grid L3: Per-subsquare numbered grid ---
  def step_grid_l3(actionable_subsquares, feature_types)
    log "  [Grid L3] Classifying #{actionable_subsquares.length} actionable subsquares (parallel)..."
    t0 = Time.now

    # Prepare all L3 data: crop with blur buffer, overlay grid, build per-subsquare prompts
    l3_prepared = actionable_subsquares.filter_map do |sub|
      l1_sq = sub[:l1_square]
      l2_sq = sub[:l2_square]
      l2_cell = sub[:l2_cell]
      l2_data = sub[:data]

      # L2 cell coordinates are relative to the L2 blurred crop image.
      # Use the blur origin to convert back to full-image coordinates.
      l2_origin_x = sub[:l2_blur_origin_x]
      l2_origin_y = sub[:l2_blur_origin_y]
      abs_x = l2_origin_x + l2_cell[:x]
      abs_y = l2_origin_y + l2_cell[:y]
      abs_w = l2_cell[:w]
      abs_h = l2_cell[:h]

      # Grid size based on pixel dimensions, not hex positions.
      # Target ~hex_diameter per cell so each cell is roughly one hex.
      hex_size = @hex_pixel_map[:hex_size]
      cells_across = (abs_w / (hex_size * 1.5)).ceil
      cells_down = (abs_h / (hex_size * 1.5)).ceil
      grid_n = [[([cells_across, cells_down].max), 2].max, 5].min

      # Crop with 25% blur buffer for context
      cell_info = { x: abs_x, y: abs_y, w: abs_w, h: abs_h }
      blur_result = crop_cell_with_blur(@base_image, cell_info, blur_pct: 0.25)
      inset = { x: blur_result[:inner_x], y: blur_result[:inner_y],
                w: blur_result[:inner_w], h: blur_result[:inner_h] }
      l3_result = overlay_square_grid(blur_result[:image], grid_n, inset: inset)
      l3_img_name = "grid_l3_#{l1_sq}_#{l2_sq}.png"
      save_image(l3_result[:image], l3_img_name)

      l3_base64 = Base64.strict_encode64(File.binread(File.join(out_dir, l3_img_name)))

      # Feature types for this specific subsquare
      sub_types = (l2_data['objects'] || []).map { |o| o['type'] }.uniq
      # Walls allowed only if L2 says this subsquare has walls
      allow_walls = !!l2_data['has_walls']
      prompt = grid_l3_prompt(l2_data, @grid_custom_types || [], allow_walls: allow_walls)

      # Track the L3 blur origin for hex mapping
      { l1_sq: l1_sq, l2_sq: l2_sq,
        blur_origin_x: blur_result[:origin_x], blur_origin_y: blur_result[:origin_y],
        abs_w: abs_w, abs_h: abs_h,
        grid_n: grid_n, cells: l3_result[:cells],
        base64: l3_base64, image: l3_img_name, sub_types: sub_types,
        prompt: prompt, l2_data: l2_data, allow_walls: allow_walls }
    end

    # Batch LLM calls via Sidekiq queue
    @grid_cell_results = []
    l3_gallery = []
    failed = 0

    batch_results = run_batch_classify(l3_prepared) do |prep|
      grid_l3_schema(prep[:sub_types].uniq, allow_walls: prep[:allow_walls])
    end

    l3_prepared.each_with_index do |prep, idx|
      result = batch_results[idx]
      parsed = result&.dig(:parsed) if result&.dig(:success)

      if parsed
        # Cap walls using L2's wall_pct estimate (with 50% margin)
        walls = parsed['walls'] || []
        wall_pct = prep[:l2_data]['wall_pct'] || 0
        total_cells = prep[:grid_n] ** 2
        max_wall_cells = ((wall_pct / 100.0) * total_cells * 1.5).ceil
        max_wall_cells = [max_wall_cells, 1].max if wall_pct > 0
        if walls.length > max_wall_cells && max_wall_cells < walls.length
          grid_n = prep[:grid_n]
          walls_with_edge_dist = walls.map do |c|
            row = (c - 1) / grid_n
            col = (c - 1) % grid_n
            edge_dist = [row, col, grid_n - 1 - row, grid_n - 1 - col].min
            [c, edge_dist]
          end
          walls_with_edge_dist.sort_by! { |_, d| d }
          parsed['walls'] = walls_with_edge_dist.first(max_wall_cells).map(&:first)
          log "    L3 #{prep[:l1_sq]}_#{prep[:l2_sq]}: wall cap #{walls.length}->#{parsed['walls'].length} (wall_pct=#{wall_pct}, max=#{max_wall_cells})"
        end

        log "    L3 #{prep[:l1_sq]}_#{prep[:l2_sq]}: #{prep[:grid_n]}x#{prep[:grid_n]} grid — walls:#{(parsed['walls'] || []).length} features:#{(parsed['features'] || []).length}"

        @grid_cell_results << {
          blur_origin_x: prep[:blur_origin_x], blur_origin_y: prep[:blur_origin_y],
          abs_w: prep[:abs_w], abs_h: prep[:abs_h],
          grid_n: prep[:grid_n], cells: prep[:cells], data: parsed
        }
        l3_gallery << { l1_square: prep[:l1_sq], l2_square: prep[:l2_sq], grid_n: prep[:grid_n],
                        image: prep[:image], data: parsed, prompt: prep[:prompt] }
      else
        fail_reason = result&.dig(:error) || 'no response'
        log "    L3 #{prep[:l1_sq]}_#{prep[:l2_sq]}: FAILED - #{fail_reason}"
        failed += 1
        l3_gallery << { l1_square: prep[:l1_sq], l2_square: prep[:l2_sq], grid_n: prep[:grid_n],
                        image: prep[:image], data: nil, prompt: prep[:prompt] }
      end
    end

    elapsed = Time.now - t0
    log "  L3 done in #{elapsed.round(1)}s (#{l3_prepared.length} subsquares, #{failed} failed)"

    @grid_details[:l3] = l3_gallery.sort_by { |g| [g[:l1_square], g[:l2_square]] }

    add_step "Grid L3: Per-subsquare Classification",
      content: "#{@grid_cell_results.length} subsquares classified (#{elapsed.round(1)}s, #{failed} failed)",
      code: JSON.pretty_generate(@grid_cell_results.map { |r| { origin_x: r[:blur_origin_x], origin_y: r[:blur_origin_y], grid_n: r[:grid_n], data: r[:data] } })

    step_grid_map_to_hexes
  end

  # --- Grid L3 Tool ---
  def grid_l3_tool(feature_types)
    [{
      name: 'classify_cells',
      description: 'Assign grid cell numbers to walls and features',
      parameters: {
        type: 'object',
        properties: {
          area_description: { type: 'string', description: 'Brief description of this area' },
          walls: {
            type: 'array', items: { type: 'integer' },
            description: 'Grid cell numbers that are impassable wall structures'
          },
          features: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                type: { type: 'string', enum: feature_types },
                cells: { type: 'array', items: { type: 'integer' } }
              },
              required: %w[type cells]
            }
          }
        },
        required: %w[area_description walls features]
      }
    }]
  end

  # --- Grid L3 Prompt ---
  def grid_l3_prompt(l2_data, custom_types = [], allow_walls: true)
    tasks = []
    wall_visual = @grid_wall_visual || ''
    if allow_walls && l2_data['has_walls']
      wall_pct = l2_data['wall_pct'] || 0
      wall_look = wall_visual.empty? ? '' : " (#{wall_visual})"
      tasks << "Mark which cells are wall#{wall_look}#{wall_pct > 0 ? " — walls cover ~#{wall_pct}% of this area" : ''}"
    end

    objects = l2_data['objects'] || []
    objects.each do |obj|
      count = obj['count'] || 1
      coverage = obj['coverage_pct']
      size_hint = coverage ? " (~#{coverage}% of area)" : ''
      # Include visual description if available
      visual = (@grid_type_visuals || {})[obj['type']]
      look = visual ? " — looks like: #{visual}" : ''
      tasks << "Place #{count} #{obj['type']}#{count > 1 ? 's' : ''} (#{obj['location']})#{size_hint}#{look}"
    end

    if tasks.empty?
      tasks << "This area is open floor — no walls or features to mark"
    end

    floor_pct = l2_data['floor_pct']
    floor_hint = floor_pct ? "\nThis area is ~#{floor_pct}% open floor. Most cells should be left unassigned (floor)." : ''

    floor_visual = @grid_floor_visual || ''
    lighting = @grid_lighting || ''

    <<~PROMPT
      This small section of a battle map has a numbered grid overlay.

      Tasks — assign grid cell numbers for each:
      #{tasks.map { |t| "• #{t}" }.join("\n")}
      #{floor_hint}
      Rules:
      - #{allow_walls ? "\"walls\" = areas where characters CANNOT stand on or walk through — room perimeter walls, structural barriers, impassable borders. Walls are typically 1 cell thick. Only mark cells whose CENTER is on the actual wall structure, not floor next to a wall.#{wall_visual.empty? ? '' : " Walls look like: #{wall_visual}."}" : 'No walls exist in this area — do not classify any cells as wall.'}
      - "features" = objects on the floor. Mark cells where the object physically sits.
      - Cells not in any list are open floor — when in doubt, leave a cell as floor.#{floor_visual.empty? ? '' : "\n      - The floor looks like: #{floor_visual}. Do NOT confuse floor texture with walls."}
      - Dark areas next to walls or objects are SHADOWS, not walls or features. Shadows are floor.#{lighting.empty? ? '' : " #{lighting}."}
      - For staircases/ladders: note the direction they ascend in the feature description.
    PROMPT
  end

  # --- Grid: Map to Hexes (placeholder) ---
  def step_grid_map_to_hexes
    return if @grid_cell_results.nil? || @grid_cell_results.empty?

    log "  [Grid] Mapping grid cells to hexes..."

    # Build list of hex positions for nearest-neighbor lookup
    hex_positions = svc.coord_lookup.filter_map do |(hx, hy), info|
      next unless info.is_a?(Hash) && info[:px]
      [hx, hy, info[:px], info[:py]]
    end

    # Debug: show coordinate ranges
    hpx = hex_positions.map { |_, _, px, _| px }
    hpy = hex_positions.map { |_, _, _, py| py }
    log "    Hex px range: #{hpx.min}..#{hpx.max}, py range: #{hpy.min}..#{hpy.max} (#{hex_positions.length} hexes)"
    log "    Image: #{@base_image.width}x#{@base_image.height}" if @base_image

    all_centers = []
    @grid_cell_results.each do |result|
      ox = result[:blur_origin_x]; oy = result[:blur_origin_y]
      result[:cells]&.each do |num, cell|
        all_centers << [ox + cell[:cx], oy + cell[:cy]]
      end
    end
    if all_centers.any?
      cxs = all_centers.map(&:first)
      cys = all_centers.map(&:last)
      log "    Cell center px range: #{cxs.min}..#{cxs.max}, py range: #{cys.min}..#{cys.max} (#{all_centers.length} cells)"
    end

    # For each hex, compute overlap area with each classified grid cell.
    # The type with the most combined coverage wins (must cover ≥50% of hex area).
    hex_coverage_threshold = 0.50
    hex_size = @hex_pixel_map[:hex_size]
    # Flat-top hex area = (3 * sqrt(3) / 2) * size^2
    hex_area = (3.0 * Math.sqrt(3) / 2.0) * hex_size * hex_size

    # Build a flat list of classified cell rectangles with types
    classified_rects = []
    @grid_cell_results.each do |result|
      origin_x = result[:blur_origin_x]
      origin_y = result[:blur_origin_y]
      cells = result[:cells]
      data = result[:data]
      next unless data && cells

      cell_types = {}
      (data['walls'] || []).each { |c| cell_types[c] = { type: 'wall' } }
      (data['features'] || []).each do |feat|
        meta = { type: feat['type'] }
        meta[:ascending_direction] = feat['ascending_direction'] if feat['ascending_direction']
        (feat['cells'] || []).each { |c| cell_types[c] = meta }
      end

      cell_types.each do |cell_num, meta|
        cell = cells[cell_num]
        next unless cell
        rect = {
          x: origin_x + cell[:x], y: origin_y + cell[:y],
          w: cell[:w], h: cell[:h], type: meta[:type]
        }
        rect[:ascending_direction] = meta[:ascending_direction] if meta[:ascending_direction]
        classified_rects << rect
      end
    end

    # For each hex, find overlapping rects and compute intersection area
    hex_assignments = {}
    hex_positions.each do |hx, hy, px, py|
      hex_poly = hexagon_points_array(px, py, hex_size)
      type_areas = Hash.new(0.0)
      type_meta = {}

      classified_rects.each do |rect|
        # Quick bounding box check
        next if px + hex_size < rect[:x] || px - hex_size > rect[:x] + rect[:w]
        next if py + hex_size < rect[:y] || py - hex_size > rect[:y] + rect[:h]

        rect_poly = [
          [rect[:x], rect[:y]], [rect[:x] + rect[:w], rect[:y]],
          [rect[:x] + rect[:w], rect[:y] + rect[:h]], [rect[:x], rect[:y] + rect[:h]]
        ]
        area = polygon_intersection_area(hex_poly, rect_poly)
        if area > 0
          type_areas[rect[:type]] += area
          # Keep metadata from the rect with most area for this type
          if !type_meta[rect[:type]] || area > (type_meta[rect[:type]][:best_area] || 0)
            type_meta[rect[:type]] = { best_area: area, ascending_direction: rect[:ascending_direction] }
          end
        end
      end

      next if type_areas.empty?
      best_type, best_area = type_areas.max_by { |_, a| a }
      coverage = best_area / hex_area
      # Winning type must cover ≥50% of hex area, otherwise hex stays unclassified (floor)
      if coverage >= hex_coverage_threshold
        assignment = { type: best_type, distance: 0 }
        if type_meta[best_type]&.dig(:ascending_direction)
          assignment[:ascending_direction] = type_meta[best_type][:ascending_direction]
        end
        hex_assignments[[hx, hy]] = assignment
      end
    end

    # Convert to standard chunk_results format
    @grid_chunk_results = hex_assignments.map do |(hx, hy), info|
      result = { 'x' => hx, 'y' => hy, 'hex_type' => info[:type] }
      result['ascending_direction'] = info[:ascending_direction] if info[:ascending_direction]
      result
    end

    dist = @grid_chunk_results.each_with_object(Hash.new(0)) { |r, h| h[r['hex_type']] += 1 }
      .sort_by { |_, v| -v }.to_h

    add_step "Grid Classification: Hex Mapping",
      content: "#{hex_assignments.length} hexes classified via grid method",
      data: dist

    # Use grid results for normalization if chunk classification wasn't run
    @all_chunk_results ||= @grid_chunk_results

    # Render overlays
    render_classification_overlay(@grid_chunk_results, "09_grid_classify_raw.png", "Grid Classification (Raw)")
    render_grid_cell_overlay
  end

  # --- Step: Grid Cell Overlay ---
  # Shows the actual L3 grid cells as colored rectangles on the full map,
  # before hex snapping. Useful for seeing exactly what the LLM classified.
  def render_grid_cell_overlay
    return unless @base_image && @grid_cell_results&.any?

    svg_elements = []

    @grid_cell_results.each do |result|
      origin_x = result[:blur_origin_x]
      origin_y = result[:blur_origin_y]
      cells = result[:cells]
      data = result[:data]
      next unless data && cells

      # Build cell_num -> type mapping
      cell_types = {}
      (data['walls'] || []).each { |c| cell_types[c] = 'wall' }
      (data['features'] || []).each do |feat|
        (feat['cells'] || []).each { |c| cell_types[c] = feat['type'] }
      end

      cell_types.each do |cell_num, hex_type|
        cell = cells[cell_num]
        next unless cell

        # Cell position in full-image coordinates
        rx = origin_x + cell[:x]
        ry = origin_y + cell[:y]
        rw = cell[:w]
        rh = cell[:h]

        color = VIS_COLORS[hex_type] || [255, 0, 255]
        abbrev = hex_type[0..2]
        cx = rx + rw / 2.0
        cy = ry + rh / 2.0
        font_size = [[rw, rh].min * 0.35, 7].max.round

        svg_elements << "<rect x='#{rx}' y='#{ry}' width='#{rw}' height='#{rh}' " \
          "fill='rgba(#{color[0]},#{color[1]},#{color[2]},0.45)' " \
          "stroke='rgba(#{color[0]},#{color[1]},#{color[2]},0.9)' stroke-width='1'/>"
        svg_elements << "<text x='#{cx.round}' y='#{(cy + font_size * 0.35).round}' " \
          "text-anchor='middle' fill='white' font-size='#{font_size}' " \
          "font-family='monospace' stroke='black' stroke-width='2' paint-order='stroke'>#{abbrev}</text>"
      end
    end

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{@base_image.width}" height="#{@base_image.height}">
        #{svg_elements.join("\n")}
      </svg>
    SVG

    overlay = Vips::Image.svgload_buffer(svg)
    if overlay.width != @base_image.width
      overlay = overlay.resize(@base_image.width.to_f / overlay.width,
                                vscale: @base_image.height.to_f / overlay.height)
    end

    base_rgba = @base_image.bands >= 4 ? @base_image : @base_image.bandjoin(255)
    overlay_rgba = overlay.bands >= 4 ? overlay : overlay.bandjoin(255)
    composite = base_rgba.composite(overlay_rgba, :over)

    save_image(composite, "09b_grid_cells_overlay.png")
    add_step "Grid Cell Classification (Pre-Hex)", image: "09b_grid_cells_overlay.png"
  end

  # --- Step: Normalization ---
  def step_normalization
    # Prefer grid classification results — they're newer and more spatially precise.
    # Fall back to chunk classification if grid didn't run.
    norm_results = @grid_chunk_results || @all_chunk_results
    return unless norm_results && @hex_coords

    hex_size = @hex_pixel_map[:hex_size]
    return unless hex_size

    # Ensure coord_lookup is set
    svc.setup_coord_lookup(@hex_pixel_map) unless svc.coord_lookup&.any?

    # Build typed_map from chunk results
    typed_map = {}
    ascending_directions = {}
    norm_results.each do |r|
      next unless r['x'] && r['y']
      typed_map[[r['x'], r['y']]] = r['hex_type']
      ascending_directions[[r['x'], r['y']]] = r['ascending_direction'] if r['ascending_direction']
    end
    all_coords = Set.new(@hex_coords)

    # Pre-compute zone map from depth + edges
    hex_zones = {}
    hex_shapes = {}
    hex_depths = {}
    hex_image_shapes = {}
    if @pixel_hex_zones
      hex_zones = @pixel_hex_zones
      hex_shapes = @pixel_hex_shapes || {}
      hex_image_shapes = @pixel_hex_image_shapes || {}
      zone_dist = hex_zones.values.tally
      puts "  Pixel classification: #{hex_zones.length} hexes (#{zone_dist}), #{hex_shapes.values.uniq.length} depth shapes, #{hex_image_shapes.values.uniq.length} image shapes"
    elsif @zone_map
      hex_zones = svc.build_hex_zone_map(@zone_map, hex_size)
      zone_dist = hex_zones.values.tally
      puts "  Zone map sampled (fallback): #{hex_zones.length} hexes (#{zone_dist})"
    end
    if @depth_map
      hex_depths = svc.build_hex_depth_map(@depth_map, hex_size)
      puts "  Depth map sampled: #{hex_depths.length} hexes"
    end

    # Pre-compute color features for terrain pass
    rgb = @base_image.bands > 3 ? @base_image.extract_band(0, n: 3) : @base_image
    lab_image = rgb.colourspace(:lab)
    color_features = {}
    svc.coord_lookup&.each do |(hx, hy), info|
      color_features[[hx, hy]] = svc.extract_hex_features(lab_image, info[:px], info[:py], hex_size)
    end

    # Build type_properties from overview or grid L1 custom types
    type_properties = {}
    if @overview
      (@overview['present_types'] || []).each do |t|
        props = {}
        %w[traversable provides_cover provides_concealment is_wall is_exit difficult_terrain].each do |key|
          props[key] = t[key] unless t[key].nil?
        end
        props['elevation'] = t['elevation'] unless t['elevation'].nil?
        type_properties[t['type_name']] = props
      end
    end
    if @grid_custom_types
      @grid_custom_types.each do |ct|
        next if type_properties.key?(ct['type_name'])
        props = { 'traversable' => true }
        %w[provides_cover is_exit difficult_terrain].each do |key|
          props[key] = ct[key] unless ct[key].nil?
        end
        props['elevation'] = ct['elevation'] if ct['elevation'] && ct['elevation'] != 0
        type_properties[ct['type_name']] = props
      end
    end

    before_count = typed_map.length
    pass_num = 0

    # Render initial state
    render_typed_map_overlay(typed_map, "07_norm_00_input.png", "Normalization Input")
    add_step "Norm Input",
      content: "#{typed_map.length} classified hexes before normalization",
      image: "07_norm_00_input.png",
      data: type_dist(typed_map)

    # --- Pass 1: Off-map flood ---
    pass_num += 1
    off_map_fills = svc.norm_v3_off_map_flood(typed_map, all_coords, image: @base_image, hex_size: hex_size, hex_zones: hex_zones)
    off_map_fills.each { |coord| typed_map[coord] = 'off_map' }
    render_typed_map_overlay(typed_map, "07_norm_01_offmap.png", "Pass 1: Off-Map Flood")
    add_step "Pass 1: Off-Map Flood",
      content: "#{off_map_fills.length} hexes marked off_map",
      image: "07_norm_01_offmap.png",
      data: type_dist(typed_map)

    # --- Pass 2: Zone validation ---
    pass_num += 1
    zv = svc.norm_v3_zone_validation(typed_map, hex_zones: hex_zones, type_properties: type_properties)
    zv[:demotions].each { |coord| typed_map.delete(coord) }
    zv[:overrides].each { |coord, type| typed_map[coord] = type }
    # Debug: check bottom wall zone hexes
    max_y = all_coords.map(&:last).max
    bottom_hexes = hex_zones.select { |(_, hy), _| hy >= max_y - 4 }
    bottom_wall_hexes = bottom_hexes.select { |_, z| z == 1 }
    bottom_wall_overrides = zv[:overrides].select { |(_, hy), _| hy >= max_y - 4 }
    log "    Zone validation: #{zv[:demotions].length} demoted, #{zv[:overrides].length} overridden"
    log "    Bottom hexes (y>=#{max_y-4}): #{bottom_hexes.length} sampled, #{bottom_wall_hexes.length} in wall zone, #{bottom_wall_overrides.length} overridden to wall"
    render_typed_map_overlay(typed_map, "07_norm_02_clearing.png", "Pass 2: Zone Validation")
    add_step "Pass 2: Zone Validation",
      content: "#{zv[:demotions].length} hexes demoted, #{zv[:overrides].length} hexes overridden (bottom: #{bottom_wall_hexes.length} wall zone, #{bottom_wall_overrides.length} overridden)",
      image: "07_norm_02_clearing.png",
      data: type_dist(typed_map)

    # --- Pass 2.5: Border wall guarantee ---
    unless @room.outdoor_room?
      border_walls = svc.norm_v3_border_walls(typed_map, all_coords)
      border_walls.each { |coord, type| typed_map[coord] = type }
      render_typed_map_overlay(typed_map, "07_norm_02b_borderwalls.png", "Pass 2.5: Border Walls")
      add_step "Pass 2.5: Border Walls",
        content: "#{border_walls.length} border hexes enforced as wall",
        image: "07_norm_02b_borderwalls.png",
        data: type_dist(typed_map)
    end

    # --- Pass 3: Shape snapping ---
    pass_num += 1
    snap = svc.norm_v3_shape_snap(typed_map, all_coords, hex_zones: hex_zones, hex_shapes: hex_shapes)
    snap[:additions].each { |coord, type| typed_map[coord] = type }
    snap[:trims].each { |coord, type| typed_map[coord] = type }
    render_typed_map_overlay(typed_map, "07_norm_03_shapesnap.png", "Pass 3: Shape Snap")
    add_step "Pass 3: Shape Snap",
      content: "#{snap[:additions].length} hexes added to shapes, #{snap[:trims].length} trimmed beyond shapes",
      image: "07_norm_03_shapesnap.png",
      data: type_dist(typed_map)

    # --- Pass 3b: Flat shape snap ---
    pass_num += 1
    flat_snap = svc.norm_v3_flat_shape_snap(typed_map, all_coords,
                                            hex_image_shapes: hex_image_shapes,
                                            hex_zones: hex_zones)
    flat_snap[:additions].each { |coord, type| typed_map[coord] = type }
    if flat_snap[:additions].any?
      render_typed_map_overlay(typed_map, "07_norm_03b_flatsnap.png", "Pass 3b: Flat Shape Snap")
      add_step "Pass 3b: Flat Shape Snap",
        content: "#{flat_snap[:additions].length} floor hexes snapped to flat types",
        image: "07_norm_03b_flatsnap.png",
        data: type_dist(typed_map)
    end

    # --- Pass 4: Wall flood ---
    pass_num += 1
    wall_ext = svc.norm_v3_wall_flood(typed_map, all_coords, hex_zones: hex_zones)
    wall_ext.each { |coord, type| typed_map[coord] = type }
    render_typed_map_overlay(typed_map, "07_norm_04_wallflood.png", "Pass 4: Wall Flood")
    add_step "Pass 4: Wall Flood",
      content: "#{wall_ext.length} hexes extended as walls",
      image: "07_norm_04_wallflood.png",
      data: type_dist(typed_map)

    # --- Pass 5: Elevation fix ---
    pass_num += 1
    elevations = svc.norm_v3_elevation_fix(typed_map, all_coords, ascending_directions, hex_depths: hex_depths, hex_zones: hex_zones)
    render_typed_map_overlay(typed_map, "07_norm_05_elevation.png", "Pass 5: Elevation Fix")
    add_step "Pass 5: Elevation Fix",
      content: "#{elevations.length} hexes with elevation assigned",
      image: "07_norm_05_elevation.png",
      data: type_dist(typed_map)

    # --- Pass 6: Elevated objects ---
    pass_num += 1
    elev_updates = svc.norm_v3_elevated_objects(typed_map, elevations)
    elevations.merge!(elev_updates)
    render_typed_map_overlay(typed_map, "07_norm_06_elevated.png", "Pass 6: Elevated Objects")
    add_step "Pass 6: Elevated Objects",
      content: "#{elev_updates.length} objects with stacked elevation",
      image: "07_norm_06_elevated.png",
      data: type_dist(typed_map)

    # --- Pass 7: Terrain color pass (removed — no longer used) ---
    pass_num += 1
    puts "  Pass 7: Terrain color pass skipped (removed from pipeline)"
    add_step "Pass 7: Terrain Color (skipped)",
      content: "Terrain color pass removed from pipeline"

    # --- Pass 7.5: SAM authoritative features (windows, water) ---
    # Use pre-fetched SAM threads from L1 if available (started during grid classification)
    overview_type_names = (@overview&.dig('present_types') || []).map { |t| t['type_name'] }
    all_type_names = overview_type_names | (@grid_feature_types || [])
    if @processed_image_path && ReplicateSamService.available?
      sam_detections = svc.norm_v3_sam_features(typed_map, all_coords,
                                                hex_zones: hex_zones, image_path: @processed_image_path,
                                                hex_size: hex_size, present_type_names: all_type_names,
                                                prefetched_sam_threads: @sam_threads || {})
      sam_detections.each { |coord, type| typed_map[coord] = type }
      render_typed_map_overlay(typed_map, "07_norm_07b_sam.png", "Pass 7.5: SAM Features")
      add_step "Pass 7.5: SAM Features",
        content: "#{sam_detections.length} hexes detected (windows in walls, water features)",
        image: "07_norm_07b_sam.png",
        data: type_dist(typed_map)

      # --- SAM mask overlay visualization ---
      ext = File.extname(@processed_image_path)
      sam_mask_defs = {
        'window' => { suffix: '_sam_glass_window', color: [60, 120, 255] },   # blue
        'water'  => { suffix: '_sam_water', color: [255, 180, 60] }            # orange
      }
      base_img = @base_image.extract_band(0, n: [3, @base_image.bands].min)
      base_img = base_img.bandjoin([base_img, base_img]) if base_img.bands == 1
      composite_overlay = (base_img * 0.5).cast(:uchar) # start with darkened base
      mask_details = []

      sam_mask_defs.each do |label, mdef|
        mask_path = @processed_image_path.sub(/#{Regexp.escape(ext)}$/, "#{mdef[:suffix]}.png")
        next unless File.exist?(mask_path)

        mask = Vips::Image.new_from_file(mask_path)
        mask = mask.extract_band(0) if mask.bands > 1
        # Resize mask to match base image if needed
        if mask.width != base_img.width || mask.height != base_img.height
          mask = mask.resize(base_img.width.to_f / mask.width,
                             vscale: base_img.height.to_f / mask.height)
        end

        coverage = (mask.avg / 255.0 * 100).round(1)
        mask_details << "#{label}: #{coverage}% coverage"

        # Build tinted overlay: where mask > threshold, blend color at 40% over base
        alpha_f = (mask > 30).ifthenelse(1.0, 0.0)
        tint = base_img.new_from_image(mdef[:color]).cast(:uchar)
        highlighted = (base_img * 0.6 + tint * 0.4).cast(:uchar)
        composite_overlay = alpha_f.ifthenelse(highlighted, composite_overlay)
      end

      if mask_details.any?
        save_image(composite_overlay, "07_norm_07b_sam_masks.png")
        add_step "Pass 7.5b: SAM Raw Masks",
          content: "Raw SAM detection masks overlaid on base image\n#{mask_details.join(', ')}",
          image: "07_norm_07b_sam_masks.png"
      else
        add_step "Pass 7.5b: SAM Raw Masks",
          content: "No SAM queries needed (no windows or water in L1 types)"
      end
    end

    # --- Pass 7.5c: Exit-guided door placement ---
    exit_doors = svc.norm_v3_exit_guided_doors(typed_map, all_coords, forced_directions: @fake_exits, hex_zones: hex_zones)
    exit_doors.each { |coord, type| typed_map[coord] = type }
    exits_label = @fake_exits ? "fake exits: #{@fake_exits.join(', ')}" : "from room data"
    render_typed_map_overlay(typed_map, "07_norm_07b2_exitdoors.png", "Pass 7.5c: Exit-Guided Doors")
    add_step "Pass 7.5c: Exit-Guided Doors",
      content: "#{exit_doors.length} doors placed (#{exits_label})",
      image: "07_norm_07b2_exitdoors.png",
      data: type_dist(typed_map)

    # --- Pass 7.6: Wall thinning → door detection ---
    wall_doors = svc.norm_v3_wall_door_detection(typed_map, all_coords)
    wall_doors.each { |coord, type| typed_map[coord] = type }
    render_typed_map_overlay(typed_map, "07_norm_07c_walldoors.png", "Pass 7.6: Wall Door Detection")
    add_step "Pass 7.6: Wall Door Detection",
      content: "#{wall_doors.length} hexes detected as doors via wall thinning",
      image: "07_norm_07c_walldoors.png",
      data: type_dist(typed_map)

    # --- Pass 7.7: Door joining ---
    door_joins = svc.norm_v3_door_join(typed_map, all_coords, hex_zones: hex_zones)
    door_joins.each { |coord, type| typed_map[coord] = type }
    if door_joins.any?
      render_typed_map_overlay(typed_map, "07_norm_07_7_doorjoin.png", "Pass 7.7: Door Join")
      add_step "Pass 7.7: Door Join",
        content: "#{door_joins.length} wall gaps filled between adjacent door hexes",
        image: "07_norm_07_7_doorjoin.png",
        data: type_dist(typed_map)
    end

    # --- Pass 8: Door/window passthrough ---
    pass_num += 1
    passthroughs = svc.norm_v3_passthrough(typed_map, all_coords)
    passthroughs.each { |coord, type| typed_map[coord] = type }
    render_typed_map_overlay(typed_map, "07_norm_08_passthrough.png", "Pass 8: Passthrough")
    add_step "Pass 8: Door/Window Passthrough",
      content: "#{passthroughs.length} hexes converted through wall thickness",
      image: "07_norm_08_passthrough.png",
      data: type_dist(typed_map)

    # --- Pass 9: Lockoff detection ---
    pass_num += 1
    lock_gaps = svc.norm_v3_lockoff_detection(typed_map, all_coords, hex_zones: hex_zones)
    lock_gaps.each { |coord, type| typed_map[coord] = type }
    render_typed_map_overlay(typed_map, "07_norm_09_lockoff.png", "Pass 9: Lockoff Detection")
    add_step "Pass 9: Lockoff Detection",
      content: "#{lock_gaps.length} gaps punched to connect inaccessible areas",
      image: "07_norm_09_lockoff.png",
      data: type_dist(typed_map)

    # --- Pass 9.5: Cleanup errant object hexes in wall/off_map zones ---
    errant = svc.norm_v3_cleanup_errant(typed_map, all_coords, hex_zones: hex_zones)
    errant.each { |coord, type| typed_map[coord] = type }
    if errant.any?
      render_typed_map_overlay(typed_map, "07_norm_09_5_cleanup.png", "Pass 9.5: Errant Cleanup")
      add_step "Pass 9.5: Errant Cleanup",
        content: "#{errant.length} object hexes cleared from wall/off_map zones",
        image: "07_norm_09_5_cleanup.png",
        data: type_dist(typed_map)
    end

    # --- Pass 9.8: Inaccessible hex removal ---
    inaccessible = svc.norm_v3_inaccessible(typed_map, all_coords, hex_zones: hex_zones)
    inaccessible.each { |coord, type| typed_map[coord] = type }
    if inaccessible.any?
      render_typed_map_overlay(typed_map, "07_norm_09_8_inaccessible.png", "Pass 9.8: Inaccessible")
      add_step "Pass 9.8: Inaccessible",
        content: "#{inaccessible.length} isolated hexes removed (unreachable from main room)",
        image: "07_norm_09_8_inaccessible.png",
        data: type_dist(typed_map)
    end

    # --- Final result ---
    @normalized = typed_map.map do |(hx, hy), hex_type|
      r = { 'x' => hx, 'y' => hy, 'hex_type' => hex_type }
      r['ascending_direction'] = ascending_directions[[hx, hy]] if ascending_directions[[hx, hy]]
      r
    end

    render_typed_map_overlay(typed_map, "07_norm_final.png", "Normalization Complete")
    zone_info = hex_zones.any? ? "Zone map: yes (#{hex_zones.length} hexes)" : "Zone map: no"
    add_step "Normalization Complete",
      content: "#{before_count} -> #{@normalized.length} hexes (delta: #{@normalized.length - before_count})\n#{zone_info}",
      image: "07_norm_final.png",
      data: type_dist(typed_map)
  end

  def type_dist(typed_map)
    typed_map.each_with_object(Hash.new(0)) { |(_, t), h| h[t] += 1 }.sort_by { |_, v| -v }.to_h
  end

  def render_typed_map_overlay(typed_map, filename, _title = nil)
    return unless @base_image && @hex_pixel_map

    hex_size = @hex_pixel_map[:hex_size]
    lookup = svc.coord_lookup

    svg_elements = typed_map.map do |(hx, hy), ht|
      info = lookup[[hx, hy]]
      next unless info
      color = VIS_COLORS[ht] || [255, 0, 255]
      points = hexagon_points(info[:px], info[:py], hex_size)
      abbrev = ht[0..2]
      "<polygon points='#{points}' fill='rgba(#{color[0]},#{color[1]},#{color[2]},0.5)' stroke='rgba(#{color[0]},#{color[1]},#{color[2]},0.8)' stroke-width='1'/>" \
      "<text x='#{info[:px]}' y='#{info[:py] + 3}' text-anchor='middle' fill='white' font-size='#{[hex_size * 0.4, 8].max}' font-family='monospace'>#{abbrev}</text>"
    end.compact.join("\n")

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{@base_image.width}" height="#{@base_image.height}">
        #{svg_elements}
      </svg>
    SVG

    overlay = Vips::Image.svgload_buffer(svg)
    if overlay.width != @base_image.width
      overlay = overlay.resize(@base_image.width.to_f / overlay.width,
                                vscale: @base_image.height.to_f / overlay.height)
    end

    base_rgba = @base_image.bands >= 4 ? @base_image : @base_image.bandjoin(255)
    overlay_rgba = overlay.bands >= 4 ? overlay : overlay.bandjoin(255)
    composite = base_rgba.composite(overlay_rgba, :over)

    save_image(composite, filename)
  end

  # --- Step: Type Mapping ---
  def step_type_mapping
    return unless @normalized

    # Build type properties from overview (if available) or L1 grid data
    overview_type_properties = {}
    if @overview
      (@overview['present_types'] || []).each do |t|
        props = {}
        %w[traversable provides_cover provides_concealment is_wall is_exit difficult_terrain].each do |key|
          props[key] = t[key] unless t[key].nil?
        end
        props['elevation'] = t['elevation'] if t['elevation']
        props['hazards'] = t['hazards'] if t['hazards']
        overview_type_properties[t['type_name']] = props
      end
    elsif @grid_details && @grid_details[:l1] && @grid_details[:l1][:data]
      # Use L1 custom types as source of tactical properties
      # Custom types are always traversable (impassable things use wall type)
      (@grid_details[:l1][:data]['custom_types'] || []).each do |ct|
        props = { 'traversable' => true }
        %w[provides_cover is_exit difficult_terrain].each do |key|
          props[key] = ct[key] unless ct[key].nil?
        end
        props['elevation'] = ct['elevation'] if ct['elevation'] && ct['elevation'] != 0
        props['hazards'] = ct['hazards'] if ct['hazards'] && !ct['hazards'].empty?
        overview_type_properties[ct['type_name']] = props
      end
    end

    @hex_data = svc.map_results_to_room_hex(@normalized, @hex_coords, @min_x, @min_y, overview_type_properties)

    dist = @hex_data.each_with_object(Hash.new(0)) { |h, acc| acc[h[:hex_type]] += 1 }
      .sort_by { |_, v| -v }.to_h

    add_step "Type Mapping (to RoomHex)",
      content: "#{@hex_data.length} hexes mapped to DB types\noff_map hexes excluded, BFS interior filtering applied",
      data: dist
  end

  # --- Step: Crop Border ---
  def step_crop_border
    return unless @hex_data && @processed_image_path

    # Set analysis_hex_size so crop_border_with_image can calculate pixel bounds
    svc.instance_variable_set(:@analysis_hex_size, @hex_pixel_map[:hex_size])

    # Use a copy of the image so we don't mutate the original
    crop_image_path = File.join(out_dir, "08_crop_input#{File.extname(@processed_image_path)}")
    FileUtils.cp(@processed_image_path, crop_image_path)

    cropped_data, cropped_path = svc.crop_border_with_image(@hex_data, crop_image_path)

    if cropped_path && File.exist?(cropped_path)
      cropped_img = Vips::Image.new_from_file(cropped_path)
      fname = "08_cropped_final#{File.extname(cropped_path)}"
      copy_image(cropped_path, fname)

      dist = cropped_data.each_with_object(Hash.new(0)) { |h, acc| acc[h[:hex_type]] += 1 }
        .sort_by { |_, v| -v }.to_h

      add_step "Final Crop",
        content: "#{cropped_img.width} x #{cropped_img.height} px\n#{cropped_data.length} hexes (from #{@hex_data.length})\nHex bounds: x=#{cropped_data.map { |h| h[:x] }.minmax.join('..')}, y=#{cropped_data.map { |h| h[:y] }.minmax.join('..')}",
        image: fname,
        data: dist
    else
      add_step "Final Crop", content: "Crop failed or no change"
    end
  end

  # --- Helpers ---

  def hexagon_points(cx, cy, size)
    6.times.map do |i|
      angle = Math::PI / 3 * i
      x = cx + size * Math.cos(angle)
      y = cy + size * Math.sin(angle)
      "#{x.round(1)},#{y.round(1)}"
    end.join(' ')
  end

  # Returns hex vertices as [[x,y], ...] array for geometric operations
  def hexagon_points_array(cx, cy, size)
    6.times.map do |i|
      angle = Math::PI / 3 * i
      [cx + size * Math.cos(angle), cy + size * Math.sin(angle)]
    end
  end

  # Compute the area of intersection between two convex polygons.
  # Uses Sutherland-Hodgman clipping + shoelace formula.
  def polygon_intersection_area(subject, clip)
    output = subject.dup
    clip.length.times do |i|
      return 0.0 if output.empty?
      input = output
      output = []
      edge_start = clip[i]
      edge_end = clip[(i + 1) % clip.length]
      input.length.times do |j|
        current = input[j]
        prev = input[(j - 1) % input.length]
        curr_inside = cross_2d(edge_start, edge_end, current) >= 0
        prev_inside = cross_2d(edge_start, edge_end, prev) >= 0
        if curr_inside
          output << line_intersect(prev, current, edge_start, edge_end) unless prev_inside
          output << current
        elsif prev_inside
          output << line_intersect(prev, current, edge_start, edge_end)
        end
      end
    end
    return 0.0 if output.length < 3
    shoelace_area(output)
  end

  def cross_2d(a, b, p)
    (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
  end

  def line_intersect(p1, p2, p3, p4)
    x1, y1 = p1; x2, y2 = p2; x3, y3 = p3; x4, y4 = p4
    denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    return p1 if denom.abs < 1e-10
    t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom
    [x1 + t * (x2 - x1), y1 + t * (y2 - y1)]
  end

  def shoelace_area(polygon)
    n = polygon.length
    area = 0.0
    n.times do |i|
      j = (i + 1) % n
      area += polygon[i][0] * polygon[j][1]
      area -= polygon[j][0] * polygon[i][1]
    end
    area.abs / 2.0
  end

  # Overlay a numbered grid on an image.
  # inset: { x:, y:, w:, h: } — if provided, the grid only covers this sub-region
  #   of the image (used with blur buffer so grid covers the sharp inner area only).
  #   Cell coordinates in the returned hash are relative to the full image.
  def overlay_square_grid(image, n, label_offset: 0, inset: nil)
    img_w = image.width
    img_h = image.height

    # Grid region — either the full image or the inset sub-region
    gx = inset ? inset[:x] : 0
    gy = inset ? inset[:y] : 0
    gw = inset ? inset[:w] : img_w
    gh = inset ? inset[:h] : img_h

    cell_w = gw.to_f / n
    cell_h = gh.to_f / n
    font_size = [([cell_w, cell_h].min * 0.3).round, 12].max

    cells = {}
    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_w}" height="#{img_h}">)

    # Grid lines — white with black outline for visibility on any background
    (1...n).each do |i|
      x = gx + (i * cell_w).round
      y = gy + (i * cell_h).round
      svg_parts << %(<line x1="#{x}" y1="#{gy}" x2="#{x}" y2="#{gy + gh}" stroke="black" stroke-width="4"/>)
      svg_parts << %(<line x1="#{x}" y1="#{gy}" x2="#{x}" y2="#{gy + gh}" stroke="white" stroke-width="2"/>)
      svg_parts << %(<line x1="#{gx}" y1="#{y}" x2="#{gx + gw}" y2="#{y}" stroke="black" stroke-width="4"/>)
      svg_parts << %(<line x1="#{gx}" y1="#{y}" x2="#{gx + gw}" y2="#{y}" stroke="white" stroke-width="2"/>)
    end

    # Outer border of the grid region
    svg_parts << %(<rect x="#{gx}" y="#{gy}" width="#{gw}" height="#{gh}" fill="none" stroke="black" stroke-width="4"/>)
    svg_parts << %(<rect x="#{gx}" y="#{gy}" width="#{gw}" height="#{gh}" fill="none" stroke="white" stroke-width="2"/>)

    # Labels — white text with black outline
    cell_num = 1
    n.times do |row|
      n.times do |col|
        label = cell_num + label_offset
        cx = gx + ((col + 0.5) * cell_w).round
        cy = gy + ((row + 0.5) * cell_h).round
        # Cell coordinates relative to the full image
        cells[cell_num] = {
          x: gx + (col * cell_w).round, y: gy + (row * cell_h).round,
          w: cell_w.round, h: cell_h.round,
          cx: cx, cy: cy
        }
        svg_parts << %(<text x="#{cx}" y="#{cy + font_size * 0.35}" text-anchor="middle" fill="white" stroke="black" stroke-width="3" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
        svg_parts << %(<text x="#{cx}" y="#{cy + font_size * 0.35}" text-anchor="middle" fill="white" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
        cell_num += 1
      end
    end

    svg_parts << '</svg>'
    overlay = Vips::Image.svgload_buffer(svg_parts.join("\n"))
    overlay = overlay.resize(img_w.to_f / overlay.width) if overlay.width != img_w || overlay.height != img_h

    base_rgba = image.bands >= 4 ? image : image.bandjoin(255)
    overlay_rgba = overlay.bands >= 4 ? overlay : overlay.bandjoin(255)
    composited = base_rgba.composite(overlay_rgba, :over)

    { image: composited, cells: cells }
  end

  def crop_cell(image, cell)
    x = [cell[:x], 0].max
    y = [cell[:y], 0].max
    w = [cell[:w], 1].max
    h = [cell[:h], 1].max
    w = [w, image.width - x].min
    h = [h, image.height - y].min
    image.crop(x, y, w, h)
  end

  # Crop a cell from the image with a blurred border buffer for context.
  # Expands the crop region by blur_pct in each direction, then applies
  # Gaussian blur to the expanded border area outside the original cell.
  # Returns { image:, origin_x:, origin_y:, inner_x:, inner_y:, inner_w:, inner_h: }
  # - origin is the top-left of the expanded crop in full-image coordinates
  # - inner_x/y/w/h is the sharp region within the returned image (for grid overlay placement)
  def crop_cell_with_blur(image, cell, blur_pct: 0.25)
    cx = [cell[:x], 0].max
    cy = [cell[:y], 0].max
    cw = [cell[:w], 1].max
    ch = [cell[:h], 1].max
    cw = [cw, image.width - cx].min
    ch = [ch, image.height - cy].min

    # Calculate expanded region
    expand_x = (cw * blur_pct).round
    expand_y = (ch * blur_pct).round

    ex = [cx - expand_x, 0].max
    ey = [cy - expand_y, 0].max
    ex2 = [cx + cw + expand_x, image.width].min
    ey2 = [cy + ch + expand_y, image.height].min
    ew = ex2 - ex
    eh = ey2 - ey

    if ew <= 0 || eh <= 0
      return { image: image.crop(cx, cy, cw, ch), origin_x: cx, origin_y: cy,
               inner_x: 0, inner_y: 0, inner_w: cw, inner_h: ch }
    end

    # Crop expanded region
    expanded = image.crop(ex, ey, ew, eh)

    # Create blurred version of the expanded region
    sigma = [cw, ch].min * 0.08  # blur strength relative to cell size
    sigma = [sigma, 2.0].max
    blurred = expanded.gaussblur(sigma)

    # Build a mask: white (255) inside original cell area, black (0) outside
    # Coordinates relative to the expanded crop
    inner_x = cx - ex
    inner_y = cy - ey

    # Create mask as a single-band image
    # Start with black (all blurred), paint white rectangle for sharp area
    mask = Vips::Image.black(ew, eh)
    white_rect = Vips::Image.black(cw, ch).invert  # all 255
    mask = mask.insert(white_rect, inner_x, inner_y)

    # Feather the mask edges slightly for smooth transition
    feather = [sigma * 0.5, 1.0].max
    mask = mask.gaussblur(feather)

    # Composite: sharp where mask is white, blurred where mask is black
    # result = sharp * mask + blurred * (1 - mask)
    mask_f = mask.cast(:float) / 255.0
    sharp_f = expanded.cast(:float)
    blurred_f = blurred.cast(:float)

    if sharp_f.bands > 1 && mask_f.bands == 1
      # Extend mask to match image bands
      mask_f = mask_f.bandjoin([mask_f] * (sharp_f.bands - 1))
    end

    result = (sharp_f * mask_f + blurred_f * (mask_f * -1 + 1)).cast(:uchar)
    { image: result, origin_x: ex, origin_y: ey,
      inner_x: inner_x, inner_y: inner_y, inner_w: cw, inner_h: ch }
  end

  def count_hexes_in_rect(px_x, px_y, px_w, px_h)
    count = 0
    svc.coord_lookup.each do |(_hx, _hy), info|
      next unless info.is_a?(Hash) && info[:px]
      if info[:px] >= px_x && info[:px] < px_x + px_w &&
         info[:py] >= px_y && info[:py] < px_y + px_h
        count += 1
      end
    end
    count
  end

  def hexes_in_rect(px_x, px_y, px_w, px_h)
    results = []
    svc.coord_lookup.each do |(hx, hy), info|
      next unless info.is_a?(Hash) && info[:px]
      if info[:px] >= px_x && info[:px] < px_x + px_w &&
         info[:py] >= px_y && info[:py] < px_y + px_h
        results << [hx, hy, info[:px], info[:py]]
      end
    end
    results
  end

  VIS_COLORS = {
    'wall' => [80, 80, 80], 'off_map' => [30, 30, 30],
    'treetrunk' => [0, 100, 0], 'treebranch' => [34, 139, 34],
    'shrubbery' => [107, 142, 35], 'table' => [139, 90, 43],
    'chair' => [160, 82, 45], 'fire' => [255, 100, 0],
    'barrel' => [139, 90, 43], 'door' => [139, 69, 19],
    'glass_window' => [135, 206, 250], 'crate' => [160, 120, 60],
    'chest' => [184, 134, 11], 'staircase' => [192, 192, 192],
    'weapon_rack' => [100, 100, 150], 'anvil' => [120, 120, 120],
    'forge' => [200, 80, 0], 'armor_stand' => [150, 150, 170],
    'bench' => [160, 82, 45], 'pillar' => [192, 192, 192],
    'glass_display_case' => [170, 210, 240], 'display_case' => [170, 210, 240],
    'forge_platform' => [180, 80, 20],
    'boulder' => [139, 137, 137], 'fence' => [139, 119, 101],
    'water' => [30, 100, 200], 'rug' => [130, 60, 60],
    'counter' => [120, 80, 50], 'shelf' => [110, 80, 50],
    'bookshelf' => [100, 70, 40], 'bed' => [140, 80, 80],
    'campfire' => [255, 120, 30], 'brazier' => [220, 100, 20],
    'statue' => [180, 180, 180], 'column' => [170, 170, 170],
  }.freeze

  def render_classification_overlay(results, filename, title)
    return unless @base_image && @hex_pixel_map

    hex_size = @hex_pixel_map[:hex_size]
    lookup = svc.coord_lookup

    svg_elements = results.map do |r|
      hx, hy, ht = r['x'], r['y'], r['hex_type']
      info = lookup[[hx, hy]]
      next unless info
      color = VIS_COLORS[ht] || [255, 0, 255]
      points = hexagon_points(info[:px], info[:py], hex_size)
      abbrev = ht[0..2]
      "<polygon points='#{points}' fill='rgba(#{color[0]},#{color[1]},#{color[2]},0.5)' stroke='rgba(#{color[0]},#{color[1]},#{color[2]},0.8)' stroke-width='1'/>" \
      "<text x='#{info[:px]}' y='#{info[:py] + 3}' text-anchor='middle' fill='white' font-size='#{[hex_size * 0.4, 8].max}' font-family='monospace'>#{abbrev}</text>"
    end.compact.join("\n")

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{@base_image.width}" height="#{@base_image.height}">
        #{svg_elements}
      </svg>
    SVG

    overlay = Vips::Image.svgload_buffer(svg)
    if overlay.width != @base_image.width
      overlay = overlay.resize(@base_image.width.to_f / overlay.width,
                                vscale: @base_image.height.to_f / overlay.height)
    end

    base_rgba = @base_image.bands >= 4 ? @base_image : @base_image.bandjoin(255)
    overlay_rgba = overlay.bands >= 4 ? overlay : overlay.bandjoin(255)
    composite = base_rgba.composite(overlay_rgba, :over)

    save_image(composite, filename)
    add_step title, image: filename
  end

  # --- HTML Output ---

  def write_html
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>Battle Map Inspector: #{room.name}</title>
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body { background: #1a1a2e; color: #e0e0e0; font-family: system-ui, sans-serif; padding: 20px; }
          h1 { color: #00d4ff; margin-bottom: 20px; }
          .step { background: #16213e; border: 1px solid #2a3a5c; border-radius: 8px; margin-bottom: 20px; overflow: hidden; }
          .step-header { background: #0f3460; padding: 12px 16px; cursor: pointer; display: flex; align-items: center; gap: 10px; }
          .step-header:hover { background: #1a4a7a; }
          .step-num { background: #00d4ff; color: #1a1a2e; width: 28px; height: 28px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: bold; font-size: 13px; flex-shrink: 0; }
          .step-title { font-size: 16px; font-weight: 600; }
          .step-body { padding: 16px; display: none; }
          .step.open .step-body { display: block; }
          .step-content { white-space: pre-wrap; margin-bottom: 12px; line-height: 1.5; }
          .step-image { max-width: 100%; border: 1px solid #2a3a5c; border-radius: 4px; cursor: pointer; }
          .step-image:hover { border-color: #00d4ff; }
          .step-data { display: grid; grid-template-columns: auto 1fr; gap: 4px 16px; margin-bottom: 12px; }
          .step-data dt { color: #888; font-size: 13px; }
          .step-data dd { font-size: 14px; white-space: pre-wrap; }
          .step-code { background: #0a0a1a; border: 1px solid #2a3a5c; border-radius: 4px; padding: 12px; font-family: 'Fira Code', monospace; font-size: 12px; max-height: 400px; overflow: auto; white-space: pre-wrap; word-break: break-all; }
          .toggle-code { background: #2a3a5c; color: #ccc; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; margin-bottom: 8px; font-size: 12px; }
          .toggle-code:hover { background: #3a4a6c; }
          .image-compare { display: flex; gap: 10px; flex-wrap: wrap; }
          .image-compare img { flex: 1; min-width: 300px; max-width: 49%; }
          /* Lightbox */
          .lightbox { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.9); z-index: 1000; cursor: pointer; }
          .lightbox img { max-width: 95%; max-height: 95%; position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); }
          .lightbox.active { display: block; }
        </style>
      </head>
      <body>
        <h1>Battle Map Inspector: #{room.name} (Room #{room.id})</h1>
        <div id="lightbox" class="lightbox" onclick="this.classList.remove('active')">
          <img id="lightbox-img" src="">
        </div>
    HTML

    @steps.each_with_index do |step, idx|
      # Auto-open first few steps
      open_class = idx < 3 ? ' open' : ''
      html << "<div class='step#{open_class}'>\n"
      html << "  <div class='step-header' onclick='this.parentElement.classList.toggle(\"open\")'>\n"
      html << "    <span class='step-num'>#{idx + 1}</span>\n"
      html << "    <span class='step-title'>#{step[:title]}</span>\n"
      html << "  </div>\n"
      html << "  <div class='step-body'>\n"

      if step[:content]
        html << "    <div class='step-content'>#{escape_html(step[:content])}</div>\n"
      end

      if step[:data]
        html << "    <dl class='step-data'>\n"
        step[:data].each do |k, v|
          html << "      <dt>#{escape_html(k.to_s)}</dt><dd>#{escape_html(v.to_s)}</dd>\n"
        end
        html << "    </dl>\n"
      end

      if step[:image]
        html << "    <img class='step-image' src='#{step[:image]}' onclick='showLightbox(this.src)' />\n"
      end

      if step[:code]
        html << "    <button class='toggle-code' onclick='this.nextElementSibling.style.display=this.nextElementSibling.style.display===\"none\"?\"block\":\"none\"'>Show/Hide Details</button>\n"
        html << "    <div class='step-code' style='display:none'>#{escape_html(step[:code])}</div>\n"
      end

      html << "  </div>\n"
      html << "</div>\n"
    end

    # Chunk gallery section
    if @chunk_details&.any?
      html << "<div class='step'>\n"
      html << "  <div class='step-header' onclick='this.parentElement.classList.toggle(\"open\")'>\n"
      html << "    <span class='step-num'>C</span>\n"
      html << "    <span class='step-title'>All Chunks (#{@chunk_details.length})</span>\n"
      html << "  </div>\n"
      html << "  <div class='step-body'>\n"
      html << "    <div style='display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px'>\n"

      @chunk_details.each do |cd|
        types_found = (cd[:parsed] || []).each_with_object(Hash.new(0)) { |r, h| h[r['hex_type']] += 1 }
          .sort_by { |_, v| -v }.map { |t, c| "#{t}:#{c}" }.join(' ')
        parsed_count = cd[:parsed]&.length || 0
        border_color = cd[:error] ? '#ff4444' : '#2a3a5c'

        html << "      <div style='background:#0a0a1a;border:1px solid #{border_color};border-radius:6px;overflow:hidden'>\n"
        html << "        <div style='padding:8px;background:#0f3460;font-size:13px;font-weight:600'>Chunk #{cd[:idx]} — gx=#{cd[:grid_pos][:gx]} gy=#{cd[:grid_pos][:gy]} (#{cd[:hex_count]} hexes → #{parsed_count} classified)</div>\n"
        html << "        <img src='#{cd[:image]}' onclick='showLightbox(this.src)' style='width:100%;cursor:pointer' />\n"

        if cd[:area_desc]
          html << "        <div style='padding:6px 8px;font-size:12px;color:#aaa;border-top:1px solid #2a3a5c'><b>Area:</b> #{escape_html(cd[:area_desc])}</div>\n"
        end

        if cd[:error]
          html << "        <div style='padding:6px 8px;font-size:12px;color:#ff4444'>ERROR: #{escape_html(cd[:error])}</div>\n"
        end

        if types_found.length > 0
          html << "        <div style='padding:6px 8px;font-size:11px;color:#888;border-top:1px solid #2a3a5c;word-break:break-all'>#{escape_html(types_found)}</div>\n"
        end

        # Prompt and LLM output toggles
        html << "        <div style='padding:4px 8px;border-top:1px solid #2a3a5c;display:flex;gap:4px'>"
        if cd[:prompt]
          prompt_id = "chunk_prompt_#{cd[:idx]}"
          html << "<button class='toggle-code' onclick='document.getElementById(\"#{prompt_id}\").style.display=document.getElementById(\"#{prompt_id}\").style.display===\"none\"?\"block\":\"none\"' style='font-size:11px;padding:3px 8px'>Prompt</button>"
        end
        if cd[:raw_response]
          chunk_id = "chunk_raw_#{cd[:idx]}"
          html << "<button class='toggle-code' onclick='document.getElementById(\"#{chunk_id}\").style.display=document.getElementById(\"#{chunk_id}\").style.display===\"none\"?\"block\":\"none\"' style='font-size:11px;padding:3px 8px'>LLM output</button>"
        end
        html << "</div>\n"
        if cd[:prompt]
          prompt_id = "chunk_prompt_#{cd[:idx]}"
          html << "        <div id='#{prompt_id}' class='step-code' style='display:none;max-height:300px;font-size:11px;margin:0 8px 4px'>#{escape_html(cd[:prompt])}</div>\n"
        end
        if cd[:raw_response]
          raw_json = JSON.pretty_generate(cd[:raw_response])
          chunk_id = "chunk_raw_#{cd[:idx]}"
          html << "        <div id='#{chunk_id}' class='step-code' style='display:none;max-height:300px;font-size:11px;margin:0 8px 8px'>#{escape_html(raw_json)}</div>\n"
        end

        html << "      </div>\n"
      end

      html << "    </div>\n"
      html << "  </div>\n"
      html << "</div>\n"
    end

    # Grid classification gallery section
    if @grid_details && @grid_details[:l1]
      html << "<div class='step'>\n"
      html << "  <div class='step-header' onclick='this.parentElement.classList.toggle(\"open\")'>\n"
      html << "    <span class='step-num'>G</span>\n"
      html << "    <span class='step-title'>Grid Classification Details</span>\n"
      html << "  </div>\n"
      html << "  <div class='step-body'>\n"

      # L1
      l1 = @grid_details[:l1]
      html << "    <h3 style='color:#00d4ff;margin:12px 0 8px'>Level 1: Full Image 3x3</h3>\n"
      html << "    <div style='display:flex;gap:12px;flex-wrap:wrap'>\n"
      html << "      <img src='#{l1[:image]}' onclick='showLightbox(this.src)' style='max-width:400px;cursor:pointer;border:1px solid #2a3a5c;border-radius:4px' />\n"
      html << "      <div style='flex:1;min-width:200px'>\n"
      prompt_id = "grid_l1_prompt"
      html << "        <button class='toggle-code' onclick='document.getElementById(\"#{prompt_id}\").style.display=document.getElementById(\"#{prompt_id}\").style.display===\"none\"?\"block\":\"none\"'>Prompt</button>\n"
      html << "        <div id='#{prompt_id}' class='step-code' style='display:none;max-height:300px;font-size:11px'>#{escape_html(l1[:prompt])}</div>\n"
      if l1[:data]
        html << "        <div class='step-code' style='max-height:400px;font-size:11px;margin-top:8px'>#{escape_html(JSON.pretty_generate(l1[:data]))}</div>\n"
      end
      html << "      </div>\n"
      html << "    </div>\n"

      # L2 gallery
      if @grid_details[:l2]&.any?
        html << "    <h3 style='color:#00d4ff;margin:20px 0 8px'>Level 2: Subsquare Refinement (#{@grid_details[:l2].length} squares)</h3>\n"
        html << "    <div style='display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px'>\n"
        @grid_details[:l2].each do |l2|
          border_color = l2[:data] ? '#2a3a5c' : '#ff4444'
          subsquare_count = l2[:data] ? (l2[:data]['subsquares'] || []).length : 0
          html << "      <div style='background:#0a0a1a;border:1px solid #{border_color};border-radius:6px;overflow:hidden'>\n"
          html << "        <div style='padding:8px;background:#0f3460;font-size:13px;font-weight:600'>L1 Square #{l2[:l1_square]} &rarr; #{subsquare_count} subsquares</div>\n"
          html << "        <img src='#{l2[:image]}' onclick='showLightbox(this.src)' style='width:100%;cursor:pointer' />\n"
          if l2[:l1_data]
            html << "        <div style='padding:6px 8px;font-size:12px;color:#aaa;border-top:1px solid #2a3a5c'>#{escape_html(l2[:l1_data]['description'] || '')}</div>\n"
          end
          html << "        <div style='padding:4px 8px;border-top:1px solid #2a3a5c;display:flex;gap:4px'>"
          if l2[:prompt]
            l2_prompt_id = "grid_l2_prompt_#{l2[:l1_square]}"
            html << "<button class='toggle-code' onclick='document.getElementById(\"#{l2_prompt_id}\").style.display=document.getElementById(\"#{l2_prompt_id}\").style.display===\"none\"?\"block\":\"none\"' style='font-size:11px;padding:3px 8px'>Prompt</button>"
          end
          if l2[:data]
            l2_id = "grid_l2_#{l2[:l1_square]}"
            html << "<button class='toggle-code' onclick='document.getElementById(\"#{l2_id}\").style.display=document.getElementById(\"#{l2_id}\").style.display===\"none\"?\"block\":\"none\"' style='font-size:11px;padding:3px 8px'>LLM output</button>"
          end
          html << "</div>\n"
          if l2[:prompt]
            l2_prompt_id = "grid_l2_prompt_#{l2[:l1_square]}"
            html << "        <div id='#{l2_prompt_id}' class='step-code' style='display:none;max-height:300px;font-size:11px;margin:0 8px 4px'>#{escape_html(l2[:prompt])}</div>\n"
          end
          if l2[:data]
            l2_id = "grid_l2_#{l2[:l1_square]}"
            html << "        <div id='#{l2_id}' class='step-code' style='display:none;max-height:300px;font-size:11px;margin:0 8px 8px'>#{escape_html(JSON.pretty_generate(l2[:data]))}</div>\n"
          end
          html << "      </div>\n"
        end
        html << "    </div>\n"
      end

      # L3 gallery
      if @grid_details[:l3]&.any?
        html << "    <h3 style='color:#00d4ff;margin:20px 0 8px'>Level 3: Cell Classification (#{@grid_details[:l3].length} subsquares)</h3>\n"
        html << "    <div style='display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px'>\n"
        @grid_details[:l3].each do |l3|
          border_color = l3[:data] ? '#2a3a5c' : '#ff4444'
          html << "      <div style='background:#0a0a1a;border:1px solid #{border_color};border-radius:6px;overflow:hidden'>\n"
          html << "        <div style='padding:6px 8px;background:#0f3460;font-size:12px;font-weight:600'>Sq #{l3[:l1_square]}.#{l3[:l2_square]} (#{l3[:grid_n]}x#{l3[:grid_n]})</div>\n"
          html << "        <img src='#{l3[:image]}' onclick='showLightbox(this.src)' style='width:100%;cursor:pointer' />\n"
          if l3[:data]
            area_desc = l3[:data]['area_description']
            html << "        <div style='padding:6px 8px;font-size:12px;color:#aaa;border-top:1px solid #2a3a5c'>#{escape_html(area_desc)}</div>\n" if area_desc && !area_desc.empty?
          end
          html << "        <div style='padding:4px 8px;border-top:1px solid #2a3a5c;display:flex;gap:4px'>"
          if l3[:prompt]
            l3_prompt_id = "grid_l3_prompt_#{l3[:l1_square]}_#{l3[:l2_square]}"
            html << "<button class='toggle-code' onclick='document.getElementById(\"#{l3_prompt_id}\").style.display=document.getElementById(\"#{l3_prompt_id}\").style.display===\"none\"?\"block\":\"none\"' style='font-size:11px;padding:3px 8px'>Prompt</button>"
          end
          if l3[:data]
            l3_id = "grid_l3_#{l3[:l1_square]}_#{l3[:l2_square]}"
            html << "<button class='toggle-code' onclick='document.getElementById(\"#{l3_id}\").style.display=document.getElementById(\"#{l3_id}\").style.display===\"none\"?\"block\":\"none\"' style='font-size:11px;padding:3px 8px'>LLM output</button>"
          end
          html << "</div>\n"
          if l3[:prompt]
            l3_prompt_id = "grid_l3_prompt_#{l3[:l1_square]}_#{l3[:l2_square]}"
            html << "        <div id='#{l3_prompt_id}' class='step-code' style='display:none;max-height:300px;font-size:11px;margin:0 8px 4px'>#{escape_html(l3[:prompt])}</div>\n"
          end
          if l3[:data]
            l3_id = "grid_l3_#{l3[:l1_square]}_#{l3[:l2_square]}"
            html << "        <div id='#{l3_id}' class='step-code' style='display:none;max-height:300px;font-size:11px;margin:0 8px 8px'>#{escape_html(JSON.pretty_generate(l3[:data]))}</div>\n"
          end
          html << "      </div>\n"
        end
        html << "    </div>\n"
      end

      html << "  </div>\n"
      html << "</div>\n"
    end

    html << <<~HTML
        <script>
          function showLightbox(src) {
            document.getElementById('lightbox-img').src = src;
            document.getElementById('lightbox').classList.add('active');
          }
        </script>
      </body>
      </html>
    HTML

    File.write(File.join(out_dir, 'index.html'), html)
  end

  def escape_html(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end

# --- Main ---
room_id = ARGV[0]&.to_i
unless room_id && room_id > 0
  puts "Usage: bundle exec ruby tmp/battlemap_inspect.rb <room_id> [--skip-generate]"
  exit 1
end

skip_generate = ARGV.include?('--skip-generate')
grid_only = ARGV.include?('--grid-only')
hex_only = ARGV.include?('--hex-only')
use_gemini = ARGV.include?('--gemini')
cv_mode = ARGV.include?('--cv')
# --exits=north,south,east to fake exit directions for testing
fake_exits = nil
exits_arg = ARGV.find { |a| a.start_with?('--exits=') }
if exits_arg
  fake_exits = exits_arg.sub('--exits=', '').split(',').map(&:strip).map(&:to_sym)
  puts "Using fake exit directions: #{fake_exits.join(', ')}"
end
BattleMapInspector.new(room_id, skip_generate: skip_generate, grid_only: grid_only, hex_only: hex_only, use_gemini: use_gemini, cv_mode: cv_mode, fake_exits: fake_exits).run
