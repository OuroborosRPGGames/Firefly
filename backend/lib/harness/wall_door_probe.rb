#!/usr/bin/env ruby
# frozen_string_literal: true

# Wall & Door Detection Probe
#
# Runs CV experiments on cached battle map data to detect walls and doors
# from depth maps with object mask subtraction.
#
# Usage:
#   cd backend
#   bundle exec ruby lib/harness/wall_door_probe.rb [room_id]
#
# Output: lib/harness/wall_door_probe/index.html
# Served: http://35.196.200.49:8181/wall_door_probe/index.html

$stdout.sync = true
require 'base64'
require 'fileutils'
require 'json'
require 'open-uri'
require 'open3'
require 'vips'

require_relative '../../config/room_type_config'
Dir[File.join(__dir__, '../../app/lib/*.rb')].each { |f| require f }
require_relative '../../config/application'

ROOM_ID    = (ARGV[0] || 155).to_i
SAMG_DIR   = File.join(__dir__, 'samg_l1_probe')
OUT_DIR    = File.join(__dir__, 'wall_door_probe')
PYTHON_SCRIPT = File.join(__dir__, '../cv/wall_door_detect.py')
SHADOW_EDGE_SCRIPT = File.join(__dir__, '../cv/shadow_edge_detect.py')

FileUtils.mkdir_p(OUT_DIR)

# ── Validate base inputs ──────────────────────────────────────────────────────

INPUT_IMAGE = File.join(SAMG_DIR, "room_#{ROOM_ID}_input.png")
GEMINI_JSON = File.join(SAMG_DIR, "room_#{ROOM_ID}_gemini.json")

missing = []
missing << "input image (#{INPUT_IMAGE})" unless File.exist?(INPUT_IMAGE)
missing << "gemini JSON (#{GEMINI_JSON})" unless File.exist?(GEMINI_JSON)
unless missing.empty?
  abort "Missing required files:\n  #{missing.join("\n  ")}\n\nRun samg_l1_probe.rb first."
end

# ── Generate depth map from INPUT_IMAGE (cached) ─────────────────────────────

DEPTH_MAP = File.join(OUT_DIR, 'depth_map.png')
unless File.exist?(DEPTH_MAP)
  puts "Generating depth map from input image..."
  abort 'Replicate not available' unless ReplicateDepthService.available?
  result = ReplicateDepthService.estimate(INPUT_IMAGE)
  if result[:success]
    FileUtils.cp(result[:depth_path], DEPTH_MAP)
    puts "Depth map: #{(File.size(DEPTH_MAP) / 1024.0).round}KB"
  else
    abort "Depth generation failed: #{result[:error]}"
  end
else
  puts "Depth map: cached"
end

# ── Generate shadow-aware edge map from INPUT_IMAGE (cached) ─────────────────

EDGE_MAP = File.join(OUT_DIR, 'edge_map.png')
unless File.exist?(EDGE_MAP)
  puts "Generating edge map from input image..."
  stdout, stderr, status = Open3.capture3('python3', SHADOW_EDGE_SCRIPT, INPUT_IMAGE, EDGE_MAP)
  if status.success? && File.exist?(EDGE_MAP)
    puts "Edge map: #{(File.size(EDGE_MAP) / 1024.0).round}KB"
  else
    warn "Edge generation failed: #{stderr.slice(0, 200)}"
    abort "Could not generate edge map"
  end
else
  puts "Edge map: cached"
end

gemini_data = JSON.parse(File.read(GEMINI_JSON))
puts "Room #{ROOM_ID}: #{gemini_data['scene_description']&.slice(0, 80)}"

# ── Build combined object mask ───────────────────────────────────────────────

COMBINED_MASK = File.join(OUT_DIR, "#{ROOM_ID}_combined_objects.png")

masks = Dir[File.join(SAMG_DIR, "#{ROOM_ID}_*_mask.png")]
puts "Found #{masks.size} object masks"

if masks.empty?
  # Create empty black mask matching depth dimensions
  depth_img = Vips::Image.new_from_file(DEPTH_MAP)
  combined = Vips::Image.black(depth_img.width, depth_img.height)
  combined.write_to_file(COMBINED_MASK)
  puts "Created empty object mask (no masks found)"
else
  # OR all masks together, then fill interior holes via Python
  ref = Vips::Image.new_from_file(masks.first)
  combined = ref.extract_band(0) > 128
  masks[1..].each do |path|
    img = Vips::Image.new_from_file(path).extract_band(0) > 128
    combined = combined | img
  end
  # Convert boolean to 0/255
  result = (combined.cast(:uchar)) * 255
  result.write_to_file(COMBINED_MASK)

  # Fill holes: objects on top of other objects leave voids in the combined mask.
  # Pre-close with 21px kernel seals thin channels that connect interior holes to
  # the image border (otherwise the border flood-fill leaks through the channel
  # and treats the interior hole as exterior, skipping it).
  fill_py = <<~PYTHON
    import cv2, numpy as np, sys
    path = sys.argv[1]
    mask = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    _, mask = cv2.threshold(mask, 128, 255, cv2.THRESH_BINARY)
    h, w = mask.shape
    kernel_seal = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    pre_sealed = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel_seal)
    contours, hierarchy = cv2.findContours(pre_sealed, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE)
    filled = mask.copy()
    if hierarchy is not None:
        for i in range(len(contours)):
            if hierarchy[0][i][3] != -1:
                cv2.drawContours(filled, contours, i, 255, -1)
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(filled)
    for i in range(1, num_labels):
        if stats[i, cv2.CC_STAT_AREA] < 200: continue
        bw = stats[i, cv2.CC_STAT_WIDTH]
        bh = stats[i, cv2.CC_STAT_HEIGHT]
        k = max(15, int(min(bw, bh) * 0.15))
        k = k if k % 2 == 1 else k + 1
        x0, y0 = stats[i, cv2.CC_STAT_LEFT], stats[i, cv2.CC_STAT_TOP]
        pad = k
        r0 = max(0, y0 - pad); r1 = min(h, y0 + bh + pad)
        c0 = max(0, x0 - pad); c1 = min(w, x0 + bw + pad)
        comp = (labels[r0:r1, c0:c1] == i).astype(np.uint8) * 255
        kk = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
        closed = cv2.morphologyEx(comp, cv2.MORPH_CLOSE, kk, iterations=2)
        filled[r0:r1, c0:c1] = cv2.bitwise_or(filled[r0:r1, c0:c1], closed)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    filled = cv2.dilate(filled, kernel, iterations=1)
    cv2.imwrite(path, filled)
    white = int(np.sum(filled > 0))
    print(f"Filled: {white} px ({white/(h*w)*100:.1f}%)")
  PYTHON
  stdout, stderr, _status = Open3.capture3('python3', '-c', fill_py, COMBINED_MASK)
  puts stdout.strip unless stdout.strip.empty?
  warn stderr.strip unless stderr.strip.empty?

  puts "Object mask: combined #{masks.size} source masks + hole fill → #{COMBINED_MASK}"
