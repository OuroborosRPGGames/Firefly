# frozen_string_literal: true

# ReplicateEdgeDetectionService detects edges in images using Replicate API.
#
# Uses the fofr/controlnet-preprocessors model with Canny or HED modes.
# Produces edge maps suitable for wall detection in battle map normalization.
#
# Usage:
#   result = ReplicateEdgeDetectionService.detect('/path/to/image.png')
#   # => { success: true, edge_map_path: '/path/to/image_edges.png' }
#
#   result = ReplicateEdgeDetectionService.detect('/path/to/image.png', mode: :hed)
#   # => { success: true, edge_map_path: '/path/to/image_edges.png' }
#
#   ReplicateEdgeDetectionService.available?
#   # => true if Replicate API key is configured
#
class ReplicateEdgeDetectionService
  extend ReplicateClientHelper

  SYNC_TIMEOUT = 60
  POLL_INTERVAL = 3
  MAX_POLL_ATTEMPTS = 40

  MODEL = 'fofr/controlnet-preprocessors'

  MODES = {
    canny: { preprocessor: 'canny', low_threshold: 100, high_threshold: 200 },
    hed: { preprocessor: 'softedge_hed' }
  }.freeze

  class << self
    # Detect edges in an image using Replicate.
    # @param image_path [String] path to the source image
    # @param mode [Symbol] :canny or :hed (default :canny)
    # @return [Hash] { success:, edge_map_path:, error: }
    def detect(image_path, mode: :canny)
      return { success: false, error: 'Image file not found' } unless image_path && File.exist?(image_path)

      api_key = replicate_api_key
      return { success: false, error: 'Replicate API key not configured' } unless api_key && !api_key.empty?

      mode_config = MODES[mode] || MODES[:canny]
      mime = detect_mime_type(image_path)
      data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(image_path))}"

      conn = build_connection(api_key)
      input = { image: data_uri }.merge(mode_config)

      version = resolve_model_version(conn, MODEL)
      return { success: false, error: 'Could not resolve model version' } unless version

      # Create prediction via unified endpoint
      response = conn.post('predictions') do |req|
        req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
        req.body = { version: version, input: input }
      end

      unless response.success?
        return { success: false, error: "Replicate API error: #{response.status} #{response.body}" }
      end

      result = JSON.parse(response.body)

      handle_prediction_result(
        result: result,
        api_key: api_key,
        original_path: image_path,
        failed_prefix: 'Replicate prediction failed',
        poller: method(:poll_for_result),
        downloader: method(:download_result)
      )
    rescue StandardError => e
      warn "[ReplicateEdgeDetectionService] Edge detection failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Check if Replicate API key is configured
    # @return [Boolean]
    def available?
      replicate_api_key_configured?
    end

    private

    def poll_for_result(status_url, api_key, original_path)
      poll_prediction(
        status_url: status_url,
        api_key: api_key,
        max_attempts: MAX_POLL_ATTEMPTS,
        poll_interval: POLL_INTERVAL,
        timeout_error: 'Polling timed out waiting for edge detection result',
        on_success: ->(result) { download_result(result['output'], original_path) },
        on_failed: ->(result) { { success: false, error: "Prediction #{result['status']}: #{result['error']}" } },
        on_canceled: ->(result) { { success: false, error: "Prediction #{result['status']}: #{result['error']}" } }
      )
    end

    def download_result(output, original_path)
      # Output can be a URL string or array of URLs
      url = output.is_a?(Array) ? output.first : output
      return { success: false, error: 'No output URL from Replicate' } unless url

      require 'faraday'
      response = Faraday.get(url)
      unless response.success?
        return { success: false, error: "Failed to download edge map: #{response.status}" }
      end

      ext = File.extname(original_path)
      output_path = original_path.sub(/#{Regexp.escape(ext)}$/, "_edges#{ext}")
      File.binwrite(output_path, response.body)

      { success: true, edge_map_path: output_path }
    rescue StandardError => e
      { success: false, error: "Download error: #{e.message}" }
    end

  end
end
