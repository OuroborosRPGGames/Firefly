# frozen_string_literal: true

# ReplicateDepthService estimates depth maps using Depth Anything v2 on Replicate.
#
# Usage:
#   result = ReplicateDepthService.estimate('/path/to/image.png')
#   # => { success: true, depth_path: '/path/to/image_depth.png' }
#
#   ReplicateDepthService.available?
#   # => true if Replicate API key is configured
#
class ReplicateDepthService
  extend ReplicateClientHelper

  SYNC_TIMEOUT = 60
  POLL_INTERVAL = 3
  MAX_POLL_ATTEMPTS = 40

  MODEL = 'chenxwh/depth-anything-v2'

  class << self
    # Estimate depth map for an image using Replicate.
    # @param image_path [String] path to the source image
    # @return [Hash] { success:, depth_path:, error: }
    def estimate(image_path)
      return { success: false, error: 'Image file not found' } unless image_path && File.exist?(image_path)

      api_key = replicate_api_key
      return { success: false, error: 'Replicate API key not configured' } unless api_key && !api_key.empty?

      mime = detect_mime_type(image_path)
      data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(image_path))}"

      conn = build_connection(api_key)
      version = resolve_model_version(conn, MODEL)
      return { success: false, error: 'Could not resolve model version' } unless version

      # Create prediction via unified endpoint
      response = conn.post('predictions') do |req|
        req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
        req.body = { version: version, input: { image: data_uri } }
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
      warn "[ReplicateDepthService] Depth estimation failed: #{e.message}"
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
        timeout_error: 'Polling timed out waiting for depth result',
        on_success: ->(result) { download_result(result['output'], original_path) },
        on_failed: ->(result) { { success: false, error: "Prediction #{result['status']}: #{result['error']}" } },
        on_canceled: ->(result) { { success: false, error: "Prediction #{result['status']}: #{result['error']}" } }
      )
    end

    def download_result(output, original_path)
      # Output can be: a Hash with grey_depth/color_depth, a URL string, or array of URLs
      url = if output.is_a?(Hash)
        output['grey_depth'] || output['color_depth'] || output.values.first
      elsif output.is_a?(Array)
        output.first
      else
        output
      end
      return { success: false, error: 'No output URL from Replicate' } unless url.is_a?(String) && !url.empty?

      require 'faraday'
      response = Faraday.get(url)
      unless response.success?
        return { success: false, error: "Failed to download depth map: #{response.status}" }
      end

      ext = File.extname(original_path)
      output_path = original_path.sub(/#{Regexp.escape(ext)}$/, '_depth.png')
      File.binwrite(output_path, response.body)

      { success: true, depth_path: output_path }
    rescue StandardError => e
      { success: false, error: "Download error: #{e.message}" }
    end

  end
end