end

# ── Generate cleaned depth (inpainting object regions) ───────────────────────
CLEANED_DEPTH = File.join(OUT_DIR, 'cleaned_depth.png')
unless File.exist?(CLEANED_DEPTH)
  clean_py = <<~PYTHON
    import cv2, numpy as np, sys
    depth = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
    mask = cv2.imread(sys.argv[2], cv2.IMREAD_GRAYSCALE)
    _, mask = cv2.threshold(mask, 128, 255, cv2.THRESH_BINARY)
    if mask is None or depth is None:
        import shutil; shutil.copy(sys.argv[1], sys.argv[3])
    else:
        inpaint_mask = (mask > 0).astype(np.uint8)
        cleaned = cv2.inpaint(depth, inpaint_mask, inpaintRadius=15, flags=cv2.INPAINT_TELEA)
        cv2.imwrite(sys.argv[3], cleaned)
        changed = int(np.sum(mask > 0))
        h, w = depth.shape
        print(f"Cleaned depth: inpainted {changed} px ({changed/(h*w)*100:.1f}%) using TELEA")
  PYTHON
  stdout, stderr, _status = Open3.capture3('python3', '-c', clean_py, DEPTH_MAP, COMBINED_MASK, CLEANED_DEPTH)
  puts stdout.strip unless stdout.strip.empty?
  warn stderr.strip unless stderr.strip.empty?
end

# ── Define experiments ───────────────────────────────────────────────────────

EXPERIMENTS = [
  # wall_extract: each run shows both CLAHE+Sobel (primary) and Otsu (fallback)
  # sobel_thresh: lower = more edges detected (noisier), higher = only strong transitions
  # close_px: closing kernel size for filling Sobel edge bands into solid walls
  { name: 'wall_extract', params: { sobel_thresh: 15, close_px: 20 } },
  { name: 'wall_extract', params: { sobel_thresh: 25, close_px: 30 } },
  { name: 'wall_extract', params: { sobel_thresh: 40, close_px: 40 } },
  { name: 'wall_extract', params: { sobel_thresh: 25, close_px: 60 } },
  { name: 'contour_analysis', params: {} },
  # door_thinning runs all 4 rules: thin_section, door_posts, edge_pairs
  { name: 'door_thinning', params: { thin_ratio: 0.3 } },
  { name: 'door_thinning', params: { thin_ratio: 0.5 } },
  { name: 'door_thinning', params: { thin_ratio: 0.7 } },
  # door_gap: rule 4 (interruptions)
  { name: 'door_gap', params: { max_gap_px: 10 } },
  { name: 'door_gap', params: { max_gap_px: 20 } },
  { name: 'door_gap', params: { max_gap_px: 40 } },
  { name: 'connectivity', params: {} },
  { name: 'llm_verify', params: { angular_tolerance: 45 } },
  # shape_detect: dual D+G pipeline, polygon perimeter fit, HoughLines inner walls, gap+thinning doors
  { name: 'shape_detect', params: { thin_ratio: 0.5 } },
].freeze

# ── Run experiments ──────────────────────────────────────────────────────────

results = {}

EXPERIMENTS.each do |exp|
  param_hash = exp[:params].sort.map { |k, v| "#{k}#{v}" }.join('_')
  dir_name = "exp_#{exp[:name]}_#{param_hash}"
  exp_dir = File.join(OUT_DIR, dir_name)
  results_file = File.join(exp_dir, 'results.json')

  exp[:dir_name] = dir_name
  exp[:exp_dir] = exp_dir

  # Cache check
  if File.exist?(results_file)
    puts "[cached] #{exp[:name]} (#{exp[:params]})"
    results[dir_name] = JSON.parse(File.read(results_file))
    next
  end

  FileUtils.mkdir_p(exp_dir)
  puts "[run] #{exp[:name]} (#{exp[:params]})..."

  cmd = [
    'python3', PYTHON_SCRIPT,
    '--image', INPUT_IMAGE,
    '--depth', DEPTH_MAP,
    '--edges', EDGE_MAP,
    '--object-mask', COMBINED_MASK,
    '--gemini', GEMINI_JSON,
    '--output-dir', exp_dir,
    '--experiment', exp[:name],
    '--params', exp[:params].to_json,
  ]

  stdout, stderr, status = Open3.capture3(*cmd)
  puts stdout unless stdout.strip.empty?
  warn stderr unless stderr.strip.empty?

  unless status.success?
    warn "  FAILED (exit #{status.exitstatus})"
    results[dir_name] = { 'error' => "exit #{status.exitstatus}", 'stderr' => stderr.slice(0, 500) }
    next
  end

  if File.exist?(results_file)
    results[dir_name] = JSON.parse(File.read(results_file))
  else
    warn "  WARNING: no results.json produced"
    results[dir_name] = { 'error' => 'no results.json' }
  end
