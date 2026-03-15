#!/usr/bin/env ruby
# frozen_string_literal: true

# SAMG L1 Probe — Gemini L1 Grid Descriptions → SAMG Segmentation
#
# Primary model:  rehbbea/samg (binary_mask output — pixel-accurate grayscale PNG)
# Fallback model: tmappdev/lang-segment-anything (binary mask)
#   Fallback is rejected if mask coverage > MAX_MASK_COVERAGE.
#
# Priority composite: when multiple masks claim the same pixel, the mask
# with the smallest total coverage wins (most precise detection).
#
# Usage:
#   cd backend
#   bundle exec ruby lib/harness/samg_l1_probe.rb [room_id]
#
# Output: lib/harness/samg_l1_probe/index.html
# Served: http://35.196.200.49:8181/samg_l1_probe/index.html

$stdout.sync = true
require 'fileutils'
require 'base64'
require 'json'
require 'open-uri'
require 'shellwords'
require 'open3'
require 'faraday'
require 'vips'

require_relative '../../config/room_type_config'
Dir[File.join(__dir__, '../../app/lib/*.rb')].each { |f| require f }
require_relative '../../config/application'

ROOM_ID           = (ARGV[0] || 155).to_i
SAMG_MODEL        = 'rehbbea/samg'
LANG_SAM_MODEL    = 'tmappdev/lang-segment-anything'
MAX_MASK_COVERAGE     = 0.15   # reject lang-SAM if it covers more than this fraction
LANG_SAM_CONF_THRESH  = 210    # lang-SAM outputs confidence 0-255; only keep pixels >= this
MIN_SAMG_COVERAGE = 0.001  # treat SAMG as a miss if pixel coverage is below this
COMPOSITE_ALPHA   = 0.60   # blend opacity for composite overlay
SYNC_TIMEOUT      = 60
POLL_INTERVAL     = 5
MAX_POLLS         = 60
OUT_DIR           = File.join(__dir__, 'samg_l1_probe')
PUBLIC_DIR        = File.expand_path('../../public', __dir__)

PALETTE = [
  { rgb: [255,  80,  80], hex: '#ff5050' },
  { rgb: [ 80, 200,  80], hex: '#50c850' },
  { rgb: [ 80, 120, 255], hex: '#5078ff' },
  { rgb: [255, 200,   0], hex: '#ffc800' },
  { rgb: [255,  80, 255], hex: '#ff50ff' },
  { rgb: [  0, 220, 220], hex: '#00dcdc' },
  { rgb: [255, 140,   0], hex: '#ff8c00' },
  { rgb: [160,  80, 255], hex: '#a050ff' },
  { rgb: [  0, 255, 180], hex: '#00ffb4' },
  { rgb: [255, 100, 160], hex: '#ff64a0' },
  { rgb: [180, 220,   0], hex: '#b4dc00' },
].freeze

FileUtils.mkdir_p(OUT_DIR)

# ── Setup ──────────────────────────────────────────────────────────────────────

rc      = ReplicateDepthService
api_key = rc.send(:replicate_api_key)
abort 'No Replicate API key' unless api_key && !api_key.empty?

gemini_key = AIProviderService.api_key_for('google_gemini')
abort 'No Gemini API key' unless gemini_key && !gemini_key.empty?

conn = rc.send(:build_connection, api_key, timeout: 300)

samg_version = rc.send(:resolve_model_version, conn, SAMG_MODEL)
abort "Could not resolve #{SAMG_MODEL}" unless samg_version
puts "#{SAMG_MODEL}: #{samg_version[0..7]}..."

lang_version = rc.send(:resolve_model_version, conn, LANG_SAM_MODEL)
abort "Could not resolve #{LANG_SAM_MODEL}" unless lang_version
puts "#{LANG_SAM_MODEL}: #{lang_version[0..7]}..."

# ── Room + input image ─────────────────────────────────────────────────────────

room = Room[ROOM_ID]
abort "Room #{ROOM_ID} not found" unless room
puts "Room: #{room.name} (#{ROOM_ID})"

input_path = File.join(OUT_DIR, "room_#{ROOM_ID}_input.png")
unless File.exist?(input_path) && File.size(input_path) > 1000
  url = room.battle_map_image_url
  abort "Room #{ROOM_ID} has no battle_map_image_url" unless url && !url.empty?

  src = if url.start_with?('http')
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
base64   = Base64.strict_encode64(File.binread(input_path))
data_uri = "data:#{mime};base64,#{base64}"

# ── Gemini schema + prompt ─────────────────────────────────────────────────────

STANDARD_FEATURE_TYPES = AIBattleMapGeneratorService::SIMPLE_HEX_TYPES.reject { |t|
  %w[wall off_map open_floor other].include?(t)
}.freeze

def grid_l1_prompt_extended(grid_n = 3)
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

    STEP 5 — For each standard type and custom type, provide a short_description:
    2-4 words that visually identify THIS object on THIS map, suitable as a search phrase for image segmentation.
    Good examples: "rough grey stone", "dark stained planks", "iron-banded barrel", "iron wall sconce".
    Bad examples: "wall", "floor", "object" (too generic), "a table" (article + too short).

    STEP 6 — Light sources:
    List all light-emitting objects (light_sources). Do NOT include windows, ambient light, or skylights.
    Types: fire (campfire/fireplace/brazier), torch (wall sconce/torch), candle (candle/candelabra),
    gaslamp (oil lamp/lantern), electric_light (spotlight/fluorescent), magical_light (glowing crystal/rune/orb).
    For each, provide: source_type, description (what it looks like), short_description (2-4 word SAMG phrase,
    e.g. "iron wall sconce", "stone hearth fire", "brass oil lantern"), squares (which 1-9 grid squares contain it).

    STEP 7 — Perimeter wall analysis:
    - perimeter_wall: true if the room is enclosed by a visible wall boundary (not just open space)
    - perimeter_wall_doors: list directions where doors, archways, or openings exist in the perimeter wall
      Options: n, s, e, w, nw, ne, sw, se

    STEP 8 — Internal wall analysis:
    - internal_walls: list any walls INSIDE the room that divide the space
      For each: location (which part of the room: n, s, e, w, nw, ne, sw, se), has_door, door_side (direction)
  PROMPT
