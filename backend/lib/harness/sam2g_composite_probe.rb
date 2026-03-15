#!/usr/bin/env ruby
# frozen_string_literal: true

# sam2grounded Composite Label Probe
# ====================================
# Tests passing all object types as a single comma-separated labels string
# across 2 label sets × 3 detectors × 3 thresholds on Room 155.
#
# Usage:
#   cd backend
#   bundle exec ruby lib/harness/sam2g_composite_probe.rb
#
# Output: lib/harness/sam2g_composite_probe/index.html

$stdout.sync = true
require 'fileutils'
require 'base64'
require 'json'
require 'open-uri'
require 'faraday'

require_relative '../../config/room_type_config'
Dir[File.join(__dir__, '../../app/lib/*.rb')].each { |f| require f }
require_relative '../../config/application'

# ── Constants ─────────────────────────────────────────────────────────────────

SAM2G_MODEL  = 'rehbbea/sam2grounded'
LANG_SAM_DIR = File.join(__dir__, 'samg_l1_probe')
OUT_DIR      = File.join(__dir__, 'sam2g_composite_probe')
INPUT_IMAGE  = File.join(LANG_SAM_DIR, 'room_155_input.png')

LABEL_SETS = [
  {
    name:   'generic',
    labels: 'table, chair, barrel, crate, glass_window, anvil, forge, sack, counter'
  },
  {
    name:   'descriptive',
    labels: 'wooden table, wooden stool, wooden barrel, wooden crate, narrow glass window, metal anvil, stone forge, burlap sacks, wooden shop counter'
  }
].freeze

DETECTORS  = %w[dino owlv2 both].freeze
THRESHOLDS = [0.1, 0.3, 0.5].freeze

SYNC_TIMEOUT  = 60
POLL_INTERVAL = 5
MAX_POLLS     = 60
MAX_THREADS   = 4

# ── Setup ─────────────────────────────────────────────────────────────────────

FileUtils.mkdir_p(OUT_DIR)

rc      = ReplicateDepthService
api_key = rc.send(:replicate_api_key)
abort 'No Replicate API key configured' unless api_key && !api_key.empty?

abort "Input image not found: #{INPUT_IMAGE}" unless File.exist?(INPUT_IMAGE)

bootstrap_conn = rc.send(:build_connection, api_key, timeout: 120)
version = rc.send(:resolve_model_version, bootstrap_conn, SAM2G_MODEL)
abort "Could not resolve model version for #{SAM2G_MODEL}" unless version
puts "#{SAM2G_MODEL}: #{version[0..7]}..."

# ── Helpers ───────────────────────────────────────────────────────────────────

LOG_MUTEX     = Mutex.new
RESULTS_MUTEX = Mutex.new

def log(msg)
  LOG_MUTEX.synchronize { puts msg }
end

def image_data_uri(path)
  mime = ReplicateDepthService.send(:detect_mime_type, path)
  "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
end

def extract_output_url(output)
  case output
  when String then output
  when Array  then output.first
  when Hash   then output['url'] || output['image'] || output['mask'] || output.values.first
  end
end

def download_url(url)
  URI.open(url, 'rb') { |f| f.read } # rubocop:disable Security/Open
rescue StandardError => e
  warn "  download_url error: #{e.message}"
  nil
end

def output_filename(set_name, detector, threshold)
  t = (threshold * 10).round
  "155_#{set_name}_sam2grounded_#{detector}_t#{t}.png"
end

def run_prediction(api_key, version, input, label)
  conn = ReplicateDepthService.send(:build_connection, api_key, timeout: 300)

  resp = conn.post('predictions') do |req|
    req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
    req.body = { version: version, input: input }
  end

  unless resp.success?
    log "  #{label}: HTTP #{resp.status}"
    return nil
  end

  result = JSON.parse(resp.body)

  if %w[starting processing].include?(result['status'])
    poll_url  = result.dig('urls', 'get')
    poll_conn = ReplicateDepthService.send(:build_connection, api_key, timeout: 300)
    MAX_POLLS.times do
      sleep POLL_INTERVAL
      pr     = poll_conn.get(poll_url)
      result = JSON.parse(pr.body)
      break unless %w[starting processing].include?(result['status'])
    end
  end

  unless result['status'] == 'succeeded'
    log "  #{label}: FAILED — #{result['error']}"
    return nil
  end

  result['output']
rescue StandardError => e
  log "  #{label}: exception — #{e.message}"
  nil
end

# ── Main experiment loop ───────────────────────────────────────────────────────

data_uri = image_data_uri(INPUT_IMAGE)
puts "Input image encoded (#{(data_uri.length / 1024.0).round}KB base64)"

# results[set_name][detector][threshold] = { path: String } or { error: String } or nil
results = {}
LABEL_SETS.each do |set|
  results[set[:name]] = {}
  DETECTORS.each do |d|
    results[set[:name]][d] = {}
    THRESHOLDS.each { |t| results[set[:name]][d][t] = nil }
  end
end

work = LABEL_SETS.flat_map { |set| DETECTORS.flat_map { |d| THRESHOLDS.map { |t| [set, d, t] } } }

queue = Queue.new
work.each { |item| queue << item }