end


# ── Gemini color annotation ───────────────────────────────────────────────────

GEMINI_COLORMAP_DIR    = File.join(OUT_DIR, 'gemini_colormap')
GEMINI_COLORMAP_IMG    = File.join(GEMINI_COLORMAP_DIR, 'colormap_raw.png')
GEMINI_COLORMAP_RESULT = File.join(GEMINI_COLORMAP_DIR, 'results.json')
COLORMAP_SCRIPT        = File.join(__dir__, '../cv/gemini_colormap_analyze.py')

FileUtils.mkdir_p(GEMINI_COLORMAP_DIR)

has_inner_walls = !gemini_data['internal_walls'].to_a.empty?

unless File.exist?(GEMINI_COLORMAP_IMG)
  gemini_key = AIProviderService.api_key_for('google_gemini')
  if gemini_key
    puts "Gemini colormap: calling image generation API..."
    prompt = if has_inner_walls
      'Can you turn the inner room walls for the room map to bright green, change any doors in the inner room walls to bright pink. Change the outer walls to bright blue and change any outer doors to bright red.'
    else
      'Can you change the outer walls to bright blue and change any outer doors to bright red.'
    end
    img_b64 = Base64.strict_encode64(File.binread(INPUT_IMAGE))
    require 'faraday'
    conn = Faraday.new do |c|
      c.request :json; c.response :json, content_type: /\bjson$/; c.adapter Faraday.default_adapter; c.options.timeout = 180
    end
    model    = 'gemini-3.1-flash-image-preview'
    endpoint = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{gemini_key}"
    body = { contents: [{ parts: [{ inlineData: { mimeType: 'image/png', data: img_b64 } }, { text: prompt }] }],
             generationConfig: { responseModalities: ['TEXT', 'IMAGE'], temperature: 0.0 } }
    resp = conn.post(endpoint, body)
    if resp.success?
      parts = resp.body.dig('candidates', 0, 'content', 'parts') || []
      img_part = parts.find { |p| (p.dig('inlineData', 'mimeType') || p.dig('inline_data', 'mimeType') || '').start_with?('image/') }
      if img_part
        inline = img_part['inlineData'] || img_part['inline_data']
        File.binwrite(GEMINI_COLORMAP_IMG, Base64.decode64(inline['data']))
        puts "  Saved colormap: #{(File.size(GEMINI_COLORMAP_IMG) / 1024.0).round}KB"
      else
        warn "  Gemini colormap: no image in response"
      end
    else
      warn "  Gemini colormap API error #{resp.status}"
    end
  else
    warn "  Gemini colormap: no API key"
  end
end

if File.exist?(GEMINI_COLORMAP_IMG) && !File.exist?(GEMINI_COLORMAP_RESULT)
  puts "Gemini colormap: running pixel analysis..."
  object_mask_path = File.join(OUT_DIR, "#{ROOM_ID}_combined_objects.png")
  cmd = ['python3', COLORMAP_SCRIPT,
         '--original', INPUT_IMAGE, '--colormap', GEMINI_COLORMAP_IMG,
         '--output-dir', GEMINI_COLORMAP_DIR,
         '--has-inner-walls', has_inner_walls ? '1' : '0']
  cmd += ['--object-mask', object_mask_path] if File.exist?(object_mask_path)
  stdout, stderr, status = Open3.capture3(*cmd)
  puts stdout.strip unless stdout.strip.empty?
  warn stderr.strip unless stderr.strip.empty?
end

colormap_results = File.exist?(GEMINI_COLORMAP_RESULT) ? JSON.parse(File.read(GEMINI_COLORMAP_RESULT)) : {}
puts "Gemini colormap: #{File.exist?(GEMINI_COLORMAP_RESULT) ? 'cached' : 'no results'}"

# ── Generate HTML ────────────────────────────────────────────────────────────

def h(str)
  str.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
end

def img_tag(dir_name, filename, label = nil)
  path = File.join(OUT_DIR, dir_name, filename)
  return '' unless File.exist?(path)

  rel = "#{dir_name}/#{filename}"
  cap = label || filename
  "<img src='#{rel}' loading='lazy' onclick=\"open_lb('#{rel}','#{h(cap)}')\" class='probe-img'>"
end

def metric_row(label, value, unit = '')
  "<tr><td class='label'>#{h label}</td><td>#{h value.to_s}#{unit}</td></tr>"
end