end

def grid_l1_schema_extended
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
            visual_description: { type: 'STRING', description: 'What this type looks like on this specific map (color, shape, material)' },
            short_description: { type: 'STRING', description: '2-4 word visual phrase for SAMG segmentation' }
          },
          required: %w[type_name visual_description short_description]
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
            short_description: { type: 'STRING' },
            provides_cover: { type: 'BOOLEAN', description: 'Does this provide cover from ranged attacks?' },
            is_exit: { type: 'BOOLEAN', description: 'Is this a door, gate, or passage?' },
            difficult_terrain: { type: 'BOOLEAN', description: 'Does this slow movement?' },
            elevation: { type: 'INTEGER', description: 'Height in feet above floor (0 for floor-level objects)' },
            hazards: { type: 'ARRAY', items: { type: 'STRING' }, description: 'Hazard types if any' }
          },
          required: %w[type_name visual_description short_description provides_cover is_exit difficult_terrain elevation hazards]
        }
      },
      light_sources: {
        type: 'ARRAY',
        description: 'Light-emitting objects visible on the map. Do NOT include windows or ambient light.',
        items: {
          type: 'OBJECT',
          properties: {
            source_type: { type: 'STRING', enum: %w[fire torch candle gaslamp electric_light magical_light],
                           description: 'fire=campfire/fireplace/brazier, torch=wall sconce/torch, candle=candle/candelabra, gaslamp=oil lamp/lantern, electric_light=spotlight, magical_light=glowing crystal/rune/orb' },
            description: { type: 'STRING', description: 'What it looks like (e.g. "iron wall sconce with flame")' },
            short_description: { type: 'STRING', description: '2-4 word visual phrase for SAMG segmentation (e.g. "iron wall sconce", "stone hearth fire")' },
            squares: { type: 'ARRAY', items: { type: 'INTEGER' }, description: 'Which grid squares (1-9) contain this light source' }
          },
          required: %w[source_type description short_description squares]
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
      },
      perimeter_wall: { type: 'BOOLEAN' },
      perimeter_wall_doors: {
        type: 'ARRAY',
        items: { type: 'STRING', enum: %w[n s e w nw ne sw se] }
      },
      internal_walls: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            location: { type: 'STRING', enum: %w[n s e w nw ne sw se] },
            has_door: { type: 'BOOLEAN' },
            door_side: { type: 'STRING', enum: %w[n s e w nw ne sw se none] }
          },
          required: %w[location has_door door_side]
        }
      }
    },
    required: %w[scene_description wall_visual floor_visual lighting_direction standard_types_present custom_types light_sources squares perimeter_wall perimeter_wall_doors internal_walls]
  }
end

# ── Step 1 — Gemini L1 call ────────────────────────────────────────────────────

gemini_cache = File.join(OUT_DIR, "room_#{ROOM_ID}_gemini.json")
l1_data = nil

if File.exist?(gemini_cache)
  puts "Gemini: cached"
  l1_data = JSON.parse(File.read(gemini_cache))
else
  puts "Gemini: calling L1..."
  t0 = Time.now
  response = LLM::Adapters::GeminiAdapter.generate(
    messages: [{ role: 'user', content: [
      { type: 'image', mime_type: mime, data: base64 },
      { type: 'text', text: grid_l1_prompt_extended }
    ]}],
    model: 'gemini-3.1-pro-preview',
    api_key: gemini_key,
    response_schema: grid_l1_schema_extended,
    options: { max_tokens: 32768, timeout: 300, temperature: 0, thinking_level: 'MEDIUM' }
  )

  text = response[:text] || response[:content]
  abort "Gemini failed: #{response[:error] || 'empty response'}" unless text

  l1_data = JSON.parse(text) rescue nil
  abort "Could not parse Gemini JSON: #{text&.slice(0, 200)}" unless l1_data

  File.write(gemini_cache, JSON.pretty_generate(l1_data))
  puts "Gemini: ok (#{(Time.now - t0).round(1)}s)"
end

# ── Collect descriptions ───────────────────────────────────────────────────────

descriptions = []
(l1_data['standard_types_present'] || []).each do |t|
  d = t['short_description'].to_s.strip
  descriptions << d unless d.empty?
end
(l1_data['custom_types'] || []).each do |t|
  d = t['short_description'].to_s.strip
  descriptions << d unless d.empty?
end
(l1_data['light_sources'] || []).each do |ls|
  d = ls['short_description'].to_s.strip
  descriptions << d unless d.empty?
end
descriptions.uniq!
descriptions.compact!

puts "Descriptions (#{descriptions.size}): #{descriptions.inspect}"

# ── Replicate helpers ──────────────────────────────────────────────────────────

# Submit a prediction and poll until done. Returns output URL or nil.
def replicate_run(conn, api_key, version, input, label, rc)
  resp = conn.post('predictions') do |req|
    req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
    req.body = { version: version, input: input }
  end

  unless resp.success?
    puts "    #{label}: submit error #{resp.status}"
    return nil
  end

  result = JSON.parse(resp.body)

  if %w[starting processing].include?(result['status'])
    poll_url  = result.dig('urls', 'get')
    poll_conn = rc.send(:build_connection, api_key, timeout: 300)
    MAX_POLLS.times do
      sleep POLL_INTERVAL
      pr     = poll_conn.get(poll_url)
      result = JSON.parse(pr.body)
      break unless %w[starting processing].include?(result['status'])
    end
  end

  unless result['status'] == 'succeeded'
    puts "    #{label}: FAILED — #{result['error']}"
    return nil
  end

  output = result['output']
  url    = output.is_a?(Array) ? output.first : output
  return nil unless url.is_a?(String) && url.start_with?('http')

  url
