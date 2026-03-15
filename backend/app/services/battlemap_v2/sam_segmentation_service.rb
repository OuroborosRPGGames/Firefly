# frozen_string_literal: true

require 'base64'
require 'json'
require 'open3'

module BattlemapV2
  # Handles SAM2G (primary) and Lang-SAM (fallback) segmentation for battlemap objects.
  #
  # Usage:
  #   svc = BattlemapV2::SamSegmentationService.new(image_path: path, output_dir: dir)
  #   result = svc.segment_object('dark wooden table', room_id: 155)
  #   results = svc.segment_objects_parallel(descs_hash, room_id: 155)
  #   generic = svc.segment_generic_list(%w[barrel table chair])
  class SamSegmentationService
    SAMG_MODEL = 'rehbbea/samg'
    LANG_SAM_MODEL = 'tmappdev/lang-segment-anything'
    SAM2GROUNDED_MODEL = 'rehbbea/sam2grounded'

    MIN_SAMG_COVERAGE = 0.001
    DEFAULT_MAX_COVERAGE = 0.20       # SAM2G/Lang-SAM: reject and fall back if mask covers > 20%
    GROUNDED_MAX_COVERAGE = 0.20      # SAM2Grounded: discard any detection covering > 20%
    LANG_SAM_CONF_THRESH = 210
    GENERIC_HIGH_THRESHOLD = 0.25
    SYNC_TIMEOUT = 60

    def initialize(image_path:, output_dir:)
      @image_path = image_path
      @output_dir = output_dir
      @data_uri = nil # lazy
    end

    # Segment a single object description. SAM2G primary, Lang-SAM fallback.
    # @param description [String] visual description (e.g. "dark wooden table")
    # @param room_id [Integer] for file naming
    # @param max_coverage [Float] SAM2G falls back to Lang-SAM if over this; Lang-SAM hard-rejects if over (default 0.20)
    # @return [Hash] { success:, mask_path:, coverage:, model:, rejected_coverage: }
    def segment_object(description, room_id:, max_coverage: DEFAULT_MAX_COVERAGE, type_name: nil)
      # Try SAM2G first
      samg_result = call_samg(description, room_id)
      if samg_result[:success] && samg_result[:coverage] && samg_result[:coverage] >= MIN_SAMG_COVERAGE
        if samg_result[:coverage] >= max_coverage
          warn "[SamSegmentation] SAMG '#{description}': too large (#{(samg_result[:coverage] * 100).round(1)}% > #{(max_coverage * 100).round(0)}%) — falling back to Lang-SAM"
        else
          fill_mask_holes(samg_result[:mask_path]) if samg_result[:mask_path]
          return samg_result.merge(model: :samg)
        end
      else
        warn "[SamSegmentation] SAMG '#{description}': no detection — falling back to Lang-SAM"
      end

      # Fallback to Lang-SAM using short type name (same single-word style as SAM2Grounded)
      lang_query = type_name ? type_name.tr('_', ' ') : description
      lang_result = call_lang_sam(lang_query, room_id)
      if lang_result[:success] && lang_result[:mask_path]
        if lang_result[:coverage] && lang_result[:coverage] >= max_coverage
          warn "[SamSegmentation] Lang-SAM '#{description}': rejected (#{(lang_result[:coverage] * 100).round(1)}%)"
          return { success: true, mask_path: nil, coverage: lang_result[:coverage],
                   model: :lang_sam, rejected_coverage: lang_result[:coverage] }
        end
        threshold_lang_sam_mask(lang_result[:mask_path])
        # threshold may delete a corrupt file — treat as no detection
        unless File.exist?(lang_result[:mask_path].to_s)
          return { success: true, mask_path: nil, coverage: 0.0, model: :lang_sam }
        end
        fill_mask_holes(lang_result[:mask_path])
        return lang_result.merge(model: :lang_sam)
      end

      { success: true, mask_path: nil, coverage: 0.0, model: :none }
    rescue StandardError => e
      warn "[SamSegmentation] segment_object failed for '#{description}': #{e.message}"
      { success: false, mask_path: nil, error: e.message }
    end

    # Run segment_object for multiple descriptions in parallel (max 8 concurrent).
    # @param descriptions [Hash] { type_name => visual_description }
    # @param room_id [Integer]
    # @param max_coverage [Float]
    # @return [Hash] { type_name => segment_object result }
    def segment_objects_parallel(descriptions, room_id:, max_coverage: DEFAULT_MAX_COVERAGE)
      results = {}
      mutex = Mutex.new
      threads = descriptions.map do |type_name, desc|
        Thread.new do
          result = segment_object(desc, room_id: room_id, max_coverage: max_coverage, type_name: type_name)
          mutex.synchronize { results[type_name] = result }
        end
      end
      threads.each(&:join)
      results
    end

    # Run SAM2Grounded with a comma-separated label list (generic detection).
    # Returns high-confidence and low-confidence mask sets.
    # @param labels [Array<String>] type names
    # @return [Hash] { success:, high_conf: [...], low_conf: [...] }
    def segment_generic_list(labels)
      call_sam2grounded(labels)
    rescue StandardError => e
      warn "[SamSegmentation] segment_generic_list failed: #{e.message}"
      { success: false, high_conf: [], error: e.message }
    end

    private

    def data_uri
      @data_uri ||= begin
        mime = case File.extname(@image_path).downcase
               when '.png' then 'image/png'
               when '.jpg', '.jpeg' then 'image/jpeg'
               when '.webp' then 'image/webp'
               else 'image/png'
               end
        "data:#{mime};base64,#{Base64.strict_encode64(File.binread(@image_path))}"
      end
    end

    def api_key
      @api_key ||= AIProviderService.api_key_for('replicate')
    end

    def replicate_conn
      @replicate_conn ||= build_connection
    end

    # Call rehbbea/samg with binary_mask output
    def call_samg(description, room_id)
      version = resolve_model_version(replicate_conn, SAMG_MODEL)
      url = replicate_run(replicate_conn, api_key, version,
        { image: data_uri, prompt: description, output_format: 'binary_mask' },
        "'#{description}' [samg]")

      return { success: true, mask_path: nil, coverage: 0.0 } unless url

      safe = description.gsub(/[^a-z0-9_-]/i, '_')[0, 60]
      mask_path = File.join(@output_dir, "#{room_id}_#{safe}_samg.png")
      img = download_with_retry(url, mask_path, label: "'#{description}' [samg]")
      return { success: true, mask_path: nil, coverage: 0.0 } unless img

      coverage = img.avg / 255.0
      { success: true, mask_path: mask_path, coverage: coverage }
    end

    # Call tmappdev/lang-segment-anything
    def call_lang_sam(description, room_id)
      version = resolve_model_version(replicate_conn, LANG_SAM_MODEL)
      url = replicate_run(replicate_conn, api_key, version,
        { image: data_uri, text_prompt: description },
        "'#{description}' [lang-SAM]")

      return { success: true, mask_path: nil, coverage: 0.0 } unless url

      safe = description.gsub(/[^a-z0-9_-]/i, '_')[0, 60]
      mask_path = File.join(@output_dir, "#{room_id}_#{safe}_lang.png")
      img = download_with_retry(url, mask_path, label: "'#{description}' [lang-SAM]")
      return { success: true, mask_path: nil, coverage: 0.0 } unless img

      coverage = img.avg / 255.0
      { success: true, mask_path: mask_path, coverage: coverage }
    end

    # Call rehbbea/sam2grounded with dual thresholds
    def call_sam2grounded(labels)
      version = resolve_model_version(replicate_conn, SAM2GROUNDED_MODEL)
      query = labels.map { |l| l.tr('_', ' ') }.join(', ')

      prediction = replicate_run_raw(replicate_conn, api_key, version,
        { image: data_uri, labels: query, output_format: 'json_with_masks',
          detection_threshold: GENERIC_HIGH_THRESHOLD })

      return { success: false, high_conf: [], error: 'No response' } unless prediction

      # sam2grounded with json_with_masks returns a URL to a JSON file, not inline JSON.
      # The CDN may serve a truncated response if fetched immediately after prediction succeeds.
      raw = if prediction.is_a?(String) && prediction.start_with?('http')
              fetch_json_with_retry(prediction)
            else
              prediction.is_a?(String) ? prediction : prediction.to_json
            end
      return { success: false, high_conf: [], error: 'JSON fetch failed' } unless raw
      output = JSON.parse(raw)
      high_conf = parse_grounded_masks(output['masks'] || [])

      { success: true, high_conf: high_conf }
    end

    def parse_grounded_masks(masks_array)
      masks_array.filter_map do |m|
        mask_b64 = m['mask_png']
        next unless mask_b64

        safe = (m['label'] || 'unknown').gsub(/[^a-z0-9_-]/i, '_')[0, 40]
        mask_path = File.join(@output_dir, "grounded_#{safe}_#{SecureRandom.hex(4)}.png")
        File.binwrite(mask_path, Base64.decode64(mask_b64))

        require 'vips'
        img = begin
          Vips::Image.new_from_file(mask_path)
        rescue StandardError => e
          warn "[SamSegmentation] grounded mask unreadable for '#{m['label']}': #{e.message}"
          FileUtils.rm_f(mask_path)
          next
        end
        coverage = img.avg / 255.0

        if coverage >= GROUNDED_MAX_COVERAGE
          warn "[SamSegmentation] sam2grounded '#{m['label']}': rejected (#{(coverage * 100).round(1)}% > #{(GROUNDED_MAX_COVERAGE * 100).round(0)}%)"
          FileUtils.rm_f(mask_path)
          next
        end

        { label: m['label'], confidence: m['confidence'], mask_path: mask_path, coverage: coverage,
          model: :sam2grounded }
      end
    end

    def binary_mask_coverage(path)
      return 0.0 unless path && File.exist?(path)
      require 'vips'
      img = Vips::Image.new_from_file(path)
      img.avg / 255.0
    rescue StandardError => e
      warn "[SamSegmentation] Failed to compute mask coverage for #{path}: #{e.message}"
      0.0
    end

    def threshold_lang_sam_mask(path)
      return unless path && File.exist?(path)
      require 'vips'
      img = Vips::Image.new_from_file(path)
      binary = (img > LANG_SAM_CONF_THRESH - 1).ifthenelse(255, 0).cast(:uchar)
      # Write to buffer before writing to disk — avoids VIPS lazy-load conflict
      # where pngsave truncates the output file before finishing decoding the same input path.
      buf = binary.write_to_buffer('.png')
      File.binwrite(path, buf)
    rescue StandardError => e
      warn "[SamSegmentation] Threshold failed: #{e.message}"
      FileUtils.rm_f(path)
    end

    def fill_mask_holes(path)
      return unless path && File.exist?(path)
      script = <<~PY
        import cv2, numpy as np, sys
        m = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
        if m is None: sys.exit(0)
        k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
        m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, k)
        h, w = m.shape
        flood = m.copy()
        mask = np.zeros((h+2, w+2), np.uint8)
        for seed in [(0,0), (w-1,0), (0,h-1), (w-1,h-1)]:
            if flood[seed[1], seed[0]] == 0:
                cv2.floodFill(flood, mask, seed, 255)
        interior_holes = cv2.bitwise_and(cv2.bitwise_not(flood), cv2.bitwise_not(m))
        m = cv2.bitwise_or(m, interior_holes)
        cv2.imwrite(sys.argv[1], m)
      PY
      Open3.capture3('python3', '-c', script, path)
    rescue StandardError => e
      warn "[SamSegmentation] fill_mask_holes failed: #{e.message}"
    end

    # Fetch a JSON URL with exponential backoff, retrying on parse failures.
    # Replicate CDN may not serve results immediately after prediction succeeds —
    # we add an initial settling delay before the first attempt, then retry with
    # increasing intervals to give the CDN time to propagate.
    # Returns the raw JSON string on success, nil if all attempts fail.
    def fetch_json_with_retry(url, max_attempts: 8)
      require 'open-uri'
      # Initial delay: Replicate CDN typically needs a few seconds after 'succeeded'
      sleep 4
      delays = [4, 8, 16, 30, 60, 90, 120]

      max_attempts.times do |attempt|
        if attempt > 0
          delay = delays[attempt - 1]
          warn "[SamSegmentation] sam2grounded JSON: CDN not ready (attempt #{attempt}/#{max_attempts - 1}), retrying in #{delay}s"
          sleep delay
        end
        raw = URI.parse(url).open.read
        JSON.parse(raw)  # validate it's complete
        return raw
      rescue StandardError => e
        warn "[SamSegmentation] sam2grounded JSON: attempt #{attempt + 1} failed — #{e.message}"
      end

      warn "[SamSegmentation] sam2grounded JSON: all #{max_attempts} fetch attempts failed"
      nil
    end

    # Download a Replicate output URL and validate it is VIPS-readable.
    # Replicate CDN may not propagate output files immediately after a prediction
    # shows 'succeeded' — poll with an initial settling delay then exponential
    # backoff to give the CDN enough time before giving up.
    # Returns the Vips::Image on success, nil if all attempts fail.
    def download_with_retry(url, path, max_attempts: 8, label: url)
      require 'open-uri'
      require 'vips'
      # Initial delay: Replicate CDN typically needs a few seconds after 'succeeded'
      sleep 4
      delays = [4, 8, 16, 30, 60, 90, 120]

      max_attempts.times do |attempt|
        if attempt > 0
          delay = delays[attempt - 1]
          warn "[SamSegmentation] #{label}: CDN not ready (attempt #{attempt}/#{max_attempts - 1}), retrying in #{delay}s"
          sleep delay
        end
        File.binwrite(path, URI.parse(url).open.read)
        return Vips::Image.new_from_file(path)
      rescue StandardError => e
        warn "[SamSegmentation] #{label}: download attempt #{attempt + 1} failed — #{e.message}"
      end

      warn "[SamSegmentation] #{label}: all #{max_attempts} download attempts failed"
      FileUtils.rm_f(path)
      nil
    end

    def replicate_run(conn, key, version, input, label)
      resp = conn.post('predictions') do |req|
        req.headers['Authorization'] = "Bearer #{key}"
        req.headers['Content-Type'] = 'application/json'
        req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
        req.body = { version: version, input: input }.to_json
      end
      body = resp.body.is_a?(String) ? JSON.parse(resp.body) : resp.body

      if body['status'] == 'succeeded'
        body['output']
      elsif body['status'].nil? || %w[starting processing].include?(body['status'])
        poll_prediction(conn, key, body['id'])
      else
        warn "[SamSegmentation] #{label} failed: #{body['error'] || body['status']}"
        nil
      end
    rescue StandardError => e
      warn "[SamSegmentation] #{label} error: #{e.message}"
      nil
    end

    def replicate_run_raw(conn, key, version, input)
      resp = conn.post('predictions') do |req|
        req.headers['Authorization'] = "Bearer #{key}"
        req.headers['Content-Type'] = 'application/json'
        req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
        req.body = { version: version, input: input }.to_json
      end
      body = resp.body.is_a?(String) ? JSON.parse(resp.body) : resp.body

      if body['status'] == 'succeeded'
        body['output']
      elsif body['status'].nil? || %w[starting processing].include?(body['status'])
        poll_and_return_output(conn, key, body['id'])
      else
        warn "[SamSegmentation] sam2grounded failed: #{body['error'] || body['status']}"
        nil
      end
    end

    def poll_and_return_output(conn, key, prediction_id)
      40.times do
        sleep 3
        resp = conn.get("predictions/#{prediction_id}") do |req|
          req.headers['Authorization'] = "Bearer #{key}"
        end
        body = resp.body.is_a?(String) ? JSON.parse(resp.body) : resp.body
        return body['output'] if body['status'] == 'succeeded'
        return nil if body['status'] == 'failed'
      end
      nil
    end

    def poll_prediction(conn, key, prediction_id)
      40.times do
        sleep 3
        resp = conn.get("predictions/#{prediction_id}") do |req|
          req.headers['Authorization'] = "Bearer #{key}"
        end
        body = resp.body.is_a?(String) ? JSON.parse(resp.body) : resp.body
        return body['output'] if body['status'] == 'succeeded'
        return nil if body['status'] == 'failed'
      end
      nil
    end

    def build_connection
      Faraday.new(url: 'https://api.replicate.com/v1') do |c|
        c.request :json
        c.response :json, content_type: /\bjson$/
        c.adapter Faraday.default_adapter
        c.options.timeout = 180
      end
    end

    def resolve_model_version(conn, model)
      @version_cache ||= {}
      @version_cache[model] ||= begin
        resp = conn.get("models/#{model}/versions") do |req|
          req.headers['Authorization'] = "Bearer #{api_key}"
        end
        body = resp.body.is_a?(String) ? JSON.parse(resp.body) : resp.body
        results = body['results'] || []
        results.first&.dig('id')
      end
    end
  end
end