# ── Input summary section
input_section = <<~HTML
  <div class="section">
    <h2>Input Data</h2>
    <div class="img-row">
      <div class="img-card">
        <img src="#{File.basename(INPUT_IMAGE)}" loading="lazy" onclick="open_lb('#{File.basename(INPUT_IMAGE)}','Original')" class="probe-img">
        <div class="img-label">Original</div>
      </div>
      <div class="img-card">
        <img src="depth_map.png" loading="lazy" class="probe-img"
             onclick="open_lb('depth_map.png','Depth Map')">
        <div class="img-label">Depth Map</div>
      </div>
      <div class="img-card">
        <img src="edge_map.png" loading="lazy" class="probe-img"
             onclick="open_lb('edge_map.png','Edge Map')">
        <div class="img-label">Edge Map</div>
      </div>
      <div class="img-card">
        <img src="#{ROOM_ID}_combined_objects.png" loading="lazy"
             onclick="open_lb('#{ROOM_ID}_combined_objects.png','Combined Object Mask')" class="probe-img">
        <div class="img-label">Object Mask (#{masks.size} masks)</div>
      </div>
      <div class="img-card">
        <img src="cleaned_depth.png" loading="lazy"
             onclick="open_lb('cleaned_depth.png','Depth — Objects Inpainted')" class="probe-img">
        <div class="img-label">Depth (objects inpainted)</div>
      </div>
    </div>
    <div class="llm-summary">
      <h3>LLM Analysis</h3>
      <table>
        #{metric_row('Scene', gemini_data['scene_description'])}
        #{metric_row('Walls', gemini_data['wall_visual'])}
        #{metric_row('Floor', gemini_data['floor_visual'])}
        #{metric_row('Perimeter Wall', gemini_data['perimeter_wall'] ? 'Yes' : 'No')}
        #{metric_row('Perimeter Doors', (gemini_data['perimeter_wall_doors'] || []).join(', '))}
        #{metric_row('Internal Walls', (gemini_data['internal_walls'] || []).map { |w| "#{w['location']}#{w['has_door'] ? " (door #{w['door_side']})" : ' (no door)'}" }.join('; '))}
      </table>
    </div>
  </div>
HTML

# Copy input image to output dir for relative HTML paths
FileUtils.cp(INPUT_IMAGE, File.join(OUT_DIR, File.basename(INPUT_IMAGE))) unless File.exist?(File.join(OUT_DIR, File.basename(INPUT_IMAGE)))
# depth_map.png and edge_map.png are already written directly to OUT_DIR above

# ── Wall extraction comparison
wall_exps = EXPERIMENTS.select { |e| e[:name] == 'wall_extract' }
wall_section = <<~HTML
  <div class="section">
    <h2>Wall Detection — CLAHE+Sobel+Ring-Fill vs Otsu Threshold</h2>
    <p class="meta-note">
      Primary (CLAHE+Sobel): rescale → gamma γ=0.4 → CLAHE → bilateral → Sobel → directional close (H+V) → isotropic close → RETR_CCOMP ring fill → wall ring.<br>
      Fallback (Otsu): depth threshold on interior pixels after object subtraction.<br>
      sobel_thresh controls Sobel sensitivity; close_px fills Sobel bands into solid wall bodies.
    </p>
    <h3>CLAHE+Sobel Results</h3>
    <div class="img-row">
      #{wall_exps.map { |e|
        r = results[e[:dir_name]] || {}
        st = e[:params][:sobel_thresh]; cp = e[:params][:close_px]
        label = "sobel=#{st} close=#{cp}"
        <<~CARD
          <div class="img-card">
            #{img_tag(e[:dir_name], 'wall_overlay_clahe.png', "CLAHE #{label}")}
            <div class="img-label">CLAHE #{label}</div>
            <table class="mini-metrics">
              #{metric_row('Wall %', "#{((r['clahe_wall_area_fraction'] || 0) * 100).round(1)}%")}
              #{metric_row('Components', r['clahe_num_components'])}
              #{metric_row('Largest', "#{((r['clahe_largest_component_frac'] || 0) * 100).round(1)}%")}
              #{metric_row('Dir close px', r['clahe_dir_close_px'])}
            </table>
          </div>
        CARD
      }.join}
    </div>
    <h3>Otsu Depth Threshold Results (fallback)</h3>
    <div class="img-row">
      #{wall_exps.map { |e|
        r = results[e[:dir_name]] || {}
        st = e[:params][:sobel_thresh]
        <<~CARD
          <div class="img-card">
            #{img_tag(e[:dir_name], 'wall_overlay_otsu.png', "Otsu sobel=#{st}")}
            <div class="img-label">Otsu (sobel=#{st} run)</div>
            <table class="mini-metrics">
              #{metric_row('Wall %', "#{((r['otsu_wall_area_fraction'] || 0) * 100).round(1)}%")}
              #{metric_row('Components', r['otsu_num_components'])}
              #{metric_row('Floor peak', r['floor_peak'])}
              #{metric_row('Otsu thresh', r['otsu_thresh'])}
              #{metric_row('Inverted', r['depth_inverted'] ? 'yes' : 'no')}
            </table>
          </div>
        CARD
      }.join}
    </div>
    <h3>Zone Maps — CLAHE (dark=off_map, red=wall, tan=floor)</h3>
    <div class="img-row">
      #{wall_exps.map { |e|
        st = e[:params][:sobel_thresh]; cp = e[:params][:close_px]
        <<~CARD
          <div class="img-card">
            #{img_tag(e[:dir_name], 'zone_colorized_clahe.png', "Zones sobel=#{st} close=#{cp}")}
            <div class="img-label">sobel=#{st} close=#{cp}</div>
          </div>
        CARD
      }.join}
    </div>
    <h3>CLAHE Pipeline (first experiment)</h3>
    <div class="img-row">
      <div class="img-card">
        #{img_tag(wall_exps.first[:dir_name], 'enhanced_depth.png', 'Enhanced (rescale→gamma→CLAHE)')}
        <div class="img-label">Enhanced (rescale→γ→CLAHE)</div>
      </div>
      <div class="img-card">
        #{img_tag(wall_exps.first[:dir_name], 'sobel_gradient.png', 'Sobel Gradient')}
        <div class="img-label">Sobel Gradient</div>
      </div>
    </div>
  </div>
HTML

# ── Contour analysis
contour_exp = EXPERIMENTS.find { |e| e[:name] == 'contour_analysis' }
contour_r = results[contour_exp[:dir_name]] || {}
internal_blobs_html = (contour_r['internal_blobs'] || []).map { |iw|
  match_badge = iw['llm_match'] ? "<span class='badge badge-ok'>LLM match</span>" : "<span class='badge badge-warn'>no LLM match</span>"
  elongated_badge = iw['is_elongated'] ? "<span class='badge badge-ok'>elongated</span>" : "<span class='badge badge-warn'>compact</span>"
  "<tr><td>#{h iw['direction'].to_s}</td><td>#{iw['area']}</td><td>#{iw['aspect_ratio']}</td><td>#{elongated_badge} #{match_badge}</td></tr>"
}.join