rescue StandardError => e
  puts "    #{label}: exception #{e.message}"
  nil
end

# Compute coverage fraction from a binary mask file (0=bg, 255=fg).
def binary_mask_coverage(mask_path)
  img = Vips::Image.new_from_file(mask_path)
  img = img.extract_band(0) if img.bands > 1
  img.avg / 255.0
rescue StandardError => e
  warn "[coverage] #{e.message}"
  nil
end

# Fill interior holes in a binary mask PNG in-place.
# Uses morphological close (21px) before flood-fill to handle gaps touching the border.
FILL_HOLES_PY = <<~PYTHON.freeze
  import cv2, numpy as np, sys
  path = sys.argv[1]
  mask = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
  if mask is None: sys.exit(0)
  _, mask = cv2.threshold(mask, 128, 255, cv2.THRESH_BINARY)
  # Pass 1: global 15px seal + RETR_CCOMP for small enclosed holes
  kernel_seal = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
  pre_sealed = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel_seal)
  contours, hierarchy = cv2.findContours(pre_sealed, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE)
  filled = mask.copy()
  if hierarchy is not None:
      for i in range(len(contours)):
          if hierarchy[0][i][3] != -1:
              cv2.drawContours(filled, contours, i, 255, -1)
  # Pass 2: per-component proportional close.
  # Gap tolerance scales with the shorter edge of each component's bounding box
  # (15% of it), so a large counter can have bigger gaps closed than a small crate.
  # Each component is closed in isolation so no merging with neighbours.
  num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(filled)
  for i in range(1, num_labels):
      if stats[i, cv2.CC_STAT_AREA] < 200: continue
      bw = stats[i, cv2.CC_STAT_WIDTH]
      bh = stats[i, cv2.CC_STAT_HEIGHT]
      k = max(15, int(min(bw, bh) * 0.15))
      k = k if k % 2 == 1 else k + 1
      x0, y0 = stats[i, cv2.CC_STAT_LEFT], stats[i, cv2.CC_STAT_TOP]
      pad = k
      r0 = max(0, y0 - pad); r1 = min(mask.shape[0], y0 + bh + pad)
      c0 = max(0, x0 - pad); c1 = min(mask.shape[1], x0 + bw + pad)
      comp = (labels[r0:r1, c0:c1] == i).astype(np.uint8) * 255
      kk = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
      closed = cv2.morphologyEx(comp, cv2.MORPH_CLOSE, kk, iterations=2)
      filled[r0:r1, c0:c1] = cv2.bitwise_or(filled[r0:r1, c0:c1], closed)
  kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
  filled = cv2.dilate(filled, kernel, iterations=1)
  cv2.imwrite(path, filled)
PYTHON

def fill_mask_holes_py(mask_path)
  require 'open3'
  _out, err, _st = Open3.capture3('python3', '-c', FILL_HOLES_PY, mask_path)
  warn "[fill_holes] #{err.strip}" unless err.strip.empty?
end

# Build priority composite: paint masks from largest coverage to smallest so the
# most precise (smallest) mask wins any overlapping pixels.
def build_composite(input_path, accepted, composite_path)
  base      = Vips::Image.new_from_file(input_path).extract_band(0, n: 3).cast(:float)
  composite = base.copy

  # Largest coverage first (lowest priority), smallest last (highest priority)
  accepted.sort_by { |r| -(r[:coverage] || 0) }.each do |r|
    next unless r[:mask_path] && File.exist?(r[:mask_path])

    mask      = Vips::Image.new_from_file(r[:mask_path]).cast(:float)
    mask      = mask.extract_band(0) if mask.bands > 1
    mask_norm = mask / 255.0                                           # 0..1, single band
    blend     = mask_norm * COMPOSITE_ALPHA                            # broadcasts across RGB
    color_img = composite.new_from_image(r[:palette][:rgb]).cast(:float)
    # composite + (color - composite) * blend  ≡  composite*(1-blend) + color*blend
    composite = composite + (color_img - composite) * blend
  end

  composite.cast(:uchar).write_to_file(composite_path)
  true
rescue StandardError => e
  warn "[composite] #{e.message}"
  false
end

# ── Step 2 — Run SAMG primary, lang-SAM fallback ───────────────────────────────

results = {}
mutex   = Mutex.new

queue = Queue.new
descriptions.each { |d| queue << d }

