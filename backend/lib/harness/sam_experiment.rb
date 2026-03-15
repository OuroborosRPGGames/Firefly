#!/usr/bin/env ruby
# frozen_string_literal: true

# SAM Model Comparison Experiment
# ================================
# Compares rehbbea/sam_autolabel, rehbbea/samg, and our existing
# tmappdev/lang-segment-anything for battlemap segmentation quality.
#
# Usage:
#   cd backend
#   bundle exec ruby lib/harness/sam_experiment.rb
#
# Output: lib/harness/sam_experiment/index.html

$stdout.sync = true
require 'fileutils'
require 'base64'
require 'json'
require 'faraday'
require 'open-uri'

# Boot the application
require_relative '../../config/room_type_config'
Dir[File.join(__dir__, '../../app/lib/*.rb')].each { |f| require f }
require_relative '../../config/application'

class SamExperiment
  ROOM_IDS = [155, 2200, 2201, 2202, 2203, 2204, 2208, 2209, 2212].freeze
  QUERIES = %w[wall door window table chair barrel fireplace stairs water tree].freeze

  AUTOLABEL_MODEL    = 'rehbbea/sam_autolabel'
  SAMG_MODEL         = 'rehbbea/samg'
  SAM2GROUNDED_MODEL = 'rehbbea/sam2grounded'
  EXISTING_MODEL     = 'tmappdev/lang-segment-anything'

  SYNC_TIMEOUT = 60
  POLL_INTERVAL = 5
  MAX_POLL_ATTEMPTS = 60
  MAX_THREADS = 4

  OUT_DIR = File.join(__dir__, 'sam_experiment')

  def initialize
    @results = {} # room_id => { autolabel:, samg:, existing:, pipeline: }
    @rc = ReplicateDepthService # proxy for ReplicateClientHelper
    @api_key = @rc.send(:replicate_api_key)
    raise 'Replicate API key not configured' unless @api_key && !@api_key.empty?

    @conn = @rc.send(:build_connection, @api_key, timeout: 300)
    @versions = {}
    @conn_mutex = Mutex.new
    @log_mutex = Mutex.new
  end

  def run(described_only: false)
    log "SAM Model Comparison Experiment#{described_only ? ' [described-only mode]' : ''}"
    log "=" * 50

    # Pre-resolve model versions (only need samg for described-only)
    log "\nResolving model versions..."
    models = described_only ? [SAMG_MODEL] : [AUTOLABEL_MODEL, SAMG_MODEL, SAM2GROUNDED_MODEL, EXISTING_MODEL]
    models.each do |model|
      @versions[model] = @rc.send(:resolve_model_version, @conn, model)
      if @versions[model]
        log "  #{model}: #{@versions[model][0..7]}..."
      else
        log "  #{model}: FAILED to resolve"
      end
    end

    unless described_only
      log "\nDownloading battle map images..."
      download_input_images
    end

    ROOM_IDS.each do |room_id|
      room_dir = File.join(OUT_DIR, "room_#{room_id}")
      input_path = File.join(room_dir, 'input.png')
      unless File.exist?(input_path)
        log "  Skipping room #{room_id} — no input image"
        next
      end

      @results[room_id] = { autolabel: nil, samg: {}, sam2grounded: {}, existing: {}, pipeline: {}, described: {} }

      if described_only
        # Load cached data for HTML rendering without re-calling APIs
        load_cached_results(room_id)
      else
        run_autolabel(room_id, input_path)
        run_head_to_head(room_id, input_path)
        run_pipeline(room_id, input_path)
      end

      run_described_queries(room_id, input_path)
    end

    generate_html
    log "\nDone! Open #{OUT_DIR}/index.html"
  end

  private

  def log(msg)
    @log_mutex.synchronize { puts msg }
  end

  def download_input_images
    ROOM_IDS.each do |room_id|
      room_dir = File.join(OUT_DIR, "room_#{room_id}")
      FileUtils.mkdir_p(room_dir)
      input_path = File.join(room_dir, 'input.png')

      if File.exist?(input_path) && File.size(input_path) > 1000
        log "  Room #{room_id}: already downloaded"
        next
      end

      room = Room[room_id]
      unless room
        log "  Room #{room_id}: not found in database"
        next
      end

      url = room.battle_map_image_url
      unless url && !url.empty?
        log "  Room #{room_id}: no battle_map_image_url"
        next
      end

      log "  Room #{room_id}: copying from #{url}..."
      src = resolve_image_url(url)
      unless src && File.exist?(src)
        log "  Room #{room_id}: file not found at #{src}"
        next
      end
      FileUtils.cp(src, input_path)
      log "  Room #{room_id}: #{(File.size(input_path) / 1024.0).round}KB"
    end
  end

  # Load existing cached results into @results for HTML rendering (no API calls)
  def load_cached_results(room_id)
    room_dir = File.join(OUT_DIR, "room_#{room_id}")

    # AutoLabel
    json_path = File.join(room_dir, 'autolabel.json')
    @results[room_id][:autolabel] = JSON.parse(File.read(json_path)) if File.exist?(json_path)

    # Head-to-head: just check for files
    QUERIES.each do |query|
      overlay = File.join(room_dir, "samg_#{query}_overlay.png")
      @results[room_id][:samg][query] = { overlay: overlay } if File.exist?(overlay)

      overlay2 = File.join(room_dir, "sam2grounded_#{query}.png")
      @results[room_id][:sam2grounded][query] = { overlay: overlay2 } if File.exist?(overlay2)

      mask = File.join(room_dir, "existing_#{query}.png")
      @results[room_id][:existing][query] = File.exist?(mask) ? { mask: mask } : { no_detections: true }
    end

    # Pipeline
    labels_path = File.join(room_dir, 'pipeline_labels.json')
    if File.exist?(labels_path)
      JSON.parse(File.read(labels_path)).each do |label|
        safe_name = label.gsub(/[^a-z0-9_-]/i, '_')[0..40]
        overlay = File.join(room_dir, "pipeline_#{safe_name}_overlay.png")
        @results[room_id][:pipeline][label] = { overlay: overlay } if File.exist?(overlay)
      end
    end
  end

  def image_data_uri(path)
    mime = @rc.send(:detect_mime_type, path)
    "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
  end

  # ─── Part 1: AutoLabel ───

  def run_autolabel(room_id, input_path)
    room_dir = File.join(OUT_DIR, "room_#{room_id}")
    json_path = File.join(room_dir, 'autolabel.json')

    if File.exist?(json_path)
      log "\n[Room #{room_id}] AutoLabel: loading cached result"
      @results[room_id][:autolabel] = JSON.parse(File.read(json_path))
      return
    end

    version = @versions[AUTOLABEL_MODEL]
    unless version
      log "\n[Room #{room_id}] AutoLabel: model not available"
      return
    end

    log "\n[Room #{room_id}] AutoLabel: running..."
    t0 = Time.now

    result = run_prediction(
      version: version,
      input: { image: image_data_uri(input_path), pipeline: 'both' }
    )

    if result
      # Download annotated image if present
      annotated_url = result['annotated_image']
      if annotated_url
        data = download_url(annotated_url)
        File.binwrite(File.join(room_dir, 'autolabel_annotated.jpg'), data) if data
      end
      File.write(json_path, JSON.pretty_generate(result))
      @results[room_id][:autolabel] = result
      log "  AutoLabel done (#{(Time.now - t0).round(1)}s) — #{extract_labels(result).size} labels"
    else
      log "  AutoLabel failed"
    end
  end

  # ─── Part 2: Head-to-Head ───

  def run_head_to_head(room_id, input_path)
    room_dir = File.join(OUT_DIR, "room_#{room_id}")
    data_uri = image_data_uri(input_path)

    log "\n[Room #{room_id}] Head-to-head comparison..."
    t0 = Time.now

    queue = Queue.new
    QUERIES.each { |q| queue << q }

    threads = Array.new([MAX_THREADS, QUERIES.size].min) do
      Thread.new do
        loop do
          query = begin; queue.pop(true); rescue ThreadError; break; end

          # SAMG
          samg_result = run_samg_query(room_id, room_dir, data_uri, query)
          @results[room_id][:samg][query] = samg_result

          # SAM2Grounded
          sam2g_result = run_sam2grounded_query(room_id, room_dir, data_uri, query)
          @results[room_id][:sam2grounded][query] = sam2g_result

          # Existing SAM
          existing_result = run_existing_sam(room_id, room_dir, input_path, query)
          @results[room_id][:existing][query] = existing_result

          log "  [#{room_id}] #{query}: samg=#{samg_result ? 'ok' : 'fail'} sam2grounded=#{sam2g_result ? 'ok' : 'fail'} existing=#{existing_result ? 'ok' : 'fail'}"
        end
      end
    end
    threads.each(&:join)

    log "  Head-to-head done (#{(Time.now - t0).round(1)}s)"
  end

  def run_samg_query(room_id, room_dir, data_uri, query)
    # Check for cached overlay
    overlay_path = File.join(room_dir, "samg_#{query}_overlay.png")
    json_path = File.join(room_dir, "samg_#{query}.json")
    return { overlay: overlay_path, meta: JSON.parse(File.read(json_path)) } if File.exist?(overlay_path) && File.exist?(json_path)

    version = @versions[SAMG_MODEL]
    return nil unless version

    # Get colored overlay
    overlay_result = run_prediction(
      version: version,
      input: { image: data_uri, prompt: query, output_format: 'colored_overlay' }
    )

    # Get JSON metadata
    json_result = run_prediction(
      version: version,
      input: { image: data_uri, prompt: query, output_format: 'json' }
    )

    result = {}

    if overlay_result
      # overlay_result should be a URL string
      url = extract_output_url(overlay_result)
      if url
        data = download_url(url)
        if data
          File.binwrite(overlay_path, data)
          result[:overlay] = overlay_path
        end
      end
    end

    if json_result
      meta = extract_json_output(json_result)
      if meta
        File.write(json_path, JSON.pretty_generate(meta))
        result[:meta] = meta
      end
    end

    result.empty? ? nil : result
  rescue StandardError => e
    log "    samg #{query} error: #{e.message}"
    nil
  end

  def run_sam2grounded_query(_room_id, room_dir, data_uri, query)
    overlay_path = File.join(room_dir, "sam2grounded_#{query}.png")
    return { overlay: overlay_path } if File.exist?(overlay_path)

    version = @versions[SAM2GROUNDED_MODEL]
    return nil unless version

    result = run_prediction(
      version: version,
      input: { image: data_uri, prompt: query }
    )
    return nil unless result

    url = extract_output_url(result)
    return nil unless url

    data = download_url(url)
    return nil unless data

    File.binwrite(overlay_path, data)
    { overlay: overlay_path }
  rescue StandardError => e
    log "    sam2grounded #{query} error: #{e.message}"
    nil
  end

  def run_existing_sam(room_id, room_dir, input_path, query)
    mask_path = File.join(room_dir, "existing_#{query}.png")
    return { mask: mask_path } if File.exist?(mask_path)

    result = ReplicateSamService.segment_with_samg_fallback(input_path, query, suffix: "_existing_#{query}")
    if result[:success] && result[:mask_path]
      # Move to our directory
      FileUtils.cp(result[:mask_path], mask_path)
      File.delete(result[:mask_path]) if result[:mask_path] != mask_path
      { mask: mask_path }
    elsif result[:no_detections]
      { no_detections: true }
    else
      nil
    end
  rescue StandardError => e
    log "    existing SAM #{query} error: #{e.message}"
    nil
  end

  # ─── Part 3: AutoLabel → SAMG Pipeline ───

  def run_pipeline(room_id, input_path)
    autolabel = @results[room_id][:autolabel]
    unless autolabel
      log "\n[Room #{room_id}] Pipeline: skipping (no autolabel results)"
      return
    end

    room_dir = File.join(OUT_DIR, "room_#{room_id}")
    data_uri = image_data_uri(input_path)

    # Extract labels from autolabel output
    labels = extract_labels(autolabel)
    log "\n[Room #{room_id}] Pipeline: #{labels.size} labels discovered"
    labels.each { |l| log "    - #{l}" }

    # Save labels
    File.write(File.join(room_dir, 'pipeline_labels.json'), JSON.pretty_generate(labels))

    # Run SAMG for each label (parallel)
    t0 = Time.now
    queue = Queue.new
    labels.each { |l| queue << l }

    threads = Array.new([MAX_THREADS, labels.size].min) do
      Thread.new do
        loop do
          label = begin; queue.pop(true); rescue ThreadError; break; end
          begin
            safe_name = label.gsub(/[^a-z0-9_-]/i, '_')[0..40]
            overlay_path = File.join(room_dir, "pipeline_#{safe_name}_overlay.png")

            if File.exist?(overlay_path)
              @results[room_id][:pipeline][label] = { overlay: overlay_path }
              next
            end

            version = @versions[SAMG_MODEL]
            next unless version

            result = run_prediction(
              version: version,
              input: { image: data_uri, prompt: label, output_format: 'colored_overlay' }
            )

            if result
              url = extract_output_url(result)
              if url
                data = download_url(url)
                if data
                  File.binwrite(overlay_path, data)
                  @results[room_id][:pipeline][label] = { overlay: overlay_path }
                  log "    [#{room_id}] pipeline '#{label}': ok"
                end
              end
            end
          rescue StandardError => e
            log "    [#{room_id}] pipeline '#{label}' error: #{e.message}"
          end
        end
      end
    end
    threads.each(&:join)
    log "  Pipeline done (#{(Time.now - t0).round(1)}s)"
  end

  # ─── Part 4: Gemini-described queries → SAMG ───

  DESCRIBED_TARGETS = %w[wall door].freeze

  def run_described_queries(room_id, input_path)
    room_dir = File.join(OUT_DIR, "room_#{room_id}")
    desc_path = File.join(room_dir, 'gemini_descriptions.json')

    descriptions = if File.exist?(desc_path)
                     log "\n[Room #{room_id}] Described queries: loading cached descriptions"
                     JSON.parse(File.read(desc_path))
                   else
                     log "\n[Room #{room_id}] Described queries: asking Gemini..."
                     d = ask_gemini_for_descriptions(input_path)
                     if d
                       File.write(desc_path, JSON.pretty_generate(d))
                       d
                     else
                       log "  Gemini description failed"
                       return
                     end
                   end

    log "  Descriptions: #{descriptions.inspect}"

    data_uri = image_data_uri(input_path)
    version  = @versions[SAMG_MODEL]
    return unless version

    DESCRIBED_TARGETS.each do |target|
      desc = descriptions[target]
      next unless desc && !desc.empty?

      overlay_path = File.join(room_dir, "described_#{target}_overlay.png")

      if File.exist?(overlay_path)
        @results[room_id][:described][target] = { description: desc, overlay: overlay_path }
        log "  [#{room_id}] described #{target}: cached"
        next
      end

      result = run_prediction(version: version, input: { image: data_uri, prompt: desc, output_format: 'colored_overlay' })
      if result
        url  = extract_output_url(result)
        data = download_url(url) if url
        if data
          File.binwrite(overlay_path, data)
          @results[room_id][:described][target] = { description: desc, overlay: overlay_path }
          log "  [#{room_id}] described #{target} ('#{desc}'): ok"
        end
      end
    rescue StandardError => e
      log "  [#{room_id}] described #{target} error: #{e.message}"
    end
  end

  def ask_gemini_for_descriptions(image_path)
    api_key = AIProviderService.api_key_for('google_gemini')
    return nil unless api_key

    image = Vips::Image.new_from_file(image_path)
    scale = 512.0 / [image.width, image.height].max
    small = scale < 1.0 ? image.resize(scale) : image
    image_data = Base64.strict_encode64(small.write_to_buffer('.jpg', Q: 70))

    prompt = <<~PROMPT
      Look at this top-down RPG battle map image. Describe in a few words what the walls and doors look like visually, as if you were going to use those descriptions to search for them in the image.

      Be specific and visual — describe colour, material, texture (e.g. "rough stone brick walls", "heavy wooden doors with iron hinges", "mossy dungeon walls").

      Respond with JSON only:
      { "wall": "...", "door": "..." }
    PROMPT

    response = LLM::Adapters::GeminiAdapter.generate(
      messages: [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/jpeg', data: image_data },
        { type: 'text', text: prompt }
      ]}],
      model: 'gemini-3.1-flash-lite-preview',
      api_key: api_key,
      options: { max_tokens: 100, timeout: 15, temperature: 0 },
      json_mode: true
    )

    text = response[:text].to_s.strip
    text = text.sub(/\A```(?:json)?\s*\n?/, '').sub(/\n?\s*```\z/, '')
    JSON.parse(text)
  rescue StandardError => e
    warn "  [Gemini descriptions] #{e.message}"
    nil
  end

  def extract_labels(autolabel_result)
    return [] unless autolabel_result.is_a?(Hash)

    # Real output shape: { "annotated_image" => url, "detections" => json_string }
    # detections JSON: { "labels" => [...], "bboxes" => [...] }
    if autolabel_result['detections'].is_a?(String)
      parsed = JSON.parse(autolabel_result['detections']) rescue nil
      if parsed.is_a?(Hash) && parsed['labels'].is_a?(Array)
        return parsed['labels'].map(&:to_s).map(&:strip).reject(&:empty?).uniq
      end
    end

    # Fallback: detections already parsed as array/hash
    if autolabel_result['detections'].is_a?(Hash)
      det = autolabel_result['detections']
      return det['labels'].map(&:to_s).map(&:strip).reject(&:empty?).uniq if det['labels'].is_a?(Array)
    end

    []
  end

  # ─── Replicate API Helpers ───

  def run_prediction(version:, input:)
    conn = @conn_mutex.synchronize { @rc.send(:build_connection, @api_key, timeout: 300) }

    resp = conn.post('predictions') do |req|
      req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
      req.body = { version: version, input: input }
    end

    unless resp.success?
      warn "  Replicate API error: #{resp.status}"
      return nil
    end

    result = JSON.parse(resp.body)

    case result['status']
    when 'succeeded'
      result['output']
    when 'starting', 'processing'
      poll_for_output(result['urls']&.dig('get'))
    when 'failed'
      warn "  Prediction failed: #{result['error']}"
      nil
    else
      warn "  Unexpected status: #{result['status']}"
      nil
    end
  rescue StandardError => e
    warn "  Prediction error: #{e.message}"
    nil
  end

  def poll_for_output(status_url)
    return nil unless status_url

    conn = @conn_mutex.synchronize { @rc.send(:build_connection, @api_key, timeout: 300) }

    MAX_POLL_ATTEMPTS.times do
      sleep(POLL_INTERVAL)
      resp = conn.get(status_url)
      result = JSON.parse(resp.body)

      case result['status']
      when 'succeeded'
        return result['output']
      when 'failed'
        warn "  Poll: prediction failed: #{result['error']}"
        return nil
      when 'canceled'
        return nil
      end
    end

    warn "  Poll: timed out"
    nil
  end

  PUBLIC_DIR = File.expand_path('../../public', __dir__)

  # Resolve a battle_map_image_url (relative path like /uploads/...) to an absolute local path.
  def resolve_image_url(url)
    return nil unless url
    return nil if url.start_with?('http')

    path = File.join(PUBLIC_DIR, url)
    File.exist?(path) ? path : nil
  end

  def download_url(url)
    URI.open(url, 'rb') { |f| f.read } # rubocop:disable Security/Open
  rescue StandardError => e
    warn "  download_url error: #{e.message}"
    nil
  end

  def extract_output_url(output)
    case output
    when String then output
    when Array then output.first
    when Hash then output['url'] || output['image'] || output['mask'] || output.values.first
    end
  end

  def extract_json_output(output)
    case output
    when Hash then output
    when Array then output
    when String
      if output.start_with?('http')
        body = download_url(output)
        JSON.parse(body) if body
      else
        JSON.parse(output) rescue output
      end
    end
  end

  # ─── HTML Report ───

  def generate_html
    log "\nGenerating HTML report..."

    html = build_html
    File.write(File.join(OUT_DIR, 'index.html'), html)
  end

  def build_html
    rooms_html = @results.map { |room_id, data| room_section(room_id, data) }.join("\n")

    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>SAM Model Comparison</title>
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body { background: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; padding: 20px; }
          h1 { color: #e94560; margin-bottom: 20px; }
          h2 { color: #0f3460; background: #e94560; padding: 8px 16px; border-radius: 6px; margin: 30px 0 15px; }
          h3 { color: #e94560; margin: 20px 0 10px; border-bottom: 1px solid #333; padding-bottom: 5px; }
          .room-section { background: #16213e; border-radius: 10px; padding: 20px; margin-bottom: 30px; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 15px; margin: 15px 0; }
          .card { background: #0f3460; border-radius: 8px; padding: 12px; }
          .card img { width: 100%; border-radius: 4px; cursor: pointer; }
          .card .label { font-size: 13px; color: #aaa; margin-top: 6px; }
          .card .status { font-size: 12px; margin-top: 4px; }
          .status.ok { color: #4ecca3; }
          .status.fail { color: #e94560; }
          .status.none { color: #666; }
          .comparison-table { width: 100%; border-collapse: collapse; margin: 15px 0; }
          .comparison-table th { background: #0f3460; padding: 8px; text-align: left; }
          .comparison-table td { padding: 8px; border-bottom: 1px solid #222; vertical-align: top; }
          .comparison-table td img { max-width: 250px; border-radius: 4px; cursor: pointer; }
          details { margin: 10px 0; }
          summary { cursor: pointer; color: #4ecca3; padding: 5px; }
          pre { background: #0a0a1a; padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 12px; max-height: 400px; overflow-y: auto; margin: 8px 0; }
          .input-img { max-width: 400px; border-radius: 8px; margin: 10px 0; }
          .lightbox { display: none; position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; background: rgba(0,0,0,0.9); z-index: 1000; justify-content: center; align-items: center; }
          .lightbox.active { display: flex; }
          .lightbox img { max-width: 95vw; max-height: 95vh; object-fit: contain; }
          .nav-bar { position: sticky; top: 0; background: #0a0a1a; border-bottom: 2px solid #e94560; padding: 8px 16px; z-index: 100; display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
          .nav-bar a { color: #4ecca3; text-decoration: none; font-size: 12px; padding: 3px 8px; background: #0f3460; border-radius: 4px; }
          .nav-bar a:hover { background: #e94560; color: white; }
          .nav-bar strong { color: #e94560; margin-right: 8px; }
        </style>
      </head>
      <body>
        <h1>SAM Model Comparison Experiment</h1>
        <p>Comparing <code>rehbbea/sam_autolabel</code>, <code>rehbbea/samg</code>, <code>rehbbea/sam2grounded</code>, and <code>tmappdev/lang-segment-anything</code></p>
        <div class="nav-bar">
          <strong>Jump to Part 4:</strong>
          #{@results.keys.map { |id| room = Room[id]; "<a href='#p4-room-#{id}'>#{room&.name || "Room #{id}"}</a>" }.join}
        </div>
        #{rooms_html}
        <div class="lightbox" id="lightbox" onclick="this.classList.remove('active')">
          <img id="lightbox-img" src="">
        </div>
        <script>
          document.querySelectorAll('.card img, .comparison-table img, .input-img').forEach(img => {
            img.addEventListener('click', () => {
              document.getElementById('lightbox-img').src = img.src;
              document.getElementById('lightbox').classList.add('active');
            });
          });
        </script>
      </body>
      </html>
    HTML
  end

  def room_section(room_id, data)
    room = Room[room_id]
    room_name = room&.name || "Room #{room_id}"
    room_dir = "room_#{room_id}"

    sections = []

    # Input image
    sections << "<img class='input-img' src='#{room_dir}/input.png' alt='Input'>"

    # Section 1: AutoLabel
    sections << autolabel_section(room_id, room_dir, data[:autolabel])

    # Section 2: Head-to-head
    sections << comparison_section(room_id, room_dir, data[:samg], data[:sam2grounded], data[:existing])

    # Section 3: Pipeline
    sections << pipeline_section(room_id, room_dir, data[:pipeline])

    # Section 4: Described queries
    sections << described_section(room_id, room_dir, data[:described], data[:samg])

    <<~HTML
      <div class="room-section">
        <h2>#{room_name} (Room #{room_id})</h2>
        #{sections.join("\n")}
      </div>
    HTML
  end

  def autolabel_section(room_id, room_dir, autolabel_data)
    return '<h3>AutoLabel</h3><p class="status fail">No results</p>' unless autolabel_data

    labels = extract_labels(autolabel_data)
    labels_html = labels.map { |l| "<li>#{escape(l)}</li>" }.join

    <<~HTML
      <h3>Part 1: AutoLabel Discovery</h3>
      <p>Detected #{labels.size} labels:</p>
      <ul>#{labels_html}</ul>
      <details>
        <summary>Raw JSON Output</summary>
        <pre>#{escape(JSON.pretty_generate(autolabel_data))}</pre>
      </details>
    HTML
  end

  def comparison_section(_room_id, room_dir, samg_data, sam2g_data, existing_data)
    rows = QUERIES.map do |query|
      samg     = samg_data[query]
      sam2g    = sam2g_data[query]
      existing = existing_data[query]

      samg_cell = if samg&.dig(:overlay) && File.exist?(samg[:overlay].to_s)
                    "<img src='#{room_dir}/samg_#{query}_overlay.png' loading='lazy'><div class='status ok'>Detected</div>"
                  else
                    "<div class='status none'>No detection</div>"
                  end

      sam2g_cell = if sam2g&.dig(:overlay) && File.exist?(sam2g[:overlay].to_s)
                     "<img src='#{room_dir}/sam2grounded_#{query}.png' loading='lazy'><div class='status ok'>Detected</div>"
                   else
                     "<div class='status none'>No detection</div>"
                   end

      existing_cell = if existing&.dig(:mask) && File.exist?(existing[:mask].to_s)
                        "<img src='#{room_dir}/existing_#{query}.png' loading='lazy'><div class='status ok'>Detected</div>"
                      elsif existing&.dig(:no_detections)
                        "<div class='status none'>No detection</div>"
                      else
                        "<div class='status fail'>Failed</div>"
                      end

      "<tr><td><strong>#{query}</strong></td><td>#{samg_cell}</td><td>#{sam2g_cell}</td><td>#{existing_cell}</td></tr>"
    end.join("\n")

    <<~HTML
      <h3>Part 2: Head-to-Head</h3>
      <table class="comparison-table">
        <tr><th>Query</th><th>rehbbea/samg</th><th>rehbbea/sam2grounded</th><th>tmappdev/lang-segment-anything</th></tr>
        #{rows}
      </table>
    HTML
  end

  def pipeline_section(_room_id, room_dir, pipeline_data)
    return '<h3>Part 3: AutoLabel → SAMG Pipeline</h3><p class="status none">Skipped (no autolabel)</p>' if pipeline_data.empty?

    cards = pipeline_data.map do |label, data|
      safe_name = label.gsub(/[^a-z0-9_-]/i, '_')[0..40]
      if data[:overlay] && File.exist?(data[:overlay].to_s)
        <<~HTML
          <div class="card">
            <img src="#{room_dir}/pipeline_#{safe_name}_overlay.png" loading="lazy">
            <div class="label">#{escape(label)}</div>
            <div class="status ok">Detected</div>
          </div>
        HTML
      else
        <<~HTML
          <div class="card">
            <div class="label">#{escape(label)}</div>
            <div class="status none">No detection</div>
          </div>
        HTML
      end
    end.join("\n")

    <<~HTML
      <h3>Part 3: AutoLabel → SAMG Pipeline</h3>
      <p>#{pipeline_data.size} labels processed</p>
      <div class="grid">
        #{cards}
      </div>
    HTML
  end

  def described_section(room_id, room_dir, described_data, samg_data)
    return "<h3 id='p4-room-#{room_id}'>Part 4: Described Queries → SAMG</h3><p class='status none'>No results</p>" if described_data.nil? || described_data.empty?

    rows = DESCRIBED_TARGETS.map do |target|
      entry = described_data[target]
      next unless entry

      desc    = entry[:description] || entry['description']
      overlay = entry[:overlay]     || entry['overlay']

      generic_samg = samg_data&.dig(target)
      generic_cell = if generic_samg&.dig(:overlay) && File.exist?(generic_samg[:overlay].to_s)
                       "<img src='#{room_dir}/samg_#{target}_overlay.png' loading='lazy'>"
                     else
                       "<div class='status none'>No detection</div>"
                     end

      described_cell = if overlay && File.exist?(overlay.to_s)
                         "<img src='#{room_dir}/described_#{target}_overlay.png' loading='lazy'>"
                       else
                         "<div class='status none'>No detection</div>"
                       end

      <<~HTML
        <tr>
          <td><strong>#{target}</strong><br><small style='color:#888'>#{escape(desc)}</small></td>
          <td>#{generic_cell}<div class='label'>generic "#{target}"</div></td>
          <td>#{described_cell}<div class='label'>described</div></td>
        </tr>
      HTML
    end.compact.join("\n")

    <<~HTML
      <h3 id='p4-room-#{room_id}'>Part 4: Gemini-Described Queries → SAMG</h3>
      <p>Gemini described what walls/doors look like, then those descriptions were fed to SAMG — compared against generic query.</p>
      <table class="comparison-table">
        <tr><th>Target + Gemini description</th><th>SAMG (generic)</th><th>SAMG (described)</th></tr>
        #{rows}
      </table>
    HTML
  end

  def escape(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end
end

# ─── Main ───

if __FILE__ == $PROGRAM_NAME
  described_only = ARGV.include?('--described-only')
  SamExperiment.new.run(described_only: described_only)
end
