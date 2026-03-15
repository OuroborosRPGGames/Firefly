# frozen_string_literal: true
require_relative 'l1_analysis_config'

module BattlemapV2
  # Top-level orchestrator for V2 battlemap analysis pipeline.
  #
  # Parallel execution strategy:
  #   Phase 1 (parallel): L1 scene analysis + Gemini wall/door recolor + depth estimation
  #   Phase 2 (parallel): All SAM2G per-object queries + generic list query + effect masks
  #   Phase 3 (sequential): Hex overlay → pixel mask → persist
  #
  # Usage:
  #   svc = BattlemapV2::PipelineService.new(room: room, image_path: local_path)
  #   hex_data = svc.run
  class PipelineService
    GRID_L1_MODEL = 'gemini-3.1-pro-preview'
    EXCLUDE_FROM_SAM = %w[door window gate archway opening hatch wall off_map open_floor].freeze

    # Python debug visualization scripts (in lib/cv/)
    CV_DIR = File.expand_path('../../../lib/cv', __dir__)
    WALL_GAPS_SCRIPT = File.join(CV_DIR, 'debug_wall_gaps.py')
    SAM_COMPOSITE_SCRIPT = File.join(CV_DIR, 'debug_sam_composite.py')
    SAM_MODEL_COMPOSITE_SCRIPT = File.join(CV_DIR, 'debug_sam_model_composite.py')
    DEPTH_ELEVATION_SCRIPT = File.join(CV_DIR, 'depth_elevation_analyze.py')

    def initialize(room:, image_path:, on_progress: nil)
      @room = room
      @image_path = image_path.to_s.gsub('//', '/')
      @output_dir = File.join('tmp', 'battlemap_v2', "room_#{room.id}")
      @on_progress = on_progress
    end

    # Run the full V2 pipeline. Returns hex data array for persist_hex_data.
    # @return [Array<Hash>] hex data
    def run
      @spawned_threads = []
      t_start = Time.now
      prepare_output_dir

      # === Phase 1: L1 analysis + depth estimation (parallel), then conditional wall/door recolor ===
      # L1 runs first so has_perimeter_wall / has_inner_walls are authoritative gates
      # for the recolor prompt. No perimeter wall → skip recolor entirely.
      # Depth estimation runs in parallel with L1 — it's independent and used later
      # as an additional signal for wall/door classification.
      t1 = Time.now
      depth_thread = spawn_thread('depth_estimate') { run_depth_estimation }
      l1_data = run_l1_analysis
      unless l1_data
        warn "[PipelineV2] L1 analysis failed"
        return []
      end
      t_l1 = (Time.now - t1).round(1)
      @on_progress&.call(:l1_done, "Scene analysis complete (#{t_l1}s)")

      # Extract type info from L1
      standard_types = (l1_data['standard_types_present'] || [])
      custom_types = (l1_data['custom_types'] || [])
      all_types = standard_types.map { |t| t['type_name'] } + custom_types.map { |t| t['type_name'] }
      has_perimeter_wall = l1_data['has_perimeter_wall'] != false  # nil → assume present
      has_inner_walls    = l1_data['has_inner_walls'] == true

      # Start wall/door recolor now that we know the authoritative flags.
      # Skip entirely if there is no perimeter wall (open terrain — no walls to recolor).
      wall_door_thread = has_perimeter_wall ? spawn_thread('wall_recolor') { run_wall_door_recolor(has_inner_walls) } : nil

      # Build SAM queries: prefer short_description (2-4 words), fall back to visual_description
      type_visuals = {}
      standard_types.each { |t| type_visuals[t['type_name']] = t['short_description'] || t['visual_description'] }
      custom_types.each { |c| type_visuals[c['type_name']] = c['short_description'] || c['visual_description'] }

      # Build type properties for custom types.
      # Gemini often omits false boolean values even when required by schema — fill defaults.
      custom_types.each do |ct|
        ct['provides_cover']       = false if ct['provides_cover'].nil?
        ct['provides_concealment'] = false if ct['provides_concealment'].nil?
        ct['is_exit']              = false if ct['is_exit'].nil?
        ct['difficult_terrain']    = false if ct['difficult_terrain'].nil?
        ct['elevation']            = 0     if ct['elevation'].nil?
        ct['hazards']              = []    if ct['hazards'].nil?
      end

      type_properties = {}
      custom_types.each do |ct|
        type_properties[ct['type_name']] = {
          'traversable' => true,
          'provides_cover' => ct['provides_cover'],
          'provides_concealment' => ct['provides_concealment'],
          'is_exit' => ct['is_exit'],
          'difficult_terrain' => ct['difficult_terrain'],
          'elevation' => ct['elevation']
        }.compact
      end

      # === Phase 2: Parallel — SAM2G per-object + generic list + effect masks ===
      t2 = Time.now
      sam_descriptions = {}
      all_types.each do |type_name|
        next if EXCLUDE_FROM_SAM.include?(type_name)
        desc = type_visuals[type_name] || type_name.tr('_', ' ')
        sam_descriptions[type_name] = desc
      end

      generic_labels = sam_descriptions.keys

      sam_svc = SamSegmentationService.new(image_path: @image_path, output_dir: @output_dir)

      # All SAM calls share sam_svc — one Faraday connection, one version cache.
      # No concurrency limit: all per-object, effect, and grounded calls fire at once.
      per_object_thread = spawn_thread('sam_per_object') do
        sam_svc.segment_objects_parallel(sam_descriptions, room_id: @room.id)
      end
      generic_thread = spawn_thread('sam_generic') do
        generic_labels.any? ? sam_svc.segment_generic_list(generic_labels) : { success: true, high_conf: [] }
      end

      # Effect mask threads (window, water, foliage, fire, light sources) — same sam_svc
      effect_threads = start_effect_mask_threads(all_types, l1_data['light_sources'] || [], sam_svc)

      # Collect wall/door recolor result (nil if no perimeter wall → no recolor)
      recolor_path = wall_door_thread&.value

      # Collect depth estimation result (used as additional wall classification signal)
      depth_map_path = collect_depth_result(depth_thread)

      wall_door_svc = WallDoorService.new(
        image_path: @image_path, output_dir: @output_dir,
        colormap_path: recolor_path, depth_map_path: depth_map_path
      )

      # Collect SAM results
      per_object_results = per_object_thread.value || {}
      generic_results = generic_thread.value || { high_conf: [] }
      grounded_raw = (generic_results[:high_conf] || []).dup  # capture before merge
      t_sam = (Time.now - t2).round(1)
      @on_progress&.call(:sam_done, "Object segmentation complete (#{t_sam}s)")

      merge_generic_into_per_object(per_object_results, generic_results[:high_conf])

      combined_mask_path = build_combined_object_mask(per_object_results)

      # === Phases 3+4: Wall analysis and hex overlay in parallel ===
      t3 = Time.now
      window_mask_path = find_window_mask(effect_threads)

      hex_svc = HexOverlayService.new(room: @room, image_path: @image_path)

      # Hex overlay runs without wall mask (off_map detection uses @image_path directly).
      # Wall feature symbols are applied after wall analysis completes.
      hex_thread = spawn_thread('hex_overlay') do
        hex_svc.classify_hexes(
          object_masks: per_object_results,
          window_mask_path: window_mask_path,
          l1_data: l1_data,
          type_properties: type_properties
        )
      end

      wall_door_result = wall_door_svc.build_pixel_mask(
        has_inner_walls: has_inner_walls,
        window_mask_path: window_mask_path,
        object_mask_path: combined_mask_path
      )
      t_wall = (Time.now - t3).round(1)
      @on_progress&.call(:wall_done, "Wall analysis complete (#{t_wall}s)")

      hex_data = hex_thread.value
      wall_mask_path = wall_door_result[:wall_mask_path]
      hex_svc.apply_wall_features(hex_data, wall_mask_path: wall_mask_path) if wall_mask_path
      t_hex = (Time.now - t3).round(1)
      t_total = (Time.now - t_start).round(1)
      @on_progress&.call(:hex_done, "Hex classification complete (#{t_hex}s)")

      # === Phase 4.5: Depth elevation adjustment ===
      depth_map_for_elev = File.join(@output_dir, 'depth_map.png')
      if File.exist?(depth_map_for_elev) && hex_data.any?
        run_depth_elevation_adjustment(hex_data, hex_svc, wall_mask_path)
      end

      @timing = {
        'l1_and_recolor_s' => t_l1,
        'sam_segmentation_s' => t_sam,
        'wall_and_hex_s' => t_hex,
        'total_s' => t_total
      }
      warn "[PipelineV2] Timing: L1=#{t_l1}s SAM=#{t_sam}s Wall+Hex=#{t_hex}s (wall=#{t_wall}s) Total=#{t_total}s"

      # === Phase 5: Persist ===
      persist_wall_mask(wall_door_result)
      persist_effect_masks(effect_threads)
      extract_light_sources(l1_data['light_sources'] || [], effect_threads)

      save_debug_artifacts(l1_data, per_object_results, wall_door_result,
                           grounded_raw: grounded_raw, hex_svc: hex_svc, hex_data: hex_data)

      hex_data
    rescue StandardError => e
      warn "[PipelineV2] Pipeline failed: #{e.class}: #{e.message}"
      warn e.backtrace&.first(5)&.join("\n")
      join_all_threads
      []
    end

    private

    def prepare_output_dir
      FileUtils.rm_rf(@output_dir)
      FileUtils.mkdir_p(@output_dir)
    rescue StandardError => e
      warn "[PipelineV2] Output dir prep failed: #{e.message}"
      raise
    end

    # Spawn a tracked thread so all threads can be joined on failure.
    def spawn_thread(label, &block)
      t = Thread.new(&block)
      t.name = "pipeline_v2_#{label}"
      @spawned_threads << t
      t
    end

    # Join all spawned threads, suppressing errors from threads that were
    # never collected. Prevents orphan threads after pipeline failure.
    def join_all_threads
      (@spawned_threads || []).each do |t|
        t.join(5) rescue nil # 5s timeout per thread
      end
    end

    def run_l1_analysis
      require 'vips'
      require 'base64'

      base = Vips::Image.new_from_file(@image_path)
      l1_buf = base.write_to_buffer('.png')
      l1_base64 = Base64.strict_encode64(l1_buf)

      l1_prompt = BattlemapV2::L1AnalysisConfig.l1_prompt(3)
      l1_schema = BattlemapV2::L1AnalysisConfig.l1_schema

      response = LLM::Adapters::GeminiAdapter.generate(
        messages: [{ role: 'user', content: [
          { type: 'image', mime_type: 'image/png', data: l1_base64 },
          { type: 'text', text: l1_prompt }
        ]}],
        model: GRID_L1_MODEL,
        api_key: AIProviderService.api_key_for('google_gemini'),
        response_schema: l1_schema,
        options: { max_tokens: 32768, timeout: 300, temperature: 0, thinking_level: 'MEDIUM' }
      )

      l1_text = response[:text] || response[:content]
      l1_text ? (JSON.parse(l1_text) rescue nil) : nil
    rescue StandardError => e
      warn "[PipelineV2] L1 analysis failed: #{e.message}"
      nil
    end

    def run_wall_door_recolor(has_inner_walls)
      svc = WallDoorService.new(image_path: @image_path, output_dir: @output_dir)
      svc.recolor_walls(has_inner_walls: has_inner_walls)
    rescue StandardError => e
      warn "[PipelineV2] Wall/door recolor failed: #{e.message}"
      nil
    end

    def run_depth_estimation
      return nil unless ReplicateDepthService.available?
      ReplicateDepthService.estimate(@image_path)
    rescue StandardError => e
      warn "[PipelineV2] Depth estimation failed: #{e.message}"
      nil
    end

    def collect_depth_result(thread)
      result = thread&.value
      return nil unless result&.dig(:success) && result[:depth_path] && File.exist?(result[:depth_path])

      # Copy to output dir for debug artifacts
      dest = File.join(@output_dir, 'depth_map.png')
      FileUtils.cp(result[:depth_path], dest)
      warn "[PipelineV2] Depth map available: #{dest}"
      result[:depth_path]
    rescue StandardError => e
      warn "[PipelineV2] Depth result collection failed: #{e.message}"
      nil
    end

    def save_debug_artifacts(l1_data, per_object_results, wall_door_result,
                             grounded_raw: [], hex_svc: nil, hex_data: [])
      debug_dir = File.join('public', 'uploads', 'battle_map_debug', "room_#{@room.id}")
      FileUtils.rm_rf(debug_dir)
      FileUtils.mkdir_p(debug_dir)

      # Persist debug artifacts for the inspect page.
      # First stabilise @image_path: copy to debug_dir so downstream visualizations
      # are unaffected if the original temp file is cleaned up.
      debug_copy = File.join(debug_dir, '03_processed_battlemap.png')
      FileUtils.cp(@image_path, debug_copy) rescue nil
      if File.exist?(debug_copy)
        @image_path = debug_copy
        hex_svc&.instance_variable_set(:@image_path, debug_copy)
      end

      depth = File.join(@output_dir, 'depth_map.png')
      FileUtils.cp(depth, File.join(debug_dir, 'depth_map.png')) if File.exist?(depth)

      depth_elev = File.join(@output_dir, 'depth_elevation.png')
      FileUtils.cp(depth_elev, File.join(debug_dir, 'depth_elevation.png')) if File.exist?(depth_elev)

      elev_json = File.join(@output_dir, 'elevation_results.json')
      FileUtils.cp(elev_json, File.join(debug_dir, 'elevation_results.json')) if File.exist?(elev_json)

      colormap = File.join(@output_dir, 'gemini_colormap_raw.png')
      FileUtils.cp(colormap, File.join(debug_dir, 'wall_gemini_colormap.png')) if File.exist?(colormap)

      wall_mask = wall_door_result[:wall_mask_path]
      FileUtils.cp(wall_mask, File.join(debug_dir, 'wall_pixel_mask.png')) if wall_mask && File.exist?(wall_mask)

      per_object_results.each do |type_name, info|
        mask_path = info[:mask_path]
        next unless mask_path && File.exist?(mask_path)
        safe_name = type_name.gsub(/[^a-z0-9_]/, '_').gsub(/_+/, '_').slice(0, 40)
        FileUtils.cp(mask_path, File.join(debug_dir, "sam_#{safe_name}.png")) rescue nil
      end

      grounded_raw.each do |detection|
        mask_path = detection[:mask_path]
        next unless mask_path && File.exist?(mask_path)
        safe = (detection[:label] || 'unknown').to_s.gsub(/[^a-z0-9_]/, '_').slice(0, 40)
        conf = (detection[:confidence].to_f * 100).round(0)
        FileUtils.cp(mask_path, File.join(debug_dir, "grounded_#{safe}_#{conf}pct.png")) rescue nil
      end

      Dir.glob(File.join(@output_dir, '*_lang.png')).each do |path|
        basename = File.basename(path, '.png').sub(/\A\d+_/, '').sub(/_lang\z/, '')
        FileUtils.cp(path, File.join(debug_dir, "lang_sam_#{basename}.png")) rescue nil
      end

      # Generate SAM composite overlay image
      generate_sam_composite(per_object_results, debug_dir)

      # Generate hex grid, classified-hex, and hex+objects visualizations
      hex_svc&.generate_debug_images(hex_data || [], output_dir: debug_dir,
                                     object_masks: per_object_results)

      # Copy wall/door gap detection data and generate gap visualization
      results_json = File.join(@output_dir, 'results.json')
      if File.exist?(results_json)
        FileUtils.cp(results_json, File.join(debug_dir, 'wall_gaps_data.json'))
        generate_wall_gaps_image(results_json, wall_door_result[:wall_mask_path], debug_dir)
      end

      # Merge V2 metadata into inspection.json (generator writes :room key after this)
      meta_path = File.join(debug_dir, 'inspection.json')
      existing = File.exist?(meta_path) ? (JSON.parse(File.read(meta_path)) rescue {}) : {}
      v2_meta = {
        'timing' => @timing,
        'l1' => {
          'scene_description'    => l1_data['scene_description'],
          'has_perimeter_wall'   => l1_data['has_perimeter_wall'],
          'has_inner_walls'      => l1_data['has_inner_walls'],
          'perimeter_wall_doors' => l1_data['perimeter_wall_doors'] || [],
          'internal_walls'       => l1_data['internal_walls'] || [],
          'wall_visual'          => l1_data['wall_visual'],
          'floor_visual'         => l1_data['floor_visual'],
          'lighting_direction'   => l1_data['lighting_direction'],
          'standard_types'       => (l1_data['standard_types_present'] || []).map { |t|
            {
              'type_name'           => t['type_name'],
              'visual_description'  => t['visual_description'],
              'short_description'   => t['short_description']
            }
          },
          'custom_types'         => (l1_data['custom_types'] || []).map { |t|
            {
              'type_name'            => t['type_name'],
              'visual_description'   => t['visual_description'],
              'short_description'    => t['short_description'],
              'provides_cover'       => t['provides_cover']       || false,
              'provides_concealment' => t['provides_concealment'] || false,
              'difficult_terrain'    => t['difficult_terrain']    || false,
              'elevation'            => t['elevation']            || 0,
              'is_exit'              => t['is_exit']              || false,
              'hazards'              => t['hazards']              || []
            }
          },
          'light_sources'        => l1_data['light_sources'] || []
        },
        'sam_results' => per_object_results.transform_values do |info|
          { 'coverage' => info[:coverage], 'method' => (info[:model] || info[:method])&.to_s, 'found' => !info[:mask_path].nil? }
        end,
        'sam_grounded' => grounded_raw.map do |d|
          { 'label' => d[:label], 'confidence' => d[:confidence], 'coverage' => d[:coverage] }
        end
      }
      File.write(meta_path, JSON.pretty_generate(existing.merge(v2_meta)))
    rescue StandardError => e
      warn "[PipelineV2] save_debug_artifacts failed: #{e.message}"
    end

    def generate_wall_gaps_image(results_json_path, wall_mask_path, debug_dir)
      require 'open3'
      data = JSON.parse(File.read(results_json_path)) rescue {}
      outer_gaps = data['outer_gaps'] || []
      inner_gaps = data['inner_gaps'] || []
      all_gaps = outer_gaps.map { |g| g.merge('kind' => 'outer') } +
                 inner_gaps.map { |g| g.merge('kind' => 'inner') }

      bg = wall_mask_path && File.exist?(wall_mask_path) ? wall_mask_path : @image_path
      out_path = File.join(debug_dir, 'wall_gaps.png')
      Open3.capture3('python3', WALL_GAPS_SCRIPT, bg, all_gaps.to_json, out_path)
    rescue StandardError => e
      warn "[PipelineV2] Wall gaps image failed: #{e.message}"
    end

    def generate_sam_composite(object_results, debug_dir)
      require 'open3'
      mask_paths = {}
      object_results.each do |type_name, info|
        mp = info[:mask_path]
        mask_paths[type_name] = mp if mp && File.exist?(mp)
      end
      return if mask_paths.empty?

      colors = [
        [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
        [255, 0, 255], [0, 255, 255], [255, 128, 0], [128, 0, 255],
        [0, 255, 128], [255, 0, 128], [128, 255, 0], [0, 128, 255]
      ]
      out_path = File.join(debug_dir, 'sam_composite.png')
      Open3.capture3('python3', SAM_COMPOSITE_SCRIPT, @image_path,
                     mask_paths.to_json, colors.to_json, out_path)

      # Model-colored composite: green=SAM2G, yellow=Lang-SAM, cyan=SAM2Grounded
      model_map = {}
      object_results.each do |type_name, info|
        mp = info[:mask_path]
        next unless mp && File.exist?(mp)
        model_map[type_name] = { 'mask' => mp, 'model' => (info[:model] || :none).to_s }
      end
      return if model_map.empty?

      model_out_path = File.join(debug_dir, 'sam_model_composite.png')
      Open3.capture3('python3', SAM_MODEL_COMPOSITE_SCRIPT, @image_path,
                     model_map.to_json, model_out_path)
    rescue StandardError => e
      warn "[PipelineV2] SAM composite generation failed: #{e.message}"
    end

    def start_effect_mask_threads(all_types, light_sources, sam_svc)
      threads = {}
      return threads unless AIProviderService.api_key_for('replicate')

      sam_window_types = %w[glass_window window]
      sam_water_types = %w[water puddle wading_water deep_water stream river pond lake]
      sam_foliage_types = %w[shrubbery bush tree treetrunk treebranch hedge vine]
      sam_fire_types = %w[fire campfire torch brazier]

      room_id = @room.id

      if (all_types & sam_window_types).any?
        threads['window'] = spawn_thread('effect_window') do
          sam_svc.segment_object('window', room_id: room_id)
        end
      end

      if (all_types & sam_water_types).any?
        threads['water'] = spawn_thread('effect_water') do
          sam_svc.segment_object('water', room_id: room_id, max_coverage: 0.40)
        end
      end

      if (all_types & sam_foliage_types).any?
        threads['foliage_tree'] = spawn_thread('effect_foliage_tree') do
          sam_svc.segment_object('tree', room_id: room_id)
        end
        threads['foliage_bush'] = spawn_thread('effect_foliage_bush') do
          sam_svc.segment_object('bush', room_id: room_id)
        end
      end

      if (all_types & sam_fire_types).any?
        threads['fire'] = spawn_thread('effect_fire') do
          # Include torch flames so wall torches can drive fire animation masks.
          result = sam_svc.segment_object('hearth fire or torch flame', room_id: room_id)
          threshold_fire_mask(result[:mask_path]) if result[:mask_path] && File.exist?(result[:mask_path])
          result
        end
      end

      sam_light_fallbacks = {
        'fire' => 'hearth fire', 'torch' => 'torch', 'candle' => 'candle',
        'gaslamp' => 'oil lantern', 'electric_light' => 'spotlight', 'magical_light' => 'glowing crystal'
      }
      seen = {}
      light_sources.each do |ls|
        stype = ls['source_type']
        query = ls['short_description'] || sam_light_fallbacks[stype] || stype
        next if seen[query]
        seen[query] = true
        threads["light_#{stype}"] = spawn_thread("effect_light_#{stype}") do
          sam_svc.segment_object(query, room_id: room_id)
        end
      end

      threads
    end

    def threshold_fire_mask(path)
      require 'vips'
      img = Vips::Image.new_from_file(path)
      binary = (img > 200).ifthenelse(255, 0).cast(:uchar)
      coverage = binary.avg / 255.0
      if coverage > 0.20
        warn "[PipelineV2] Fire mask rejected: #{(coverage * 100).round(1)}% coverage"
        FileUtils.rm_f(path)
      else
        # Write to buffer before writing to disk — avoids VIPS lazy-load conflict
        # where pngsave truncates the output file before finishing decoding the same input path.
        File.binwrite(path, binary.write_to_buffer('.png'))
      end
    rescue StandardError => e
      warn "[PipelineV2] Fire mask threshold failed: #{e.message}"
    end

    def find_window_mask(effect_threads)
      thread = effect_threads['window']
      return nil unless thread
      result = thread.value
      result[:mask_path] if result&.dig(:mask_path) && File.exist?(result[:mask_path])
    rescue StandardError => e
      warn "[PipelineV2] Window mask thread failed for room #{@room&.id}: #{e.message}"
      nil
    end

    def merge_generic_into_per_object(per_object, high_conf)
      return unless high_conf
      high_conf.each do |detection|
        label = detection[:label]
        next if per_object.key?(label) && per_object[label][:mask_path]
        per_object[label] = detection
      end
    end

    def build_combined_object_mask(object_results)
      require 'vips'
      masks = object_results.values.filter_map do |r|
        path = r[:mask_path] || r['mask_path']
        path if path && File.exist?(path)
      end
      return nil if masks.empty?

      combined = Vips::Image.new_from_file(masks.first)
      masks[1..].each do |path|
        other = Vips::Image.new_from_file(path)
        if other.width != combined.width || other.height != combined.height
          other = other.resize(combined.width.to_f / other.width,
                               vscale: combined.height.to_f / other.height)
        end
        combined = (combined | other)
      end

      out_path = File.join(@output_dir, 'combined_objects.png')
      combined.pngsave(out_path)
      out_path
    rescue StandardError => e
      warn "[PipelineV2] Combined object mask failed: #{e.message}"
      nil
    end

    def persist_wall_mask(wall_door_result)
      return unless wall_door_result[:wall_mask_path]

      dest_dir = "public/uploads/battle_maps"
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, "room_#{@room.id}_wall_mask.png")
      FileUtils.cp(wall_door_result[:wall_mask_path], dest)

      url = "/uploads/battle_maps/room_#{@room.id}_wall_mask.png"
      @room.update(
        battle_map_wall_mask_url: url,
        battle_map_wall_mask_width: wall_door_result[:width],
        battle_map_wall_mask_height: wall_door_result[:height]
      )
    rescue StandardError => e
      warn "[PipelineV2] Wall mask persist failed: #{e.message}"
    end

    def persist_effect_masks(effect_threads)
      persist_effect_mask(effect_threads, 'water', :battle_map_water_mask_url, '_sam_water')

      tree_result = effect_threads['foliage_tree']&.value
      bush_result = effect_threads['foliage_bush']&.value
      foliage_path = combine_foliage_masks(tree_result, bush_result)
      if foliage_path
        dest = "public/uploads/battle_maps/room_#{@room.id}_foliage_mask.png"
        FileUtils.cp(foliage_path, dest)
        @room.update(battle_map_foliage_mask_url: "/uploads/battle_maps/room_#{@room.id}_foliage_mask.png")
      end

      persist_combined_fire_mask(effect_threads)
    rescue StandardError => e
      warn "[PipelineV2] Effect mask persist failed: #{e.message}"
    end

    # Build fire effect mask from fire/torch SAM masks so torch flames animate too.
    def persist_combined_fire_mask(effect_threads)
      require 'vips'

      candidate_keys = %w[fire light_fire light_torch]
      source_paths = candidate_keys.filter_map do |key|
        thread = effect_threads[key]
        next unless thread
        result = thread.value rescue nil
        path = result&.dig(:mask_path)
        path if path && File.exist?(path)
      end
      return if source_paths.empty?

      combined = Vips::Image.new_from_file(source_paths.first)
      combined = combined.extract_band(0) if combined.bands > 1
      source_paths[1..].each do |path|
        other = Vips::Image.new_from_file(path)
        other = other.extract_band(0) if other.bands > 1
        if other.width != combined.width || other.height != combined.height
          other = other.resize(combined.width.to_f / other.width,
                               vscale: combined.height.to_f / other.height)
        end
        combined = (combined | other)
      end

      if combined.avg > 20
        combined = (combined > 200).ifthenelse(255, 0).cast(:uchar)
      end

      coverage = combined.avg / 255.0
      if coverage > 0.20
        warn "[PipelineV2] Fire mask rejected: #{(coverage * 100).round(1)}% coverage"
        return
      end

      dest_dir = "public/uploads/battle_maps"
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, "room_#{@room.id}_sam_fire.png")
      File.binwrite(dest, combined.write_to_buffer('.png'))
      @room.update(battle_map_fire_mask_url: "/uploads/battle_maps/room_#{@room.id}_sam_fire.png")
    rescue StandardError => e
      warn "[PipelineV2] Combined fire mask persist failed: #{e.message}"
    end

    def persist_effect_mask(threads, key, column, suffix)
      thread = threads[key]
      return unless thread
      result = thread.value
      return unless result&.dig(:mask_path) && File.exist?(result[:mask_path])

      dest_dir = "public/uploads/battle_maps"
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, "room_#{@room.id}#{suffix}.png")
      FileUtils.cp(result[:mask_path], dest)
      @room.update(column => "/uploads/battle_maps/room_#{@room.id}#{suffix}.png")
    rescue StandardError => e
      warn "[PipelineV2] #{key} mask persist failed: #{e.message}"
    end

    def combine_foliage_masks(tree_result, bush_result)
      require 'vips'
      paths = [tree_result, bush_result].filter_map do |r|
        r&.dig(:mask_path) if r&.dig(:mask_path) && File.exist?(r[:mask_path])
      end
      return nil if paths.empty?
      return paths.first if paths.length == 1

      combined = Vips::Image.new_from_file(paths.first)
      other = Vips::Image.new_from_file(paths.last)
      if other.width != combined.width || other.height != combined.height
        other = other.resize(combined.width.to_f / other.width,
                             vscale: combined.height.to_f / other.height)
      end
      combined = (combined | other)
      out = File.join(@output_dir, 'foliage_combined.png')
      combined.pngsave(out)
      out
    rescue StandardError => e
      warn "[PipelineV2] Foliage combine failed: #{e.message}"
      nil
    end

    def extract_light_sources(l1_light_sources, effect_threads)
      sources = []
      l1_light_sources.each do |ls|
        stype = ls['source_type']
        next if stype.nil? || stype.to_s.strip.empty?
        thread = effect_threads["light_#{stype}"]
        next unless thread

        result = thread.value rescue nil
        next unless result&.dig(:mask_path) && File.exist?(result[:mask_path])

        require 'vips'
        mask = Vips::Image.new_from_file(result[:mask_path])
        coverage = mask.avg / 255.0
        next if coverage < 0.001

        cx, cy = light_source_anchor(ls, mask.width, mask.height)
        radius = Math.sqrt(coverage * mask.width * mask.height / Math::PI).round
        light_color = light_color_for(stype)
        light_intensity = light_intensity_for(stype)

        sources << {
          'type' => stype,
          'source_type' => stype,
          'center_x' => cx,
          'center_y' => cy,
          'radius_px' => [radius, 20].max,
          'intensity' => light_intensity,
          'color' => light_color,
          'description' => ls['description']
        }
      end

      if sources.any?
        @room.update(detected_light_sources: Sequel.pg_jsonb_wrap(JSON.parse(sources.to_json)))
      end
    rescue StandardError => e
      warn "[PipelineV2] Light source extraction failed: #{e.message}"
    end

    # Resolve a light source anchor point from L1 data.
    # Preferred: explicit x_pct/y_pct (legacy-compatible)
    # Fallback: centroid of L1 square centers (current schema)
    def light_source_anchor(ls, width, height, grid_n: 3)
      max_x = [width.to_i - 1, 0].max
      max_y = [height.to_i - 1, 0].max

      x_pct = ls['x_pct']
      y_pct = ls['y_pct']
      if !x_pct.nil? && !y_pct.nil?
        cx = (x_pct.to_f / 100.0 * width).round.clamp(0, max_x)
        cy = (y_pct.to_f / 100.0 * height).round.clamp(0, max_y)
        return [cx, cy]
      end

      squares = Array(ls['squares']).map(&:to_i).select { |sq| sq >= 1 && sq <= (grid_n * grid_n) }
      return [width.to_i / 2, height.to_i / 2] if squares.empty?

      points = squares.map do |sq|
        idx = sq - 1
        row = idx / grid_n
        col = idx % grid_n
        [
          ((col + 0.5) / grid_n.to_f) * width,
          ((row + 0.5) / grid_n.to_f) * height
        ]
      end

      cx = (points.sum { |p| p[0] } / points.length).round.clamp(0, max_x)
      cy = (points.sum { |p| p[1] } / points.length).round.clamp(0, max_y)
      [cx, cy]
    end

    def light_color_for(source_type)
      BattlemapV2::L1AnalysisConfig::LIGHT_COLORS[source_type] ||
        BattlemapV2::L1AnalysisConfig::LIGHT_COLOR_DEFAULT
    end

    def light_intensity_for(source_type)
      BattlemapV2::L1AnalysisConfig::LIGHT_INTENSITIES[source_type] ||
        BattlemapV2::L1AnalysisConfig::LIGHT_INTENSITY_DEFAULT
    end

    def run_depth_elevation_adjustment(hex_data, hex_overlay_svc, wall_mask_path)
      require 'open3'

      depth_map_path = File.join(@output_dir, 'depth_map.png')
      return unless File.exist?(depth_map_path)

      # Build hex data JSON with pixel positions and neighbors
      coord_lookup = hex_overlay_svc.coord_lookup
      enriched = hex_data.map do |hx|
        info = coord_lookup[[hx[:x], hx[:y]]]
        next nil unless info

        neighbors = HexGrid.hex_neighbors(hx[:x], hx[:y])
        {
          'x' => hx[:x], 'y' => hx[:y],
          'px' => info[:px], 'py' => info[:py],
          'hex_type' => hx[:hex_type].to_s,
          'is_stairs' => !!hx[:is_stairs],
          'is_ladder' => !!hx[:is_ladder],
          'label' => (hx[:label] || '').to_s,
          'elevation_level' => hx[:elevation_level] || 0,
          'neighbors' => neighbors
        }
      end.compact

      return if enriched.empty?

      hex_json_path = File.join(@output_dir, 'hex_data_for_elevation.json')
      File.write(hex_json_path, JSON.generate(enriched))

      # Get original image dimensions for depth map resizing
      require 'vips'
      orig = Vips::Image.new_from_file(@image_path)

      cmd = [
        'python3', DEPTH_ELEVATION_SCRIPT,
        '--depth-map', depth_map_path,
        '--hex-data', hex_json_path,
        '--output-dir', @output_dir,
        '--image-width', orig.width.to_s,
        '--image-height', orig.height.to_s
      ]
      cmd += ['--wall-mask', wall_mask_path] if wall_mask_path && File.exist?(wall_mask_path)

      stdout, stderr, status = Open3.capture3(*cmd)
      unless status&.success?
        warn "[PipelineV2] Depth elevation analysis failed (exit=#{status&.exitstatus}): #{stderr}"
        return
      end

      results_path = File.join(@output_dir, 'elevation_results.json')
      return unless File.exist?(results_path)

      results = JSON.parse(File.read(results_path))
      return if results['skipped']

      # Apply elevation overrides to hex_data
      hex_elevations = results['hex_elevations'] || {}
      hex_data.each do |hx|
        key = "#{hx[:x]},#{hx[:y]}"
        elev_info = hex_elevations[key]
        next unless elev_info

        hx[:elevation_level] = elev_info['elevation_level']
      end

      platform_count = (results['platforms'] || []).length
      anchor_count = (results['anchors_used'] || []).length
      warn "[PipelineV2] Depth elevation: #{platform_count} platforms, #{anchor_count} anchors, " \
           "k=#{results['k_chosen']}, silhouette=#{results['silhouette_score']}"
    rescue StandardError => e
      warn "[PipelineV2] Depth elevation adjustment failed: #{e.message}"
    end
  end
end