threads = Array.new([4, descriptions.size].min) do
  Thread.new do
    loop do
      desc = begin; queue.pop(true); rescue ThreadError; break; end

      safe      = desc.gsub(/[^a-z0-9_-]/i, '_')
      samg_mask = File.join(OUT_DIR, "#{ROOM_ID}_#{safe}_samg.png")
      lang_out  = File.join(OUT_DIR, "#{ROOM_ID}_#{safe}_lang.png")
      mask_out  = File.join(OUT_DIR, "#{ROOM_ID}_#{safe}_mask.png")

      entry = { desc: desc, safe: safe, visual: nil, mask_path: nil,
                model: nil, coverage: nil, fallback: false, rejected: false }

      # ── Primary: SAMG (binary_mask output — pixel-accurate grayscale PNG) ──────
      unless File.exist?(samg_mask)
        puts "  '#{desc}' [samg]: submitting..."
        url = replicate_run(conn, api_key, samg_version,
          { image: data_uri, prompt: desc, output_format: 'binary_mask' },
          "'#{desc}' [samg]", rc)

        if url
          data = URI.open(url, 'rb') { |f| f.read } rescue nil # rubocop:disable Security/Open
          File.binwrite(samg_mask, data) if data
        end
      end

      if File.exist?(samg_mask)
        cov = binary_mask_coverage(samg_mask)
        puts "  '#{desc}' [samg]: coverage #{cov ? "#{(cov * 100).round(1)}%" : 'unknown'}"

        if cov && cov >= MIN_SAMG_COVERAGE
          FileUtils.cp(samg_mask, mask_out)
          fill_mask_holes_py(mask_out)
          entry[:visual]    = samg_mask
          entry[:mask_path] = mask_out
          entry[:model]     = :samg
          entry[:coverage]  = cov
          mutex.synchronize { results[desc] = entry }
          next
        else
          puts "  '#{desc}' [samg]: no detection — falling back to lang-SAM"
        end
      end

      # ── Fallback: lang-segment-anything ──────────────────────────────────────
      entry[:fallback] = true

      unless File.exist?(lang_out)
        puts "  '#{desc}' [lang-SAM fallback]: submitting..."
        url = replicate_run(conn, api_key, lang_version,
          { image: data_uri, text_prompt: desc },
          "'#{desc}' [lang-SAM]", rc)

        if url
          data = URI.open(url, 'rb') { |f| f.read } rescue nil # rubocop:disable Security/Open
          File.binwrite(lang_out, data) if data
        end
      end

      if File.exist?(lang_out)
        # Apply confidence threshold: lang-SAM outputs 0-255 confidence values.
        # Pixels below LANG_SAM_CONF_THRESH are low-confidence and often bleed
        # onto floor/background. Threshold to binary before coverage check.
        thresh_py = <<~PYTHON
          import cv2, numpy as np, sys
          src, dst, t = sys.argv[1], sys.argv[2], int(sys.argv[3])
          m = cv2.imread(src, cv2.IMREAD_GRAYSCALE)
          if m is None: sys.exit(1)
          _, m = cv2.threshold(m, t - 1, 255, cv2.THRESH_BINARY)
          cv2.imwrite(dst, m)
        PYTHON
        thresh_out = lang_out.sub(/\.png$/, '_thresh.png')
        system("python3 -c #{thresh_py.shellescape} #{lang_out.shellescape} #{thresh_out.shellescape} #{LANG_SAM_CONF_THRESH}")
        coverage_src = File.exist?(thresh_out) ? thresh_out : lang_out

        # Coverage guard uses the raw lang output (all detections, not just
        # high-confidence ones) so large-area misdetections are still rejected.
        cov = binary_mask_coverage(lang_out)
        if cov && cov > MAX_MASK_COVERAGE
          puts "  '#{desc}' [lang-SAM]: REJECTED — coverage #{(cov * 100).round(1)}% > #{(MAX_MASK_COVERAGE * 100).round}%"
          entry[:rejected]  = true
          entry[:coverage]  = cov
          entry[:visual]    = lang_out
          entry[:model]     = :lang_sam
        else
          puts "  '#{desc}' [lang-SAM]: ok — coverage #{cov ? "#{(cov * 100).round(1)}%" : 'unknown'} (conf≥#{LANG_SAM_CONF_THRESH})"
          FileUtils.cp(coverage_src, mask_out)
          fill_mask_holes_py(mask_out)
          entry[:visual]    = lang_out
          entry[:mask_path] = mask_out
          entry[:model]     = :lang_sam
          entry[:coverage]  = cov
        end
      else
        puts "  '#{desc}': no result from either model"
        entry[:rejected] = true
      end

      mutex.synchronize { results[desc] = entry }
    end
  end
end
threads.each(&:join)

# ── Step 2b — Grounded SAM: single combined query at dual confidence ───────────
# Uses json_with_masks output with dual detection thresholds.
# Response: { masks: [...], masks_2: [...] }
#   masks   (≥ detection_threshold 0.25) → labeled masks if not already covered by sam2g
#   masks_2 (≥ detection_threshold_2 0.1) → combined low-conf mask (depth deletion only)
# Each entry: { label, confidence, mask_png (base64 grayscale PNG) }

GROUNDED_MODEL        = 'rehbbea/sam2grounded'.freeze
GROUNDED_EXCLUDE_TYPES = %w[door window gate archway opening hatch].freeze

grounded_query          = ''
grounded_results_display = []

grounded_types = []
(l1_data['standard_types_present'] || []).each do |t|
  name = t['type_name'].to_s.strip.downcase
  next if GROUNDED_EXCLUDE_TYPES.any? { |ex| name.include?(ex) }
  grounded_types << t['type_name'].to_s.strip
end
(l1_data['custom_types'] || []).each do |t|
  name = t['type_name'].to_s.strip.downcase
  next if GROUNDED_EXCLUDE_TYPES.any? { |ex| name.include?(ex) }
  next if t['is_exit']
  grounded_types << t['type_name'].to_s.strip
end
grounded_types.uniq!