contour_section = <<~HTML
  <div class="section">
    <h2>Contour Analysis — Perimeter vs Internal Walls</h2>
    <p class="meta-note">
      Perimeter blobs = elevated regions touching the off-map exterior (blue).<br>
      Internal blobs = elevated regions inside the perimeter, not touching exterior (yellow if elongated, grey if compact).<br>
      LLM expected locations shown as circles — matched to actual spatial position, not 3x3 quadrants.
    </p>
    <div class="img-row">
      <div class="img-card wide">
        #{img_tag(contour_exp[:dir_name], 'contour_overlay.png', 'Contour Analysis')}
        <div class="img-label">Blue=perimeter blobs, Yellow=elongated internal, Grey=compact internal, Cyan circles=LLM expected</div>
      </div>
    </div>
    <table>
      #{metric_row('Perimeter blobs', contour_r['num_perimeter_blobs'])}
      #{metric_row('Internal blobs (total)', contour_r['num_internal_blobs'])}
      #{metric_row('LLM internal locations', (contour_r['llm_internal_locations'] || []).join(', '))}
      #{metric_row('Floor peak', contour_r['floor_peak'])}
      #{metric_row('Off-map tolerance', "#{contour_r['off_map_tolerance']}px")}
    </table>
    #{if internal_blobs_html.empty?
        '<p class="meta-note">No internal wall candidates found (area > 200px).</p>'
      else
        "<h3>Internal Wall Candidates (area > 200px)</h3><table><thead><tr><th>Direction</th><th>Area</th><th>Aspect Ratio</th><th>Status</th></tr></thead><tbody>#{internal_blobs_html}</tbody></table>"
      end}
  </div>
HTML

# ── Door thinning
thin_exps = EXPERIMENTS.select { |e| e[:name] == 'door_thinning' }
thin_section = <<~HTML
  <div class="section">
    <h2>Door Detection — 4-Rule Combined</h2>
    <p class="meta-note">
      Rule 1 (thin section): skeleton thickness local minima<br>
      Rule 2 (door posts): paired compact blobs with passable gap (green=posts, no objects in gap)<br>
      Rule 3 (edge pairs): facing skeleton endpoints with opposite wall directions<br>
      Cyan=thin points, circles=candidates (g=thin r2=posts b=edge-pair)
    </p>
    <h3>Wall + Door Overlay (room image with detected walls and candidates)</h3>
    <div class="img-row">
      #{thin_exps.map { |e|
        ratio = e[:params][:thin_ratio]
        <<~CARD
          <div class="img-card">
            #{img_tag(e[:dir_name], 'wall_door_overlay.png', "Wall+Door Overlay ratio=#{ratio}")}
            <div class="img-label">Wall+door overlay (ratio=#{ratio})</div>
          </div>
        CARD
      }.join}
    </div>
    <h3>Skeleton + Thin Points (distance-transform heatmap on skeleton)</h3>
    <div class="img-row">
      #{thin_exps.map { |e|
        r = results[e[:dir_name]] || {}
        ratio = e[:params][:thin_ratio]
        candidates = (r['candidates'] || [])
        cand_summary = candidates.map { |c| "#{c['type'][0]}:#{c['direction']}(#{c['score']})" }.join(', ')
        <<~CARD
          <div class="img-card">
            #{img_tag(e[:dir_name], 'door_thinning.png', "Door rules ratio=#{ratio}")}
            <div class="img-label">thin_ratio=#{ratio}</div>
            <table class="mini-metrics">
              #{metric_row('Median wall thickness', "#{r['median_wall_thickness']}px")}
              #{metric_row('Rule 1 (thin section)', r['rule1_thin_section'])}
              #{metric_row('Rule 2 (door posts)', r['rule2_door_posts'])}
              #{metric_row('Rule 3 (edge pairs)', r['rule3_edge_pairs'])}
              #{metric_row('Merged candidates', r['num_candidates'])}
              #{metric_row('Floor peak', r['floor_peak'])}
            </table>
            <div class="candidates-list">#{cand_summary.empty? ? '(none)' : h(cand_summary)}</div>
          </div>
        CARD
      }.join}
    </div>
  </div>
HTML

# ── Door gap
gap_exps = EXPERIMENTS.select { |e| e[:name] == 'door_gap' }
gap_section = <<~HTML
  <div class="section">
    <h2>Door Detection — Contour Gaps</h2>
    <p class="meta-note">Skeleton endpoints and gaps = potential doors. Red dots=endpoints, circles=gaps.</p>
    <div class="img-row">
      #{gap_exps.map { |e|
        r = results[e[:dir_name]] || {}
        max_gap = e[:params][:max_gap_px]
        gaps_list = (r['gaps'] || [])
        gap_summary = gaps_list.select { |g| g['point2'] }.map { |g| "#{g['direction']}(w=#{g['gap_width']})" }.join(', ')
        <<~CARD
          <div class="img-card">
            #{img_tag(e[:dir_name], 'door_gaps.png', "Gap max=#{max_gap}px")}
            <div class="img-label">max_gap=#{max_gap}px</div>
            <table class="mini-metrics">
              #{metric_row('Endpoints', r['num_endpoints'])}
              #{metric_row('Paired gaps', r['num_gaps'])}
              #{metric_row('Isolated', r['num_isolated'])}
            </table>
            <div class="candidates-list">#{gap_summary.empty? ? '(none)' : gap_summary}</div>
          </div>
        CARD
      }.join}
    </div>
  </div>
HTML