threads = Array.new([MAX_THREADS, work.size].min) do
  Thread.new do
    loop do
      begin
        item = queue.pop(true)
      rescue ThreadError
        break
      end
      set, detector, threshold = item

      fname    = output_filename(set[:name], detector, threshold)
      out_path = File.join(OUT_DIR, fname)
      label    = "'#{set[:name]}' [#{detector} t=#{threshold}]"

      if File.exist?(out_path)
        log "  #{label}: cached"
        RESULTS_MUTEX.synchronize { results[set[:name]][detector][threshold] = { path: out_path } }
        next
      end

      log "  #{label}: submitting..."

      input = {
        image:               data_uri,
        labels:              set[:labels],
        detector:            detector,
        detection_threshold: threshold
      }

      output = run_prediction(api_key, version, input, label)

      entry = if output
                url  = extract_output_url(output)
                data = download_url(url) if url
                if data
                  File.binwrite(out_path, data)
                  log "  #{label}: ok (#{(data.length / 1024.0).round}KB)"
                  { path: out_path }
                else
                  log "  #{label}: no data from URL"
                  { error: 'no data' }
                end
              else
                { error: 'prediction failed' }
              end

      RESULTS_MUTEX.synchronize { results[set[:name]][detector][threshold] = entry }
    end
  end
end
threads.each(&:join)

puts "\nAll calls complete."

# ── HTML generation ───────────────────────────────────────────────────────────

def h(str)
  str.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
end

DETECTOR_LABELS = {
  'dino'  => 'Grounding DINO',
  'owlv2' => 'OWL-ViT v2',
  'both'  => 'Both (DINO + OWL-ViT v2)'
}.freeze

def result_img(entry, set_name, detector, threshold)
  return "<div class='no-result'>no result</div>" unless entry && entry[:path] && File.exist?(entry[:path])

  fname = File.basename(entry[:path])
  cap   = h("#{set_name} — #{detector} t=#{threshold}")
  "<img src='#{fname}' loading='lazy' onclick=\"open_lb('#{fname}','#{cap}')\">"
end

sections = DETECTORS.map do |detector|
  det_label = DETECTOR_LABELS[detector]

  rows = LABEL_SETS.map do |set|
    thresh_cells = THRESHOLDS.map do |t|
      entry = results[set[:name]][detector][t]
      "<td>#{result_img(entry, set[:name], detector, t)}</td>"
    end.join
    label_cell = "<td class='qlabel'>#{h set[:name]}<div class='labels-detail'>#{h set[:labels]}</div></td>"
    "<tr>#{label_cell}#{thresh_cells}</tr>"
  end.join("\n")

  <<~SECTION
    <h2>#{h det_label}</h2>
    <table>
      <thead>
        <tr>
          <th>Label set</th>
          <th>t=0.1</th>
          <th>t=0.3</th>
          <th>t=0.5</th>
        </tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
  SECTION
end.join("\n")

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <title>sam2grounded Composite Label Probe &mdash; Room 155</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; padding: 24px; }
      h1 { color: #e94560; margin-bottom: 6px; font-size: 1.5rem; }
      .meta { color: #888; font-size: 13px; margin-bottom: 20px; }
      h2 { color: #4ecca3; margin: 28px 0 12px; font-size: 1.1rem; border-bottom: 1px solid #2a2a4e; padding-bottom: 6px; }
      .ref { margin-bottom: 20px; }
      .ref img { max-width: 360px; border-radius: 8px; border: 2px solid #4ecca3; }
      .ref p { color: #888; font-size: 12px; margin-bottom: 6px; }
      table { width: 100%; border-collapse: collapse; margin-bottom: 8px; }
      th { background: #16213e; color: #4ecca3; padding: 8px 12px; text-align: left; font-size: 13px; }
      td { padding: 8px 12px; border-bottom: 1px solid #1e1e3a; vertical-align: top; }
      td.qlabel { color: #ffd166; font-size: 13px; width: 160px; }
      .labels-detail { color: #888; font-size: 11px; margin-top: 4px; font-style: italic; }
      td img { width: 100%; max-width: 360px; border-radius: 6px; cursor: zoom-in; display: block; }
      .no-result { height: 120px; display: flex; align-items: center; justify-content: center;
                   color: #555; background: #0f0f1a; border-radius: 6px; font-size: 13px; }
      .lightbox { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.93);
                  z-index: 1000; justify-content: center; align-items: center; flex-direction: column; gap: 12px; }
      .lightbox.active { display: flex; }
      .lightbox img { max-width: 95vw; max-height: 90vh; object-fit: contain; }
      .lb-cap { color: #e0e0e0; font-size: 14px; font-style: italic; }
    </style>
  </head>
  <body>
    <h1>sam2grounded Composite Label Probe &mdash; Quality Iron Arms (Room 155)</h1>
    <p class="meta">2 label sets &times; 3 detectors &times; 3 thresholds</p>
    <div class="ref">
      <p>Reference:</p>
      <img src="../samg_l1_probe/room_155_input.png" loading="lazy" alt="Input">
    </div>
    #{sections}
    <div class="lightbox" id="lb" onclick="close_lb()">
      <img id="lb-img" src="">
      <div class="lb-cap" id="lb-cap"></div>
    </div>
    <script>
      function open_lb(src, cap) {
        document.getElementById('lb-img').src = src;
        document.getElementById('lb-cap').textContent = cap;
        document.getElementById('lb').classList.add('active');
      }
      function close_lb() { document.getElementById('lb').classList.remove('active'); }
      document.addEventListener('keydown', e => { if (e.key === 'Escape') close_lb(); });
    </script>
  </body>
  </html>
HTML

cache_bust = Time.now.to_i
html = html.gsub(/(<img[^>]+src=['\"])([^'\"?#]+)(['\"])/, "\\1\\2?t=#{cache_bust}\\3")

html_path = File.join(OUT_DIR, 'index.html')
File.write(html_path, html)
puts "HTML written to #{html_path}"

served = File.join(__dir__, '../../tmp/battlemap_inspect/sam2g_composite_probe')
unless File.exist?(served) || File.symlink?(served)
  FileUtils.ln_sf(OUT_DIR, served)
  puts "Symlinked: #{served} → #{OUT_DIR}"
end

puts "\nDone! http://35.196.200.49:8181/sam2g_composite_probe/index.html"