if grounded_types.any? && GROUNDED_MODEL !~ /TODO/
  grounded_query = grounded_types.map { |t| t.tr('_', ' ') }.join(', ')
  puts "\nGrounded SAM query (#{grounded_types.size} types): #{grounded_query}"

  grounded_version = rc.send(:resolve_model_version, conn, GROUNDED_MODEL)
  abort "Could not resolve #{GROUNDED_MODEL}" unless grounded_version
  puts "#{GROUNDED_MODEL}: #{grounded_version[0..7]}..."

  grounded_cache = File.join(OUT_DIR, "#{ROOM_ID}_grounded.json")
  raw_response   = nil

  if File.exist?(grounded_cache)
    puts 'Grounded SAM: cached'
    raw_response = JSON.parse(File.read(grounded_cache))
  else
    puts 'Grounded SAM: submitting...'
    t0 = Time.now

    grounded_resp = conn.post('predictions') do |req|
      req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
      req.body = { version: grounded_version, input: {
        image: data_uri,
        labels: grounded_query,
        output_format: 'json_with_masks',
        detection_threshold:   0.25,
        detection_threshold_2: 0.15
      }}
    end

    if grounded_resp.success?
      pred = JSON.parse(grounded_resp.body)
      if %w[starting processing].include?(pred['status'])
        poll_url  = pred.dig('urls', 'get')
        poll_conn = rc.send(:build_connection, api_key, timeout: 300)
        MAX_POLLS.times do
          sleep POLL_INTERVAL
          pr   = poll_conn.get(poll_url)
          pred = JSON.parse(pr.body)
          break unless %w[starting processing].include?(pred['status'])
        end
      end
      if pred['status'] == 'succeeded'
        output = pred['output']
        # Output may be the JSON hash directly or a URL to download it
        if output.is_a?(Hash)
          raw_response = output
        elsif output.is_a?(String) && output.start_with?('http')
          raw_response = JSON.parse(URI.open(output, 'rb') { |f| f.read }) rescue nil # rubocop:disable Security/Open
        elsif output.is_a?(Array) && output.first.is_a?(String) && output.first.start_with?('http')
          raw_response = JSON.parse(URI.open(output.first, 'rb') { |f| f.read }) rescue nil # rubocop:disable Security/Open
        end
        File.write(grounded_cache, JSON.generate(raw_response)) if raw_response
      else
        warn "[grounded] prediction failed: #{pred['error']}"
      end
    else
      warn "[grounded] submit failed: HTTP #{grounded_resp.status}"
    end

    n_high = raw_response&.dig('num_masks') || 0
    n_low2 = raw_response&.dig('num_masks_2') || 0
    puts "Grounded SAM: #{n_high} masks (≥0.25), #{n_low2} masks_2 (≥0.1) (#{(Time.now - t0).round(1)}s)"
  end

  if raw_response
    existing_mask_files = results.values
      .reject { |r| r[:rejected] || r[:mask_path].nil? }
      .map { |r| r[:mask_path] }
      .compact
      .select { |p| File.exist?(p) }

    grounded_decode_py = <<~PYTHON
      import sys, json, base64, io, numpy as np
      from PIL import Image
      import cv2
      data_file, out_dir, room_id = sys.argv[1:4]
      existing_p = sys.argv[4:]
      with open(data_file) as f:
          resp = json.load(f)
      existing_masks = []
      for p in existing_p:
          m = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
          if m is not None:
              existing_masks.append((m > 128).astype(bool))
      def overlap_frac(a, b):
          if a.shape != b.shape:
              b = (cv2.resize(b.astype(np.uint8), (a.shape[1], a.shape[0]),
                              interpolation=cv2.INTER_NEAREST) > 0)
          return float(np.logical_and(a, b).sum()) / max(float(a.sum()), 1.0)
      def decode_mask(b64):
          return np.array(Image.open(io.BytesIO(base64.b64decode(b64))).convert('L')) > 128
      output_results = []
      lowconf_combined = None
      lc_idx = 0
      # Process all entries from both arrays.
      # min_confidence_used tells us which threshold bucket the detection belongs to:
      #   >= 0.25 → high-conf object: save labeled mask if not already covered
      #   <  0.25 → low-conf: depth-deletion combined mask + individual display image
      all_entries = list(resp.get('masks') or []) + list(resp.get('masks_2') or [])
      for entry in all_entries:
          label          = str(entry.get('label', 'unknown')).strip()
          confidence     = float(entry.get('confidence', 0))
          min_conf_used  = float(entry.get('min_confidence_used', 0))
          mask_b64       = entry.get('mask_png', '')
          if not mask_b64:
              continue
          mask_np   = decode_mask(mask_b64)
          is_object = min_conf_used >= 0.25   # detection_threshold bucket
          if is_object:
              max_ov  = max((overlap_frac(mask_np, em) for em in existing_masks), default=0.0)
              covered = max_ov > 0.3
              safe    = ''.join(c if c.isalnum() or c in '_-' else '_' for c in label)
              mask_file = None
              if not covered:
                  mask_file = f"{out_dir}/{room_id}_grounded_{safe}_mask.png"
                  cv2.imwrite(mask_file, (mask_np.astype(np.uint8) * 255))
              output_results.append({
                  'label': label, 'confidence': round(confidence, 3),
                  'min_confidence_used': round(min_conf_used, 3),
                  'status': 'covered' if covered else 'new',
                  'mask_file': mask_file,
                  'coverage': round(float(mask_np.sum()) / float(mask_np.size), 4)
              })
          else:
              coverage = float(mask_np.sum()) / float(mask_np.size)
              # Reject low-conf detections covering >1.5% of image (likely walls/floors/false positives)
              rejected_lc = coverage > 0.015
              safe = ''.join(c if c.isalnum() or c in '_-' else '_' for c in label)
              disp_file = f"{out_dir}/{room_id}_grounded_lc_{str(lc_idx).zfill(3)}_{safe}.png"
              cv2.imwrite(disp_file, (mask_np.astype(np.uint8) * 255))
              lc_idx += 1
              if not rejected_lc:
                  if lowconf_combined is None:
                      lowconf_combined = mask_np.copy()
                  elif lowconf_combined.shape == mask_np.shape:
                      np.logical_or(lowconf_combined, mask_np, out=lowconf_combined)
              output_results.append({'label': label, 'confidence': round(confidence, 3),
                                     'min_confidence_used': round(min_conf_used, 3),
                                     'status': 'low_conf_rejected' if rejected_lc else 'low_conf',
                                     'visual_file': disp_file.split('/')[-1],
                                     'coverage': round(coverage, 4)})
      if lowconf_combined is not None:
          lc_path = f"{out_dir}/{room_id}_grounded_lowconf_mask.png"
          cv2.imwrite(lc_path, (lowconf_combined.astype(np.uint8) * 255))
      print(json.dumps(output_results))
    PYTHON

    data_tmpfile = File.join(OUT_DIR, "#{ROOM_ID}_grounded_tmpdata.json")
    File.write(data_tmpfile, JSON.generate(raw_response))
    stdout, stderr, _status = Open3.capture3(
      'python3', '-c', grounded_decode_py,
      data_tmpfile, OUT_DIR, ROOM_ID.to_s, *existing_mask_files
    )
    warn stderr.strip unless stderr.strip.empty?
    FileUtils.rm_f(data_tmpfile)

    grounded_results_display = JSON.parse(stdout.strip) rescue []
    n_new = grounded_results_display.count { |r| r['status'] == 'new' }
    n_cov = grounded_results_display.count { |r| r['status'] == 'covered' }
    n_low = grounded_results_display.count { |r| r['status'] == 'low_conf' }
    puts "Grounded: #{n_new} new masks, #{n_cov} already covered, #{n_low} depth-only (low-conf)"
  end