# ── Connectivity
conn_exp = EXPERIMENTS.find { |e| e[:name] == 'connectivity' }
conn_r = results[conn_exp[:dir_name]] || {}
conn_components = (conn_r['components'] || []).map { |c|
  "<tr><td>#{c['id']}</td><td>#{c['size']}</td><td>#{c['centroid']&.map { |v| v.round(0) }&.join(', ')}</td></tr>"
}.join
punch_html = (conn_r['punch_points'] || []).map { |p|
  "<tr><td>#{p['point'].join(', ')}</td><td>#{p['wall_thickness']}px</td><td>Components #{p['between_components'].join(' ↔ ')}</td></tr>"
}.join

connectivity_section = <<~HTML
  <div class="section">
    <h2>Floor Connectivity</h2>
    <div class="img-row">
      <div class="img-card wide">
        #{img_tag(conn_exp[:dir_name], 'connectivity.png', 'Connectivity')}
        <div class="img-label">Floor regions on room image — #{conn_r['is_connected'] ? '✓ Connected' : "✗ #{conn_r['num_floor_components']} disconnected regions"}</div>
      </div>
      <div class="img-card wide">
        #{img_tag(conn_exp[:dir_name], 'zone_overlay.png', 'Zone Overlay')}
        <div class="img-label">Wall zone overlay (dark=off_map, red=wall, tan=floor)</div>
      </div>
    </div>
    <h3>Components</h3>
    <table><thead><tr><th>ID</th><th>Size (px)</th><th>Centroid</th></tr></thead><tbody>#{conn_components}</tbody></table>
    #{unless punch_html.empty?
        "<h3>Suggested Punch-Through Points</h3><table><thead><tr><th>Point</th><th>Wall Thickness</th><th>Between</th></tr></thead><tbody>#{punch_html}</tbody></table>"
      end}
  </div>
HTML

# ── LLM verification
verify_exp = EXPERIMENTS.find { |e| e[:name] == 'llm_verify' }
verify_r = results[verify_exp[:dir_name]] || {}
suggestions_html = (verify_r['suggestions'] || []).map { |s|
  "<tr><td>#{h s['direction']}</td><td>#{s['suggested_point']&.join(', ')}</td><td>#{s['wall_thickness_at_point']}px</td><td>#{h s['reason']}</td></tr>"
}.join

verify_section = <<~HTML
  <div class="section">
    <h2>LLM Verification</h2>
    <div class="img-row">
      <div class="img-card wide">
        #{img_tag(verify_exp[:dir_name], 'llm_verify.png', 'LLM Verification')}
        <div class="img-label">Green=matched, Orange=spurious, Red=LLM expected but missing</div>
      </div>
    </div>
    <table>
      #{metric_row('Match score', "#{((verify_r['match_score'] || 0) * 100).round(0)}%")}
      #{metric_row('Matched', (verify_r['matched'] || []).join(', '))}
      #{metric_row('Unmatched (LLM expects)', (verify_r['unmatched_llm'] || []).join(', '))}
      #{metric_row('Spurious (detected, no LLM)', (verify_r['spurious_detected'] || []).join(', '))}
      #{metric_row('LLM perimeter doors', (verify_r['llm_perimeter_doors'] || []).join(', '))}
      #{metric_row('LLM internal doors', (verify_r['llm_internal_doors'] || []).join(', '))}
    </table>
    #{unless suggestions_html.empty?
        "<h3>Suggestions for Unmatched Doors</h3><table><thead><tr><th>Direction</th><th>Point</th><th>Wall Thickness</th><th>Reason</th></tr></thead><tbody>#{suggestions_html}</tbody></table>"
      end}
  </div>
HTML

# ── Shape detect section
shape_exp = EXPERIMENTS.find { |e| e[:name] == 'shape_detect' }
shape_r   = results[shape_exp[:dir_name]] || {}
shape_doors = shape_r['doors'] || []
shape_inner = shape_r['inner_segs'] || shape_r['inner_walls'] || []
shape_poly  = shape_r.dig('outer_perimeter', 'poly_pts') || []

shape_door_rows = shape_doors.map { |d|
  match_badge = d['llm_match'] ? "<span class='badge badge-ok'>LLM match</span>" : "<span class='badge badge-warn'>no LLM match</span>"
  "<tr><td>#{h d['direction']}</td><td>#{d['x']}, #{d['y']}</td><td>#{'%.2f' % d['score']}</td><td>#{h d['rule']}</td><td>#{h d['wall']}</td><td>#{match_badge}</td></tr>"
}.join

shape_section = <<~HTML
  <div class="section">
    <h2>Shape Detection (dual D+G pipeline)</h2>
    <p class="meta-note">D: Gamma=0.3 Sobel=15 (all walls, some external noise) &nbsp;+&nbsp; G: Gamma=0.4 Bilateral Median Sobel=20 (clean, slight inner gaps). Combined = G primary, D fills interior gaps.</p>
    <div class="img-row">
      <div class="img-card">
        #{img_tag(shape_exp[:dir_name], 'shape_wall_D.png', 'Pipeline D wall mask')}
        <div class="img-label">D wall mask (gamma=0.3, sob=15)</div>
      </div>
      <div class="img-card">
        #{img_tag(shape_exp[:dir_name], 'shape_wall_G.png', 'Pipeline G wall mask')}
        <div class="img-label">G wall mask (gamma=0.4, median+bil, sob=20)</div>
      </div>
      <div class="img-card">
        #{img_tag(shape_exp[:dir_name], 'shape_wall_combined.png', 'Combined D+G wall mask')}
        <div class="img-label">Combined wall mask</div>
      </div>
      <div class="img-card">
        #{img_tag(shape_exp[:dir_name], 'shape_perim_poly.png', 'Perimeter polygon')}
        <div class="img-label">Outer perimeter (#{shape_poly.size} vertices)</div>
      </div>
    </div>
    <div class="img-row">
      <div class="img-card">
        #{img_tag(shape_exp[:dir_name], 'shape_skeleton_raw.png', 'Raw skeleton')}
        <div class="img-label">Wall skeleton (HoughLinesP source)</div>
      </div>
      <div class="img-card">
        #{img_tag(shape_exp[:dir_name], 'shape_segments.png', 'Hough segments')}
        <div class="img-label">Hough segments (cyan=outer, green=inner)</div>
      </div>
      <div class="img-card wide">
        #{img_tag(shape_exp[:dir_name], 'shape_doors.png', 'Shape detect doors')}
        <div class="img-label">Doors detected: green=LLM match, orange=not in LLM, red=LLM expected but missing</div>
      </div>
    </div>
    <table>
      #{metric_row('Perimeter polygon sides', shape_poly.size)}
      #{metric_row('Inner wall segments (Hough)', shape_inner.size)}
      #{metric_row('Door candidates', shape_doors.size)}
      #{metric_row('LLM perimeter doors', (shape_r.dig('llm', 'perimeter_wall_doors') || []).join(', '))}
    </table>
    #{unless shape_door_rows.empty?
        "<h3>Door Candidates</h3><table><thead><tr><th>Direction</th><th>Position</th><th>Score</th><th>Rule</th><th>Wall</th><th>LLM</th></tr></thead><tbody>#{shape_door_rows}</tbody></table>"
      end}
  </div>
