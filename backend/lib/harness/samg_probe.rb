#!/usr/bin/env ruby
# frozen_string_literal: true

# SAMG Probe — focused single-room query tester
#
# Usage:
#   cd backend
#   bundle exec ruby lib/harness/samg_probe.rb [room_id] [query1] [query2] ...
#
# Example:
#   bundle exec ruby lib/harness/samg_probe.rb 155 "perimeter stone wall" "western door"
#
# Output: lib/harness/samg_probe/index.html

$stdout.sync = true
require 'fileutils'
require 'base64'
require 'json'
require 'faraday'

require_relative '../../config/room_type_config'
Dir[File.join(__dir__, '../../app/lib/*.rb')].each { |f| require f }
require_relative '../../config/application'

ROOM_ID  = (ARGV[0] || 155).to_i
QUERIES  = ARGV[1..] && ARGV[1..].any? ? ARGV[1..] : [
  'perimeter stone wall',
  'perimeter wall',
  'western door',
  'western archway',
  'left side door',
  'left side archway'
]

SAMG_MODEL   = 'rehbbea/samg'
SYNC_TIMEOUT = 60
POLL_INTERVAL = 5
MAX_POLLS    = 60
OUT_DIR      = File.join(__dir__, 'samg_probe')
PUBLIC_DIR   = File.expand_path('../../public', __dir__)

FileUtils.mkdir_p(OUT_DIR)

rc      = ReplicateDepthService
api_key = rc.send(:replicate_api_key)
abort 'No Replicate API key' unless api_key && !api_key.empty?

conn    = rc.send(:build_connection, api_key, timeout: 300)
version = rc.send(:resolve_model_version, conn, SAMG_MODEL)
abort "Could not resolve #{SAMG_MODEL}" unless version
puts "#{SAMG_MODEL}: #{version[0..7]}..."

# ── Get input image ────────────────────────────────────────────────────────────

room = Room[ROOM_ID]
abort "Room #{ROOM_ID} not found" unless room

input_path = File.join(OUT_DIR, "room_#{ROOM_ID}_input.png")
unless File.exist?(input_path) && File.size(input_path) > 1000
  url = room.battle_map_image_url
  abort "Room #{ROOM_ID} has no battle_map_image_url" unless url && !url.empty?

  src = if url.start_with?('http')
          require 'open-uri'
          tmp = "#{input_path}.tmp"
          URI.open(url, 'rb') { |f| File.binwrite(tmp, f.read) } # rubocop:disable Security/Open
          tmp
        else
          File.join(PUBLIC_DIR, url)
        end

  abort "Image not found at #{src}" unless src && File.exist?(src)
  FileUtils.cp(src, input_path)
  puts "Input: #{(File.size(input_path) / 1024.0).round}KB"
end

mime     = rc.send(:detect_mime_type, input_path)
data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(input_path))}"

# ── Run queries ────────────────────────────────────────────────────────────────

results = {}

queue = Queue.new
QUERIES.each { |q| queue << q }

threads = Array.new([4, QUERIES.size].min) do
  Thread.new do
    loop do
      query = begin; queue.pop(true); rescue ThreadError; break; end

      safe  = query.gsub(/[^a-z0-9_-]/i, '_')
      out   = File.join(OUT_DIR, "#{ROOM_ID}_#{safe}.png")

      if File.exist?(out)
        puts "  '#{query}': cached"
        results[query] = out
        next
      end

      puts "  '#{query}': submitting..."
      resp = conn.post('predictions') do |req|
        req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
        req.body = { version: version, input: { image: data_uri, prompt: query, output_format: 'colored_overlay' } }
      end

      unless resp.success?
        puts "  '#{query}': ERROR #{resp.status}"
        next
      end

      result = JSON.parse(resp.body)

      # Poll if not immediately done
      if %w[starting processing].include?(result['status'])
        poll_url = result.dig('urls', 'get')
        poll_conn = rc.send(:build_connection, api_key, timeout: 300)
        MAX_POLLS.times do
          sleep POLL_INTERVAL
          pr = poll_conn.get(poll_url)
          result = JSON.parse(pr.body)
          break unless %w[starting processing].include?(result['status'])
        end
      end

      unless result['status'] == 'succeeded'
        puts "  '#{query}': FAILED — #{result['error']}"
        next
      end

      url = result['output']
      url = url.first if url.is_a?(Array)
      unless url.is_a?(String) && url.start_with?('http')
        puts "  '#{query}': no output URL"
        next
      end

      require 'open-uri'
      data = URI.open(url, 'rb') { |f| f.read } rescue nil # rubocop:disable Security/Open
      unless data
        puts "  '#{query}': download failed"
        next
      end

      File.binwrite(out, data)
      results[query] = out
      puts "  '#{query}': ok (#{(File.size(out) / 1024.0).round}KB)"
    end
  end