elsif grounded_types.any?
  puts "Grounded SAM: skipped — set GROUNDED_MODEL constant to enable"
else
  puts 'Grounded SAM: no object types to query (all excluded)'
end

# ── Step 3 — Priority composite ────────────────────────────────────────────────

accepted = results.values.reject { |r| r[:rejected] || r[:mask_path].nil? }

# Add grounded new masks (score≥0.25, not already covered) to composite
grounded_results_display.select { |r| r['status'] == 'new' && r['mask_file'] }.each do |r|
  next unless File.exist?(r['mask_file'].to_s)
  accepted << {
    desc: "grounded:#{r['label']}",
    safe: "grounded_#{r['label'].gsub(/[^a-z0-9_-]/i, '_')}",
    visual: nil,
    mask_path: r['mask_file'],
    model: :grounded,
    coverage: r['coverage'] || 0.01,
    fallback: false,
    rejected: false,
    palette: nil
  }
end

# Assign palette colors in order of coverage ascending (most precise = first color)
accepted_sorted = accepted.sort_by { |r| r[:coverage] || 1.0 }
accepted_sorted.each_with_index { |r, i| r[:palette] = PALETTE[i % PALETTE.size] }

composite_path = File.join(OUT_DIR, "#{ROOM_ID}_composite.png")
if accepted_sorted.any?
  puts "Building priority composite (#{accepted_sorted.size} masks)..."
  if build_composite(input_path, accepted_sorted, composite_path)
    puts "Composite: ok"
  else
    composite_path = nil
  end
end

# ── Step 4 — Generate HTML ─────────────────────────────────────────────────────

input_rel = File.basename(input_path)

def h(str)
  str.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
end

# ── Gemini analysis tables ──

standard_rows = (l1_data['standard_types_present'] || []).map do |t|
  "<tr><td><code>#{h t['type_name']}</code></td><td>#{h t['visual_description']}</td><td class='sq'>#{h t['short_description']}</td></tr>"
end.join

custom_rows = (l1_data['custom_types'] || []).map do |t|
  "<tr><td><code>#{h t['type_name']}</code></td><td>#{h t['visual_description']}</td><td class='sq'>#{h t['short_description']}</td></tr>"
end.join

light_source_rows = (l1_data['light_sources'] || []).map do |ls|
  squares_str = (ls['squares'] || []).join(', ')
  "<tr><td><code>#{h ls['source_type']}</code></td><td>#{h ls['description']}</td><td class='sq'>#{h ls['short_description']}</td><td>#{h squares_str}</td></tr>"
end.join

internal_wall_rows = (l1_data['internal_walls'] || []).map do |w|
  door_label = w['has_door'] ? "Yes (#{h w['door_side']})" : 'No'
  "<tr><td>#{h w['location']}</td><td>#{door_label}</td></tr>"
end.join

perimeter_doors = (l1_data['perimeter_wall_doors'] || []).join(', ')
perimeter_label = l1_data['perimeter_wall'] ? 'Yes' : 'No'

# ── Mask cards ──

mask_cards = descriptions.map do |desc|
  r = results[desc]
  next '' unless r

  safe      = r[:safe]
  visual    = r[:visual] ? File.basename(r[:visual]) : nil
  rejected  = r[:rejected]
  fallback  = r[:fallback]
  coverage  = r[:coverage]
  palette   = r[:palette]
  cov_str   = coverage ? "#{(coverage * 100).round(1)}%" : '—'

  model_label = case r[:model]
                when :samg    then 'SAMG'
                when :lang_sam then 'lang-SAM'
                else '—'
                end

  status_class = rejected ? 'badge-rejected' : (fallback ? 'badge-fallback' : 'badge-primary')
  status_text  = rejected ? 'REJECTED' : (fallback ? "#{model_label} fallback" : model_label)

  swatch = palette ? "<span class='swatch' style='background:#{palette[:hex]}'></span>" : ''

  img_html = if visual && !rejected && File.exist?(File.join(OUT_DIR, visual))
               "<img src='#{visual}' loading='lazy' onclick=\"open_lb('#{visual}','#{h desc}')\">"
             elsif visual && File.exist?(File.join(OUT_DIR, visual))
               "<img src='#{visual}' loading='lazy' class='rejected-img' onclick=\"open_lb('#{visual}','#{h desc} [REJECTED]')\">"
             else
               "<div class='no-result'>No result</div>"
             end

  <<~CARD
    <div class="card #{rejected ? 'card-rejected' : ''}">
      #{img_html}
      <div class="card-meta">
        <span class="badge #{status_class}">#{status_text}</span>
        #{swatch}
        <span class="cov">#{cov_str}</span>
      </div>
      <div class="query">&ldquo;#{h desc}&rdquo;</div>
    </div>
  CARD
end.join("\n")

