# frozen_string_literal: true

# ReplicateUpscalerService upscales images using the Replicate API.
#
# Supports multiple upscaler models. Crystal (philz1337x) is the
# default — sharpest results for battle map images.
#
# Usage:
#   result = ReplicateUpscalerService.upscale('/path/to/image.png', scale: 4)
#   # => { success: true, output_path: '/path/to/image_upscaled.png' }
#
#   ReplicateUpscalerService.available?
#   # => true if Replicate API key is configured
#
class ReplicateUpscalerService
  extend ReplicateClientHelper

  SYNC_TIMEOUT = 60
  POLL_INTERVAL = 3
  MAX_POLL_ATTEMPTS = 60

  MODELS = {
    crystal: 'philz1337x/crystal-upscaler',
    recraft: 'recraft-ai/recraft-crisp-upscale',
    bria: 'bria/increase-resolution',
    google: 'google/upscaler',
    esrgan: 'nightmareai/real-esrgan'
  }.freeze

  class << self
    # Upscale an image using Replicate.
    # @param image_path [String] path to the source image
    # @param scale [Integer] upscale factor (2-4, default 4)
    # @param model_key [Symbol] :esrgan, :crystal, :recraft, :bria, :google (default :esrgan)
    # @return [Hash] { success:, output_path:, error: }
    def upscale(image_path, scale: 4, model_key: :esrgan)
      return { success: false, error: 'Image file not found' } unless image_path && File.exist?(image_path)

      api_key = replicate_api_key
      return { success: false, error: 'Replicate API key not configured' } unless api_key && !api_key.empty?

      model = MODELS[model_key] || MODELS[:esrgan]
      mime = detect_mime_type(image_path)
      data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(image_path))}"

      conn = build_connection(api_key)
      input = build_model_input(model_key, data_uri, scale)

      version = resolve_model_version(conn, model)
      return { success: false, error: "Could not resolve model version for #{model}" } unless version

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
      warn "[ReplicateUpscalerService] Upscale failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Check if Replicate API key is configured
    # @return [Boolean]
    def available?
      replicate_api_key_configured?
    end

    private

    # Each model has different input parameter names
    def build_model_input(model_key, data_uri, scale)
      case model_key
      when :crystal
        { image: data_uri, scale_factor: scale.to_i.clamp(2, 4), output_format: 'png' }
      when :recraft
        { image: data_uri }
      when :bria
        { image: data_uri, desired_increase: scale.to_i.clamp(2, 4) }
      when :google
        { image: data_uri, upscale_factor: "x#{scale.to_i.clamp(2, 4)}" }
      when :esrgan
        { image: data_uri, scale: scale.to_i.clamp(2, 10), face_enhance: false }
      else
        { image: data_uri, scale_factor: scale.to_i.clamp(2, 4) }
      end
    end

    def poll_for_result(status_url, api_key, original_path)
      poll_prediction(
        status_url: status_url,
        api_key: api_key,
        max_attempts: MAX_POLL_ATTEMPTS,
        poll_interval: POLL_INTERVAL,
        timeout_error: 'Polling timed out waiting for upscale result',
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
        return { success: false, error: "Failed to download result: #{response.status}" }
      end

      ext = File.extname(original_path)
      output_path = original_path.sub(/#{Regexp.escape(ext)}$/, "_upscaled#{ext}")
      File.binwrite(output_path, response.body)

      { success: true, output_path: output_path }
    rescue StandardError => e
      { success: false, error: "Download error: #{e.message}" }
    end

  end
end
