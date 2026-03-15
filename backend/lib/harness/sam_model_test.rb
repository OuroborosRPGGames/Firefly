#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick sanity check: can we call each of the three Replicate SAM models?
# Usage: cd backend && bundle exec ruby lib/harness/sam_model_test.rb

$stdout.sync = true
require 'base64'
require 'json'
require 'faraday'

require_relative '../../config/room_type_config'
Dir[File.join(__dir__, '../../app/lib/*.rb')].each { |f| require f }
require_relative '../../config/application'

IMAGE_PATH = File.join(__dir__, 'battlemap_inspect/room_155/01_raw_image.png')
AUTOLABEL_MODEL    = 'rehbbea/sam_autolabel'
SAMG_MODEL         = 'rehbbea/samg'
SAM2GROUNDED_MODEL = 'rehbbea/sam2grounded'
EXISTING_MODEL     = 'tmappdev/lang-segment-anything'
SYNC_TIMEOUT    = 60
POLL_INTERVAL   = 5
MAX_POLLS       = 60

rc      = ReplicateDepthService
api_key = rc.send(:replicate_api_key)
abort 'No Replicate API key' unless api_key && !api_key.empty?

conn = rc.send(:build_connection, api_key, timeout: 300)

def encode_image(path)
  mime = path.end_with?('.webp') ? 'image/webp' : 'image/png'
  "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
end

def submit_and_wait(conn, api_key, version, input, label)
  puts "  Submitting #{label}..."
  resp = conn.post('predictions') do |req|
    req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
    req.body = { version: version, input: input }
  end

  unless resp.success?
    puts "  ERROR: HTTP #{resp.status} — #{resp.body[0..300]}"
    return nil
  end

  result = JSON.parse(resp.body)
  puts "  Initial status: #{result['status']}"

  if result['status'] == 'succeeded'
    return result
  end

  # Poll
  poll_url = result.dig('urls', 'get')
  unless poll_url
    puts "  ERROR: No poll URL"
    return nil
  end

  poll_conn = rc.send(:build_connection, api_key, timeout: 300) rescue conn
  MAX_POLLS.times do |i|
    sleep POLL_INTERVAL
    pr = poll_conn.get(poll_url)
    r  = JSON.parse(pr.body)
    puts "  Poll #{i + 1}: #{r['status']}"
    return r if r['status'] == 'succeeded'
    if r['status'] == 'failed'
      puts "  FAILED: #{r['error']}"
      return nil
    end
  end

  puts "  TIMEOUT after #{MAX_POLLS * POLL_INTERVAL}s"
  nil
end

image_uri = encode_image(IMAGE_PATH)
puts "Image: #{IMAGE_PATH} (#{(File.size(IMAGE_PATH) / 1024.0).round}KB)"
puts

# ── 1. sam_autolabel ──────────────────────────────────────────────────────────
puts "=" * 60
puts "TEST 1: rehbbea/sam_autolabel"
puts "=" * 60
version = rc.send(:resolve_model_version, conn, AUTOLABEL_MODEL)
if version
  puts "  Version: #{version[0..15]}..."
  result = submit_and_wait(conn, api_key, version, { image: image_uri, pipeline: 'both' }, AUTOLABEL_MODEL)
  if result
    puts "  OUTPUT TYPE: #{result['output'].class}"
    puts "  OUTPUT (first 1000 chars):"
    puts JSON.pretty_generate(result['output'])[0..1000]
  end
else
  puts "  Could not resolve model version"
end
puts

# ── 2. samg ───────────────────────────────────────────────────────────────────
puts "=" * 60
puts "TEST 2: rehbbea/samg (prompt: 'wall', output_format: 'colored_overlay')"
puts "=" * 60
version = rc.send(:resolve_model_version, conn, SAMG_MODEL)
if version
  puts "  Version: #{version[0..15]}..."
  result = submit_and_wait(conn, api_key, version,
    { image: image_uri, prompt: 'wall', output_format: 'colored_overlay' },
    "#{SAMG_MODEL} colored_overlay")
  if result
    puts "  OUTPUT TYPE: #{result['output'].class}"
    puts "  OUTPUT:"
    puts JSON.pretty_generate(result['output'])[0..500]
  end
else
  puts "  Could not resolve model version"
end
puts

puts "=" * 60
puts "TEST 2b: rehbbea/samg (prompt: 'wall', output_format: 'json')"
puts "=" * 60
if (version = rc.send(:resolve_model_version, conn, SAMG_MODEL))
  result = submit_and_wait(conn, api_key, version,
    { image: image_uri, prompt: 'wall', output_format: 'json' },
    "#{SAMG_MODEL} json")
  if result
    puts "  OUTPUT TYPE: #{result['output'].class}"
    puts "  OUTPUT:"
    puts JSON.pretty_generate(result['output'])[0..500]
  end
end
puts

# ── 3. sam2grounded ───────────────────────────────────────────────────────────
puts "=" * 60
puts "TEST 3: rehbbea/sam2grounded (prompt: 'wall')"
puts "=" * 60
version = rc.send(:resolve_model_version, conn, SAM2GROUNDED_MODEL)
if version
  puts "  Version: #{version[0..15]}..."
  # Try common input shapes — grounded models often take 'prompt' or 'text_prompt'
  result = submit_and_wait(conn, api_key, version,
    { image: image_uri, prompt: 'wall' },
    SAM2GROUNDED_MODEL)
  if result
    puts "  OUTPUT TYPE: #{result['output'].class}"
    puts "  OUTPUT (first 1000 chars):"
    puts JSON.pretty_generate(result['output'])[0..1000]
  end
else
  puts "  Could not resolve model version"
end
puts

# ── 4. SAM2G + lang-segment-anything fallback ────────────────────────────────
puts "=" * 60
puts "TEST 4: SAM2G primary with lang-segment-anything fallback (query: 'wall')"
puts "=" * 60
result = ReplicateSamService.segment_with_samg_fallback(IMAGE_PATH, 'wall', suffix: '_test_wall')
puts "  Result: #{result.inspect[0..300]}"
puts

puts "All tests done."