grounded_html = if grounded_results_display.any?
  def grounded_row(r)
    sc = case r['status']
         when 'new'               then 'badge-primary'
         when 'covered'           then 'badge-fallback'
         when 'low_conf'          then 'badge-warn'
         when 'low_conf_rejected' then 'badge-rejected'
         else ''
         end
    st = case r['status']
         when 'new'               then '&#x2713; new mask'
         when 'covered'           then 'already covered'
         when 'low_conf'          then 'depth-only'
         when 'low_conf_rejected' then 'rejected (&gt;1.5%)'
         else h(r['status'].to_s)
         end
    cov      = r['coverage'] ? "#{(r['coverage'].to_f * 100).round(2)}%" : '—'
    conf     = r['confidence'] ? ('%.3f' % r['confidence'].to_f) : '—'
    min_conf = r['min_confidence_used'] ? ('%.2f' % r['min_confidence_used'].to_f) : '—'
    "<tr><td>#{h r['label'].to_s}</td><td>#{conf}</td><td>#{min_conf}</td><td>#{cov}</td><td><span class='badge #{sc}'>#{st}</span></td></tr>"
  end

  hc_entries = grounded_results_display.reject { |r| r['status'].to_s.start_with?('low_conf') }
  lc_entries = grounded_results_display.select { |r| r['status'].to_s.start_with?('low_conf') }

  hc_rows = hc_entries.map { |r| grounded_row(r) }.join
  lc_rows = lc_entries.map { |r| grounded_row(r) }.join

  lc_cards = lc_entries.map do |r|
    vf = r['visual_file'].to_s
    next '' if vf.empty? || !File.exist?(File.join(OUT_DIR, vf))
    rejected = r['status'] == 'low_conf_rejected'
    cov_pct = r['coverage'] ? "#{(r['coverage'].to_f * 100).round(2)}%" : '—'
    badge_cls = rejected ? 'badge-rejected' : 'badge-warn'
    badge_txt = rejected ? 'rejected' : 'depth-only'
    <<~CARD
      <div class="card #{rejected ? 'card-rejected' : ''}">
        <img src="#{vf}?t=#{Time.now.to_i}" loading="lazy" onclick="open_lb('#{vf}','#{h r['label'].to_s} (#{cov_pct})')">
        <div class="card-meta">
          <span class="badge #{badge_cls}">#{badge_txt}</span>
          <span class="cov">#{h r['label'].to_s} #{cov_pct}</span>
        </div>
      </div>
    CARD
  end.join

  lc_combined_file = "#{ROOM_ID}_grounded_lowconf_mask.png"
  lc_combined_html = if File.exist?(File.join(OUT_DIR, lc_combined_file))
    "<div class='img-card' style='margin-bottom:12px'><img src='#{lc_combined_file}?t=#{Time.now.to_i}' style='max-width:400px;border-radius:6px;cursor:zoom-in;border:2px solid #ffa040' onclick=\"open_lb('#{lc_combined_file}','Low-conf combined depth mask')\"><div style='font-size:12px;color:#ffa040;margin-top:4px'>Combined depth-deletion mask (accepted low-conf only)</div></div>"
  else
    ''
  end

  <<~GROUNDED_SECTION
    <div class="section">
      <h2>Grounded SAM Results</h2>
      <p class="meta-note">
        Query: <em>#{h grounded_query}</em><br>
        min_confidence_used&ge;0.25 and not already covered &rarr; labeled mask.&nbsp;
        min_confidence_used&lt;0.25 &rarr; depth-deletion only (rejected if coverage&gt;1.5%).
      </p>
      #{hc_rows.empty? ? '' : "<h3>High-confidence (&ge;0.25)</h3><table><thead><tr><th>Label</th><th>Confidence</th><th>Min conf used</th><th>Coverage</th><th>Status</th></tr></thead><tbody>#{hc_rows}</tbody></table>"}
      #{lc_rows.empty? ? '' : "<h3>Low-confidence (&lt;0.25)</h3>#{lc_combined_html}<table><thead><tr><th>Label</th><th>Confidence</th><th>Min conf used</th><th>Coverage</th><th>Status</th></tr></thead><tbody>#{lc_rows}</tbody></table><div class='grid' style='margin-top:12px'>#{lc_cards}</div>"}
    </div>
  GROUNDED_SECTION
else
  ''
end

composite_html = if composite_path && File.exist?(composite_path)
  comp_rel = File.basename(composite_path)
  # Legend: smallest coverage first
  legend = accepted_sorted.map do |r|
    cov_str = r[:coverage] ? "#{(r[:coverage] * 100).round(1)}%" : '—'
    "<span class='legend-item'><span class='swatch' style='background:#{r[:palette][:hex]}'></span>#{h r[:desc]} (#{cov_str})</span>"
  end.join(' ')
  <<~COMP
    <div class="section">
      <h2>Priority Composite</h2>
      <p class="meta-note">Smallest coverage wins overlapping pixels. #{accepted_sorted.size} masks, sorted smallest → largest.</p>
      <div class="comp-wrap">
        <img src="#{comp_rel}" loading="lazy" onclick="open_lb('#{comp_rel}','Priority Composite')" class="comp-img">
      </div>
      <div class="legend">#{legend}</div>
    </div>
  COMP
else
  ''