HTML

# ── Summary verdict
best_wall = wall_exps.min_by { |e|
  r = results[e[:dir_name]] || {}
  # Prefer fewest CLAHE components (most consolidated wall detection)
  n = (r['clahe_num_components'] || r['num_components'] || 999)
  large = r['clahe_largest_component_frac'] || r['largest_component_frac'] || 0
  n + (1.0 - large) * 10
}
best_wall_r = results[best_wall[:dir_name]] || {}

thin_candidates = thin_exps.flat_map { |e| (results[e[:dir_name]] || {})['candidates'] || [] }
gap_candidates = gap_exps.flat_map { |e| (results[e[:dir_name]] || {})['gaps'] || [] }.select { |g| g['point2'] }

all_door_dirs = (thin_candidates.map { |c| c['direction'] } + gap_candidates.map { |g| g['direction'] }).uniq

clahe_n = best_wall_r['clahe_num_components'] || best_wall_r['num_components'] || '?'
clahe_large = ((best_wall_r['clahe_largest_component_frac'] || best_wall_r['largest_component_frac'] || 0) * 100).round(1)

summary_section = <<~HTML
  <div class="section verdict">
    <h2>Summary</h2>
    <table>
      #{metric_row('Best CLAHE setting', "sobel=#{best_wall[:params][:sobel_thresh]} close=#{best_wall[:params][:close_px]} (#{clahe_n} components, largest #{clahe_large}%)")}
      #{metric_row('Floor peak / Otsu', "#{best_wall_r['floor_peak']} / #{best_wall_r['otsu_thresh']}")}
      #{metric_row('Depth inverted', best_wall_r['depth_inverted'] ? 'yes' : 'no')}
      #{metric_row('Floor connected', conn_r['is_connected'] ? 'Yes' : "No (#{conn_r['num_floor_components']} regions)")}
      #{metric_row('Door candidates (4 rules)', thin_candidates.map { |c| "#{c['type'][0]}:#{c['direction']}(#{c['score']})" }.uniq.join(', '))}
      #{metric_row('Door candidates (gaps)', gap_candidates.map { |g| "#{g['direction']}(w=#{g['gap_width']})" }.uniq.join(', '))}
      #{metric_row('All door directions', all_door_dirs.join(', '))}
      #{metric_row('LLM match score', "#{((verify_r['match_score'] || 0) * 100).round(0)}%")}
    </table>
  </div>
HTML

# ── Gemini colormap section ──────────────────────────────────────────────────

outer_gaps = colormap_results['outer_gaps'] || []
inner_gaps = colormap_results['inner_gaps'] || []
conn_info  = colormap_results['connectivity'] || {}
punch_pts  = conn_info['punch_points'] || []