end
threads.each(&:join)

# ── Generate HTML ──────────────────────────────────────────────────────────────

input_rel = File.basename(input_path)

cards = QUERIES.map do |query|
  safe = query.gsub(/[^a-z0-9_-]/i, '_')
  img_file = "#{ROOM_ID}_#{safe}.png"
  img_exists = File.exist?(File.join(OUT_DIR, img_file))
  img_html = img_exists ? "<img src='#{img_file}' loading='lazy'>" : "<div class='no-result'>No result</div>"
  <<~HTML
    <div class="card">
      #{img_html}
      <div class="query">&ldquo;#{query}&rdquo;</div>
    </div>
  HTML
end.join("\n")

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <title>SAMG Probe — Room #{ROOM_ID}</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; padding: 20px; }
      h1 { color: #e94560; margin-bottom: 6px; }
      .meta { color: #888; font-size: 13px; margin-bottom: 20px; }
      .input-wrap { display: flex; gap: 20px; align-items: flex-start; margin-bottom: 24px; }
      .input-wrap img { max-width: 420px; border-radius: 8px; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 16px; }
      .card { background: #16213e; border-radius: 10px; padding: 12px; }
      .card img { width: 100%; border-radius: 6px; cursor: pointer; }
      .query { margin-top: 8px; font-size: 14px; color: #4ecca3; font-style: italic; }
      .no-result { height: 120px; display: flex; align-items: center; justify-content: center; color: #555; background: #0f0f1a; border-radius: 6px; }
      .lightbox { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.92); z-index: 1000; justify-content: center; align-items: center; }
      .lightbox.active { display: flex; }
      .lightbox img { max-width: 95vw; max-height: 95vh; object-fit: contain; }
      .caption { position: fixed; bottom: 20px; left: 0; right: 0; text-align: center; color: #e0e0e0; font-size: 16px; font-style: italic; }
    </style>
  </head>
  <body>
    <h1>SAMG Probe — #{room.name} (Room #{ROOM_ID})</h1>
    <p class="meta">Model: #{SAMG_MODEL} &nbsp;|&nbsp; #{QUERIES.size} queries &nbsp;|&nbsp; #{results.size} succeeded</p>
    <div class="input-wrap">
      <img src="#{input_rel}" loading="lazy" alt="Input">
    </div>
    <div class="grid">
      #{cards}
    </div>
    <div class="lightbox" id="lb" onclick="close_lb()">
      <img id="lb-img" src="">
      <div class="caption" id="lb-cap"></div>
    </div>
    <script>
      document.querySelectorAll('.card img').forEach(img => {
        img.addEventListener('click', e => {
          e.stopPropagation();
          document.getElementById('lb-img').src = img.src;
          document.getElementById('lb-cap').textContent = img.closest('.card').querySelector('.query').textContent;
          document.getElementById('lb').classList.add('active');
        });
      });
      function close_lb() { document.getElementById('lb').classList.remove('active'); }
      document.addEventListener('keydown', e => { if (e.key === 'Escape') close_lb(); });
    </script>
  </body>
  </html>
HTML

File.write(File.join(OUT_DIR, 'index.html'), html)

# Symlink into served directory
served = File.join(__dir__, '../../../backend/tmp/battlemap_inspect/samg_probe')
served = File.join(__dir__, '../../tmp/battlemap_inspect/samg_probe')
unless File.exist?(served) || File.symlink?(served)
  FileUtils.ln_sf(OUT_DIR, served)
end

puts "\nDone! http://35.196.200.49:8181/samg_probe/index.html"