end

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <title>SAMG L1 Probe — Room #{ROOM_ID}</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; padding: 24px; }
      h1 { color: #e94560; margin-bottom: 6px; font-size: 1.6rem; }
      h2 { color: #4ecca3; margin: 24px 0 12px; font-size: 1.15rem; border-bottom: 1px solid #2a2a4e; padding-bottom: 6px; }
      h3 { color: #a0c4ff; margin: 16px 0 8px; font-size: 1rem; }
      .meta { color: #888; font-size: 13px; margin-bottom: 24px; }
      .meta-note { color: #888; font-size: 12px; margin-bottom: 12px; }
      .section { margin-bottom: 32px; }
      .analysis-grid { display: grid; grid-template-columns: 1fr 2fr; gap: 24px; align-items: start; }
      .input-thumb { max-width: 300px; border-radius: 8px; }
      .fact-list { list-style: none; }
      .fact-list li { padding: 4px 0; font-size: 14px; }
      .fact-list li span.label { color: #888; min-width: 140px; display: inline-block; }
      table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }
      th { background: #16213e; color: #4ecca3; text-align: left; padding: 7px 10px; }
      td { padding: 6px 10px; border-bottom: 1px solid #1e1e3a; vertical-align: top; }
      td code { color: #ffd166; font-size: 12px; }
      .sq { color: #4ecca3; font-style: italic; }
      .ref-wrap { margin-bottom: 16px; }
      .ref-wrap img { max-width: 400px; border-radius: 8px; border: 2px solid #4ecca3; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }
      .card { background: #16213e; border-radius: 10px; padding: 12px; }
      .card-rejected { opacity: 0.55; }
      .card img { width: 100%; border-radius: 6px; cursor: zoom-in; }
      .card img.rejected-img { filter: grayscale(60%); }
      .card-meta { display: flex; align-items: center; gap: 8px; margin-top: 8px; }
      .badge { font-size: 11px; padding: 2px 8px; border-radius: 10px; font-weight: 600; }
      .badge-primary  { background: #1a3a5c; color: #4ecca3; }
      .badge-fallback { background: #3a2a1a; color: #ffa040; }
      .badge-rejected { background: #3a1a1a; color: #ff6060; }
      .cov { font-size: 12px; color: #aaa; margin-left: auto; }
      .swatch { display: inline-block; width: 12px; height: 12px; border-radius: 3px; flex-shrink: 0; }
      .query { margin-top: 6px; font-size: 13px; color: #4ecca3; font-style: italic; }
      .no-result { height: 120px; display: flex; align-items: center; justify-content: center; color: #555; background: #0f0f1a; border-radius: 6px; font-size: 13px; }
      .comp-wrap { margin-bottom: 12px; }
      .comp-img { max-width: 600px; border-radius: 8px; cursor: zoom-in; border: 2px solid #2a2a4e; display: block; }
      .legend { display: flex; flex-wrap: wrap; gap: 10px; font-size: 12px; color: #aaa; }
      .legend-item { display: flex; align-items: center; gap: 5px; }
      .lightbox { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.93); z-index: 1000; justify-content: center; align-items: center; flex-direction: column; gap: 12px; }
      .lightbox.active { display: flex; }
      .lightbox img { max-width: 95vw; max-height: 90vh; object-fit: contain; }
      .lb-cap { color: #e0e0e0; font-size: 15px; font-style: italic; }
    </style>
  </head>
  <body>
    <h1>SAMG L1 Probe — #{h room.name} (Room #{ROOM_ID})</h1>
    <p class="meta">
      #{descriptions.size} descriptions &nbsp;|&nbsp;
      #{accepted.size} accepted &nbsp;|&nbsp;
      #{results.values.count { |r| r[:rejected] }} rejected &nbsp;|&nbsp;
      #{results.values.count { |r| r[:fallback] && !r[:rejected] }} lang-SAM fallbacks
    </p>

    <div class="section">
      <h2>Gemini Analysis</h2>
      <div class="analysis-grid">
        <div>
          <img class="input-thumb" src="#{input_rel}" loading="lazy" alt="Input">
        </div>
        <div>
          <ul class="fact-list">
            <li><span class="label">Scene:</span> #{h l1_data['scene_description']}</li>
            <li><span class="label">Walls look like:</span> #{h l1_data['wall_visual']}</li>
            <li><span class="label">Floor looks like:</span> #{h l1_data['floor_visual']}</li>
            <li><span class="label">Lighting:</span> #{h l1_data['lighting_direction']}</li>
            <li><span class="label">Perimeter wall:</span> #{perimeter_label}</li>
            <li><span class="label">Perimeter doors:</span> #{perimeter_doors.empty? ? '(none)' : perimeter_doors}</li>
          </ul>
          #{if (l1_data['internal_walls'] || []).any?
              "<h3>Internal Walls</h3><table><thead><tr><th>Location</th><th>Has Door</th></tr></thead><tbody>#{internal_wall_rows}</tbody></table>"
            else
              '<p style="color:#666;font-size:13px;margin-top:12px;">No internal walls detected.</p>'
            end}
        </div>
      </div>
      #{standard_rows.empty?     ? '' : "<h3>Standard Types</h3><table><thead><tr><th>Type</th><th>Visual Description</th><th>Query</th></tr></thead><tbody>#{standard_rows}</tbody></table>"}
      #{custom_rows.empty?       ? '' : "<h3>Custom Types</h3><table><thead><tr><th>Type</th><th>Visual Description</th><th>Query</th></tr></thead><tbody>#{custom_rows}</tbody></table>"}
      #{light_source_rows.empty? ? '' : "<h3>Light Sources</h3><table><thead><tr><th>Type</th><th>Description</th><th>Query</th><th>Squares</th></tr></thead><tbody>#{light_source_rows}</tbody></table>"}
    </div>

    #{composite_html}

    #{grounded_html}

    <div class="section">
      <h2>Masks</h2>
      <div class="ref-wrap">
        <p style="color:#888;font-size:12px;margin-bottom:6px;">Reference:</p>
        <img src="#{input_rel}" loading="lazy" alt="Reference">
      </div>
      <div class="grid">
        #{mask_cards}
      </div>
    </div>

    <div class="lightbox" id="lb" onclick="close_lb()">
      <img id="lb-img" src="">
      <div class="lb-cap" id="lb-cap"></div>
    </div>
    <script>
      function open_lb(src, cap) {
        document.getElementById('lb-img').src = src;
        document.getElementById('lb-cap').textContent = '\u201c' + cap + '\u201d';
        document.getElementById('lb').classList.add('active');
      }
      function close_lb() { document.getElementById('lb').classList.remove('active'); }
      document.addEventListener('keydown', e => { if (e.key === 'Escape') close_lb(); });
    </script>
  </body>
  </html>
HTML

cache_bust = Time.now.to_i
html = html.gsub(/(<img[^>]+src=['"])([^'"?]+)(['"])/, "\\1\\2?t=#{cache_bust}\\3")
File.write(File.join(OUT_DIR, 'index.html'), html)
puts "HTML written to #{OUT_DIR}/index.html"

served = File.join(__dir__, '../../tmp/battlemap_inspect/samg_l1_probe')
unless File.exist?(served) || File.symlink?(served)
  FileUtils.ln_sf(OUT_DIR, served)
  puts "Symlinked: #{served} → #{OUT_DIR}"
end

puts "\nDone! http://35.196.200.49:8181/samg_l1_probe/index.html"
