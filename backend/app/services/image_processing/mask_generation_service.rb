# frozen_string_literal: true

# MaskGenerationService generates a companion mask PNG for a room's background image
# using Mask2Former (ADE20K semantic segmentation) on Replicate.
#
# The mask uses color channels to encode regions:
#   Red   = sky (for lightning bolt constraint)
#   Green = windows, doors, archways (for indoor weather visibility)
#   Blue  = buildings, walls, wood structures (for fire effect density)
#
# Each channel is 0 or 255 — no gradients. Effects degrade gracefully without masks.
#
# How it works:
#   1. Send background image to Mask2Former on Replicate
#   2. Receive a color-coded segmentation map + label→color mapping
#   3. Map ADE20K labels to our three channels
#   4. Produce a compact RGB mask PNG
#
# Usage:
#   result = MaskGenerationService.generate(room)
#   # => { success: true, mask_url: '/uploads/masks/2026/02/abc123.png' }
#
#   MaskGenerationService.available?
#   # => true if Replicate API key is configured
#
class MaskGenerationService
  include ReplicateClientHelper
  extend ReplicateClientHelper

  SYNC_TIMEOUT = 60
  POLL_INTERVAL = 3
  MAX_POLL_ATTEMPTS = 40

  # Mask2Former ADE20K model on Replicate
  MODEL_VERSION = '86aa30aafd3ade4153ae74aae3e40642a3dff824ed622ff86cec9d67ceb178d2'

  # ADE20K label → mask channel mapping
  # Red channel: sky regions
  SKY_LABELS = %w[sky].freeze

  # Green channel: openings (windows, doors, archways)
  OPENING_LABELS = %w[window windowpane door gate arch].freeze

  # Blue channel: burnable structures
  STRUCTURE_LABELS = %w[
    house building wall fence railing column pillar
    cabinet shelf stairway table desk chair bench
    wood beam timber log
  ].freeze

  class << self
    # Generate a mask for a room's background image
    # @param room [Room] the room to generate a mask for
    # @return [Hash] { success: true, mask_url: '...' } or { success: false, error: '...' }
    def generate(room)
      new(room).generate
    end

    # Check if mask generation is available
    # @return [Boolean]
    def available?
      replicate_api_key_configured?
    end
  end

  def initialize(room)
    @room = room
  end

  def generate
    bg_url = @room.default_background_url
    return { success: false, error: 'No background image' } unless bg_url && !bg_url.to_s.strip.empty?

    api_key = replicate_api_key
    return { success: false, error: 'Replicate API key not configured' } unless api_key && !api_key.empty?

    # Load source image as base64 data URI
    image_data_uri = load_image_as_data_uri(bg_url)
    return { success: false, error: 'Could not load background image' } unless image_data_uri

    # Run Mask2Former segmentation
    conn = build_connection(api_key)
    seg_result = run_segmentation(conn, image_data_uri)
    return { success: false, error: seg_result[:error] || 'Segmentation failed' } unless seg_result[:success]

    # Build channel mapping from detected objects
    channel_map = build_channel_map(seg_result[:objects])

    if channel_map.empty?
      return { success: false, error: 'No relevant regions detected (sky, windows, or structures)' }
    end

    # Download segmentation map and composite our RGB mask
    mask_png = composite_mask(seg_result[:segment_url], channel_map)
    return { success: false, error: 'Failed to composite mask' } unless mask_png

    # Upload mask
    date_path = Time.now.strftime('%Y/%m')
    key = "masks/#{date_path}/#{SecureRandom.hex(12)}.png"
    mask_url = CloudStorageService.upload(mask_png, key, content_type: 'image/png')

    # Update room record
    @room.update(mask_url: mask_url)

    { success: true, mask_url: mask_url }
  rescue StandardError => e
    warn "[MaskGenerationService] Failed for room #{@room.id}: #{e.message}"
    { success: false, error: e.message }
  end

  private

  # Run Mask2Former segmentation via Replicate
  # @param conn [Faraday::Connection]
  # @param image_data_uri [String] base64 data URI
  # @return [Hash] { success:, segment_url:, objects:, error: }
  def run_segmentation(conn, image_data_uri)
    response = conn.post('predictions') do |req|
      req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
      req.body = {
        version: MODEL_VERSION,
        input: { image: image_data_uri }
      }
    end

    unless response.success? || response.status == 201 || response.status == 202
      return { success: false, error: "Replicate API error: #{response.status}" }
    end

    result = JSON.parse(response.body)

    case result['status']
    when 'succeeded'
      extract_output(result['output'])
    when 'starting', 'processing'
      poll_for_result(result['urls']&.dig('get'), conn)
    when 'failed'
      { success: false, error: "Segmentation failed: #{result['error']}" }
    else
      # No status means we got a 202 — need to poll
      if result['urls']&.dig('get')
        poll_for_result(result['urls']['get'], conn)
      else
        { success: false, error: "Unexpected response: #{result['status']}" }
      end
    end
  rescue StandardError => e
    { success: false, error: "Segmentation error: #{e.message}" }
  end

  # Poll for segmentation result
  # @param status_url [String]
  # @param conn [Faraday::Connection]
  # @return [Hash] { success:, segment_url:, objects:, error: }
  def poll_for_result(status_url, conn)
    return { success: false, error: 'No status URL for polling' } unless status_url

    MAX_POLL_ATTEMPTS.times do
      sleep(POLL_INTERVAL)

      response = conn.get(status_url)
      result = JSON.parse(response.body)

      case result['status']
      when 'succeeded'
        return extract_output(result['output'])
      when 'failed', 'canceled'
        return { success: false, error: "Segmentation #{result['status']}: #{result['error']}" }
      end
    end

    { success: false, error: 'Polling timed out waiting for segmentation' }
  rescue StandardError => e
    { success: false, error: "Polling error: #{e.message}" }
  end

  # Extract segment URL and objects from Mask2Former output
  # @param output [Hash] { "segment" => url, "objects" => [...] }
  # @return [Hash] { success:, segment_url:, objects: }
  def extract_output(output)
    return { success: false, error: 'No output from model' } unless output.is_a?(Hash)

    segment_url = output['segment']
    objects = output['objects']

    return { success: false, error: 'No segmentation map in output' } unless segment_url

    {
      success: true,
      segment_url: segment_url,
      objects: objects || []
    }
  end

  # Map detected ADE20K labels to our R/G/B channels
  # @param objects [Array<Hash>] [{ "label" => "sky", "color" => [80, 50, 50] }, ...]
  # @return [Hash] { [r,g,b] => :red/:green/:blue } mapping segmap colors to output channels
  def build_channel_map(objects)
    return {} unless objects.is_a?(Array)

    channel_map = {}

    objects.each do |obj|
      label = obj['label'].to_s.downcase
      color = obj['color']
      next unless color.is_a?(Array) && color.length == 3

      color_key = color.map(&:to_i)

      if SKY_LABELS.any? { |l| label.include?(l) }
        channel_map[color_key] = :red
      elsif OPENING_LABELS.any? { |l| label.include?(l) }
        channel_map[color_key] = :green
      elsif STRUCTURE_LABELS.any? { |l| label.include?(l) }
        channel_map[color_key] = :blue
      end
    end

    channel_map
  end

  # Download segmentation map and composite into our RGB mask
  # @param segment_url [String] URL of the color-coded segmentation map
  # @param channel_map [Hash] { [r,g,b] => :red/:green/:blue }
  # @return [String, nil] PNG binary data, or nil on failure
  def composite_mask(segment_url, channel_map)
    require 'chunky_png'
    require 'faraday'

    # Download segmentation map
    response = Faraday.new { |f| f.options.timeout = 30 }.get(segment_url)
    return nil unless response.success?

    seg_img = ChunkyPNG::Image.from_blob(response.body)
    width = seg_img.width
    height = seg_img.height

    # Build a fast lookup: packed RGB integer → channel symbol
    color_lookup = {}
    channel_map.each do |rgb_array, channel|
      # Pack RGB into a single comparable value
      packed = (rgb_array[0] << 16) | (rgb_array[1] << 8) | rgb_array[2]
      color_lookup[packed] = channel
    end

    output = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::TRANSPARENT)

    height.times do |y|
      width.times do |x|
        pixel = seg_img[x, y]
        r = ChunkyPNG::Color.r(pixel)
        g = ChunkyPNG::Color.g(pixel)
        b = ChunkyPNG::Color.b(pixel)
        packed = (r << 16) | (g << 8) | b

        channel = color_lookup[packed]
        next unless channel

        case channel
        when :red   then output[x, y] = ChunkyPNG::Color.rgba(255, 0, 0, 255)
        when :green then output[x, y] = ChunkyPNG::Color.rgba(0, 255, 0, 255)
        when :blue  then output[x, y] = ChunkyPNG::Color.rgba(0, 0, 255, 255)
        end
      end
    end

    output.to_blob(:fast_rgba)
  rescue StandardError => e
    warn "[MaskGenerationService] Composite failed: #{e.message}"
    nil
  end

  # Load an image from a URL (local or remote) and return as base64 data URI
  # @param url [String] image URL (/uploads/... or https://...)
  # @return [String, nil] data URI or nil on failure
  def load_image_as_data_uri(url)
    image_data = if url.start_with?('/')
                   local_path = File.join('public', url)
                   return nil unless File.exist?(local_path)

                   File.binread(local_path)
                 else
                   require 'faraday'
                   response = Faraday.new { |f| f.options.timeout = 30 }.get(url)
                   return nil unless response.success?

                   response.body
                 end

    mime = detect_mime_type(url)
    "data:#{mime};base64,#{Base64.strict_encode64(image_data)}"
  rescue StandardError => e
    warn "[MaskGenerationService] Failed to load image #{url}: #{e.message}"
    nil
  end

end
