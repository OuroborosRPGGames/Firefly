# frozen_string_literal: true

require 'base64'
require 'json'
require 'open3'

module BattlemapV2
  # Orchestrates Gemini wall/door recoloring and Python-based pixel classification.
  #
  # Flow:
  #   1. Call Gemini image generation to recolor walls (blue) and doors (red/magenta/pink)
  #   2. Run gemini_colormap_analyze.py to classify pixels, find gaps, check connectivity
  #   3. Build RGB wall/door/window pixel mask via wall_mask_build.py
  #
  # Usage:
  #   svc = BattlemapV2::WallDoorService.new(image_path: path, output_dir: dir)
  #   results = svc.analyze(has_inner_walls: true)
  #   mask = svc.build_pixel_mask(has_inner_walls: true, window_mask_path: win_path)
  class WallDoorService
    # __dir__ = backend/app/services/battlemap_v2 → ../../../ = backend/
    COLORMAP_SCRIPT = File.expand_path('../../../lib/cv/gemini_colormap_analyze.py', __dir__)
    MASK_BUILD_SCRIPT = File.expand_path('../../../lib/cv/wall_mask_build.py', __dir__)
    GEMINI_IMAGE_MODEL = 'gemini-3.1-flash-image-preview'
    GEMINI_BASE_URL = 'https://generativelanguage.googleapis.com/v1beta'

    def initialize(image_path:, output_dir:, colormap_path: nil, depth_map_path: nil)
      @image_path = image_path
      @output_dir = output_dir
      @colormap_path = colormap_path
      @depth_map_path = depth_map_path
      @analysis_results = nil
    end

    # Recolor walls/doors via Gemini image generation.
    # @param has_inner_walls [Boolean]
    # @return [String, nil] path to recolored image, or nil on failure
    def recolor_walls(has_inner_walls:)
      @colormap_path = call_gemini_recolor(has_inner_walls)
    end

    # Run full analysis: recolor + classify + gaps + connectivity.
    # @param has_inner_walls [Boolean]
    # @param object_mask_path [String, nil] combined object mask for connectivity
    # @return [Hash] parsed results.json from Python
    def analyze(has_inner_walls:, object_mask_path: nil)
      recolor_walls(has_inner_walls: has_inner_walls) unless @colormap_path
      return { 'error' => 'Recoloring failed' } unless @colormap_path

      @analysis_results = run_python_analysis(has_inner_walls, object_mask_path)
    end

    # Build the RGB pixel mask (red=wall, green=door, blue=window).
    # @param has_inner_walls [Boolean]
    # @param window_mask_path [String, nil]
    # @param object_mask_path [String, nil]
    # @return [Hash] { wall_mask_path:, width:, height:, analysis: }
    def build_pixel_mask(has_inner_walls:, window_mask_path: nil, object_mask_path: nil)
      analyze(has_inner_walls: has_inner_walls, object_mask_path: object_mask_path) unless @analysis_results

      mask_path = run_mask_build(window_mask_path)
      return { wall_mask_path: nil, error: 'Mask build failed' } unless mask_path

      require 'vips'
      img = Vips::Image.new_from_file(mask_path)

      {
        wall_mask_path: mask_path,
        width: img.width,
        height: img.height,
        analysis: @analysis_results
      }
    end

    attr_reader :analysis_results, :colormap_path

    private

    def call_gemini_recolor(has_inner_walls)
      api_key = AIProviderService.api_key_for('google_gemini')
      return nil unless api_key

      prompt_key = has_inner_walls ? 'battlemap.wall_door_recolor.with_inner_walls' : 'battlemap.wall_door_recolor.outer_only'
      prompt = GamePrompts.get(prompt_key)
      return nil unless prompt

      img_b64 = Base64.strict_encode64(File.binread(@image_path))
      conn = Faraday.new do |c|
        c.request :json
        c.response :json, content_type: /\bjson$/
        c.adapter Faraday.default_adapter
        c.options.timeout = 120
      end

      endpoint = "#{GEMINI_BASE_URL}/models/#{GEMINI_IMAGE_MODEL}:generateContent?key=#{api_key}"
      body = {
        contents: [{
          parts: [
            { inlineData: { mimeType: 'image/png', data: img_b64 } },
            { text: prompt }
          ]
        }],
        generationConfig: { responseModalities: %w[TEXT IMAGE], temperature: 0.0 }
      }

      resp = conn.post(endpoint, body)
      return nil unless resp.success?

      parts = resp.body.dig('candidates', 0, 'content', 'parts') || []
      img_part = parts.find do |p|
        (p.dig('inlineData', 'mimeType') || p.dig('inline_data', 'mimeType') || '').start_with?('image/')
      end
      return nil unless img_part

      inline = img_part['inlineData'] || img_part['inline_data']
      colormap_path = File.join(@output_dir, 'gemini_colormap_raw.png')
      File.binwrite(colormap_path, Base64.decode64(inline['data']))

      warn "[WallDoorService] Gemini recolor complete: #{colormap_path}"
      colormap_path
    rescue StandardError => e
      warn "[WallDoorService] Gemini recolor failed: #{e.message}"
      nil
    end

    def run_python_analysis(has_inner_walls, object_mask_path)
      cmd = [
        'python3', COLORMAP_SCRIPT,
        '--original', @image_path,
        '--colormap', @colormap_path,
        '--output-dir', @output_dir,
        '--has-inner-walls', has_inner_walls ? '1' : '0'
      ]
      cmd += ['--depth-map', @depth_map_path] if @depth_map_path && File.exist?(@depth_map_path)
      cmd += ['--object-mask', object_mask_path] if object_mask_path && File.exist?(object_mask_path)

      stdout, stderr, status = Open3.capture3(*cmd)
      unless status&.success?
        warn "[WallDoorService] Python analysis failed (exit=#{status&.exitstatus}): #{stderr}"
        return { 'error' => stderr }
      end

      results_path = File.join(@output_dir, 'results.json')
      if File.exist?(results_path)
        JSON.parse(File.read(results_path))
      else
        warn "[WallDoorService] No results.json produced"
        { 'error' => 'No results.json' }
      end
    rescue StandardError => e
      warn "[WallDoorService] Python analysis error: #{e.message}"
      { 'error' => e.message }
    end

    def run_mask_build(window_mask_path)
      cmd = [
        'python3', MASK_BUILD_SCRIPT,
        '--input-dir', @output_dir,
        '--output', File.join(@output_dir, 'wall_mask.png')
      ]
      cmd += ['--window-mask', window_mask_path] if window_mask_path && File.exist?(window_mask_path)

      stdout, stderr, status = Open3.capture3(*cmd)
      unless status&.success?
        warn "[WallDoorService] Mask build failed (exit=#{status&.exitstatus}): #{stderr}"
        return nil
      end

      output_path = File.join(@output_dir, 'wall_mask.png')
      File.exist?(output_path) ? output_path : nil
    rescue StandardError => e
      warn "[WallDoorService] Mask build error: #{e.message}"
      nil
    end
  end
end