gemini_colormap_section = if File.exist?(File.join(GEMINI_COLORMAP_DIR, 'colormap_annotated.png'))
  lc = colormap_results['label_counts'] || {}
  gap_rows = (outer_gaps + inner_gaps).map do |g|
    kind = outer_gaps.include?(g) ? 'outer' : 'inner'
    "<tr><td class='label'>#{kind} gap</td><td>(#{g['cx']}, #{g['cy']}) len=#{g['length']} axis=#{g['axis']==0 ? 'H' : 'V'}</td></tr>"
  end.join
  punch_rows = punch_pts.map do |p|
    warn_flag = p['near_object'] ? ' ⚠ near object' : ''
    "<tr><td class='label'>punch (#{p['wall_type']})</td><td>(#{p['point']&.join(', ')}) thickness=#{p['wall_thickness']}#{warn_flag}</td></tr>"
  end.join

  <<~HTML
    <div class="section">
      <h2>Gemini Colormap Analysis</h2>
      <p class="meta-note">
        Gemini Flash image generator recolors walls/doors by semantic role:<br>
        <span style="color:#00c800">■ green</span> inner wall &nbsp;
        <span style="color:#ff00ff">■ pink/magenta</span> inner door &nbsp;
        <span style="color:#0080ff">■ blue</span> outer wall &nbsp;
        <span style="color:#ff4040">■ red</span> outer door
      </p>
      <div class="img-row">
        <div class="img-card">
          #{img_tag('gemini_colormap', 'colormap_raw.png', 'Gemini Output (raw)')}
          <div class="img-label">Gemini Output (raw)</div>
        </div>
        <div class="img-card">
          #{img_tag('gemini_colormap', 'colormap_resized.png', 'Resized to Original Dims')}
          <div class="img-label">Resized to Original</div>
        </div>
        <div class="img-card">
          #{img_tag('gemini_colormap', 'colormap_classify.png', 'Pixel Classification')}
          <div class="img-label">Classified (changed+vivid pixels)</div>
        </div>
        <div class="img-card">
          #{img_tag('gemini_colormap', 'colormap_annotated.png', 'Annotated — gaps & punch-throughs')}
          <div class="img-label">Annotated (gaps + punch-throughs)</div>
        </div>
        <div class="img-card">
          #{img_tag('gemini_colormap', 'combined_wall_door.png', 'Combined Wall+Door Mask')}
          <div class="img-label">Combined Wall+Door Mask</div>
        </div>
        <div class="img-card wide">
          #{img_tag('gemini_colormap', 'punch_annotated.png', 'Punch-Through Candidates')}
          <div class="img-label">Punch-Throughs — cyan=outer, yellow=inner, red ring=near object</div>
        </div>
      </div>
      <div class="img-row">
        #{%w[inner_wall inner_door outer_wall outer_door].map { |name|
          "<div class='img-card'>#{img_tag('gemini_colormap', "mask_#{name}.png", name.tr('_',' ').capitalize)}<div class='img-label'>#{name.tr('_',' ')}</div></div>"
        }.join}
      </div>
      <div class="llm-summary">
        <table>
          #{metric_row('Inner wall px', lc['inner_wall'])}
          #{metric_row('Inner door px', lc['inner_door'])}
          #{metric_row('Outer wall px', lc['outer_wall'])}
          #{metric_row('Outer door px', lc['outer_door'])}
          #{metric_row('Outer gaps',    outer_gaps.size)}
          #{metric_row('Inner gaps',    inner_gaps.size)}
          #{metric_row('Connectivity',  conn_info['is_connected'] ? 'OK' : "#{conn_info['num_components']} regions")}
          #{metric_row('Punch-throughs', punch_pts.size)}
          #{gap_rows}
          #{punch_rows}
        </table>
      </div>
    </div>
  HTML
else
  "<div class='section'><h2>Gemini Colormap Analysis</h2><p style='color:#888'>No colormap output yet.</p></div>"
end

# ── Assemble HTML ────────────────────────────────────────────────────────────

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Wall & Door Probe — Room #{ROOM_ID}</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background: #1a1a2e; color: #e0e0e0; font-family: 'Segoe UI', system-ui, sans-serif; padding: 24px; max-width: 1400px; margin: 0 auto; }
      h1 { color: #e94560; margin-bottom: 6px; font-size: 1.6rem; }
      h2 { color: #4ecca3; margin: 24px 0 12px; font-size: 1.15rem; border-bottom: 1px solid #2a2a4e; padding-bottom: 6px; }
      h3 { color: #a0c4ff; margin: 16px 0 8px; font-size: 1rem; }
      .meta { color: #888; font-size: 13px; margin-bottom: 24px; }
      .meta-note { color: #888; font-size: 12px; margin-bottom: 12px; }
      .section { margin-bottom: 32px; background: #16213e; border-radius: 10px; padding: 20px; }
      .verdict { border: 2px solid #4ecca3; }
      .img-row { display: flex; flex-wrap: wrap; gap: 16px; margin: 12px 0; }
      .img-card { flex: 1; min-width: 220px; max-width: 350px; }
      .img-card.wide { max-width: 700px; flex: 2; }
      .probe-img { width: 100%; border-radius: 6px; cursor: zoom-in; border: 1px solid #2a2a4e; }
      .img-label { font-size: 12px; color: #4ecca3; margin-top: 4px; text-align: center; }
      table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }
      th { background: #0f0f1a; color: #4ecca3; text-align: left; padding: 7px 10px; }
      td { padding: 6px 10px; border-bottom: 1px solid #1e1e3a; vertical-align: top; }
      td.label { color: #888; min-width: 140px; white-space: nowrap; }
      .mini-metrics { font-size: 11px; margin-top: 6px; }
      .mini-metrics td { padding: 2px 6px; }
      .mini-metrics td.label { min-width: 100px; }
      .badge { font-size: 10px; padding: 2px 6px; border-radius: 8px; font-weight: 600; display: inline-block; margin: 1px; }
      .badge-ok { background: #1a3a1a; color: #4ecca3; }
      .badge-warn { background: #3a2a1a; color: #ffa040; }
      .candidates-list { font-size: 11px; color: #a0c4ff; margin-top: 4px; font-style: italic; }
      .llm-summary { margin-top: 16px; }
      .lightbox { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.93); z-index: 1000; justify-content: center; align-items: center; flex-direction: column; gap: 12px; }
      .lightbox.active { display: flex; }
      .lightbox img { max-width: 95vw; max-height: 90vh; object-fit: contain; }
      .lb-cap { color: #e0e0e0; font-size: 15px; font-style: italic; }
    </style>
  </head>
  <body>
    <h1>Wall & Door Probe — Room #{ROOM_ID}</h1>
    <p class="meta">#{EXPERIMENTS.size} experiments &nbsp;|&nbsp; #{masks.size} object masks &nbsp;|&nbsp; #{results.values.count { |r| r['error'] }} errors</p>

    #{summary_section}
    #{input_section}
    #{gemini_colormap_section}
    #{shape_section}
    #{wall_section}
    #{contour_section}
    #{thin_section}
    #{gap_section}
    #{connectivity_section}
    #{verify_section}

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

File.write(File.join(OUT_DIR, 'index.html'), html)
puts "\nHTML written to #{OUT_DIR}/index.html"

# Symlink for serving
served = File.join(__dir__, '../../tmp/battlemap_inspect/wall_door_probe')
unless File.exist?(served) || File.symlink?(served)
  FileUtils.ln_sf(OUT_DIR, served)
  puts "Symlinked: #{served} → #{OUT_DIR}"
end

puts "\nDone! http://35.196.200.49:8181/wall_door_probe/index.html"
