# frozen_string_literal: true

# ReplicateSamService segments objects using Lang Segment Anything on Replicate.
#
# Uses the tmappdev/lang-segment-anything model for text-prompted segmentation.
# Returns a binary mask image (white = detected, black = background).
#
# The model accepts ONE text prompt per call and returns a single mask PNG.
# For multiple object types, make separate calls or use the category-based
# approach in AIBattleMapGeneratorService which groups types by category.
#
# Usage:
#   result = ReplicateSamService.segment('/path/to/image.png', 'furniture')
#   # => { success: true, mask_path: '/path/to/image_sam_furniture.png' }
#
#   ReplicateSamService.available?
#   # => true if Replicate API key is configured
#
class ReplicateSamService
  extend ReplicateClientHelper

  SYNC_TIMEOUT = 60
  POLL_INTERVAL = 3
  MAX_POLL_ATTEMPTS = 40
  # If a SAM mask covers >= this fraction of the image, the query was too broad
  # (e.g. "fire" segmenting the entire room). Treat as no detections.
  MAX_MASK_COVERAGE = 0.25

  MODEL = 'tmappdev/lang-segment-anything'

  class << self
    # Segment objects in an image using Lang Segment Anything.
    # @param image_path [String] path to the source image
    # @param text_query [String] text prompt describing what to segment (single concept works best)
    # @param suffix [String] suffix for mask output filename
    # @return [Hash] { success:, mask_path:, error: }
    def segment(image_path, text_query, suffix: '_sam_mask')
      return { success: false, error: 'Image file not found' } unless image_path && File.exist?(image_path)

      api_key = replicate_api_key
      return { success: false, error: 'Replicate API key not configured' } unless api_key && !api_key.empty?

      mime = detect_mime_type(image_path)
      data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(image_path))}"

      conn = build_connection(api_key)
      version = resolve_model_version(conn, MODEL)
      return { success: false, error: 'Could not resolve model version' } unless version

      response = conn.post('predictions') do |req|
        req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
        req.body = {
          version: version,
          input: {
            image: data_uri,
            text_prompt: text_query
          }
        }
      end

      unless response.success?
        return { success: false, error: "Replicate API error: #{response.status} #{response.body}" }
      end

      result = JSON.parse(response.body)

      case result['status']
      when 'succeeded'
        download_mask(result['output'], image_path, suffix)
      when 'starting', 'processing'
        poll_for_result(result['urls']&.dig('get'), api_key, image_path, suffix)
      when 'failed'
        error = result['error'].to_s
        # "list index out of range" means nothing was detected — not a real error
        if error.include?('list index out of range')
          { success: true, mask_path: nil, no_detections: true }
        else
          { success: false, error: "Replicate prediction failed: #{error}" }
        end
      else
        { success: false, error: "Unexpected status: #{result['status']}" }
      end
    rescue StandardError => e
      warn "[ReplicateSamService] Segmentation failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Segment with SAM2G primary, Lang-SAM fallback.
    # Drop-in replacement for `segment` that tries SAM2G first.
    # @param image_path [String]
    # @param text_query [String]
    # @param suffix [String]
    # @param max_coverage [Float]
    # @return [Hash] { success:, mask_path:, ... }
    def segment_with_samg_fallback(image_path, text_query, suffix: '_sam_mask', max_coverage: MAX_MASK_COVERAGE)
      output_dir = File.dirname(image_path)
      room_id = File.basename(image_path, '.*').scan(/\d+/).first || '0'
      svc = BattlemapV2::SamSegmentationService.new(image_path: image_path, output_dir: output_dir)
      result = svc.segment_object(text_query, room_id: room_id, max_coverage: max_coverage)

      # Rename mask to match expected suffix convention
      if result[:mask_path] && File.exist?(result[:mask_path])
        expected_path = image_path.sub(/\.\w+$/, "#{suffix}.png")
        FileUtils.cp(result[:mask_path], expected_path) unless result[:mask_path] == expected_path
        result[:mask_path] = expected_path
      end

      result
    rescue StandardError => e
      warn "[ReplicateSamService] SAM2G+Lang-SAM segmentation failed: #{e.message}"
      # Preserve legacy behavior: if SAM2G setup/errors fail, fall back to direct Lang-SAM.
      # Lang-SAM works better with single-word queries, so use the last word only.
      simple_query = text_query.split.last || text_query
      fallback = segment(image_path, simple_query, suffix: suffix)
      fallback.merge(fallback_used: true, primary_error: e.message)
    end

    # Check if Replicate API key is configured
    # @return [Boolean]
    def available?
      replicate_api_key_configured?
    end

    private

    def poll_for_result(status_url, api_key, original_path, suffix)
      poll_prediction(
        status_url: status_url,
        api_key: api_key,
        max_attempts: MAX_POLL_ATTEMPTS,
        poll_interval: POLL_INTERVAL,
        timeout_error: 'Polling timed out waiting for segmentation result',
        on_success: ->(result) { download_mask(result['output'], original_path, suffix) },
        on_failed: lambda { |result|
          error = result['error'].to_s
          if error.include?('list index out of range')
            { success: true, mask_path: nil, no_detections: true }
          else
            { success: false, error: "Prediction failed: #{error}" }
          end
        },
        on_canceled: ->(_result) { { success: false, error: 'Prediction canceled' } }
      )
    end

    # Compute the fraction of white pixels in a mask image (0.0 to 1.0).
    # Returns nil if the mask can't be read.
    def mask_coverage(mask_path)
      require 'vips'
      mask = Vips::Image.new_from_file(mask_path)
      mask = mask.extract_band(0) if mask.bands > 1
      mask.avg / 255.0
    rescue StandardError => e
      warn "[ReplicateSamService] Failed to compute mask coverage for #{mask_path}: #{e.message}"
      nil
    end

    # Download the mask PNG from Replicate output URL.
    # Output is a single URL string pointing to a grayscale mask image.
    def download_mask(output, original_path, suffix)
      url = output
      return { success: false, error: 'No output URL from Replicate' } unless url.is_a?(String) && !url.empty?

      require 'faraday'
      response = Faraday.get(url)
      unless response.success?
        return { success: false, error: "Failed to download mask: #{response.status}" }
      end

      ext = File.extname(original_path)
      mask_path = original_path.sub(/#{Regexp.escape(ext)}$/, "#{suffix}.png")
      File.binwrite(mask_path, response.body)

      # Reject masks that cover too much of the image (query was too broad)
      coverage = mask_coverage(mask_path)
      if coverage.nil?
        warn "[ReplicateSamService] Rejecting mask due to coverage check failure: #{mask_path}"
        FileUtils.rm_f(mask_path)
        return { success: true, mask_path: nil, no_detections: true, coverage_check_failed: true }
      end

      if coverage && coverage >= MAX_MASK_COVERAGE
        warn "[ReplicateSamService] Mask covers #{(coverage * 100).round(1)}% of image (>= #{(MAX_MASK_COVERAGE * 100).round}%) — ignoring as too broad"
        return { success: true, mask_path: nil, no_detections: true, rejected_coverage: coverage }
      end

      { success: true, mask_path: mask_path }
    rescue StandardError => e
      { success: false, error: "Download error: #{e.message}" }
    end

  end
end
