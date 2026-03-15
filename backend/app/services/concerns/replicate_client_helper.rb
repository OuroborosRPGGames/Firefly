# frozen_string_literal: true

# Shared Replicate client helpers for services that call Replicate models.
module ReplicateClientHelper
  REPLICATE_BASE_URL = 'https://api.replicate.com/v1'

  private

  def replicate_api_key
    AIProviderService.api_key_for('replicate')
  end

  def replicate_api_key_configured?
    key = replicate_api_key
    !key.nil? && !key.empty?
  end

  def build_connection(api_key, timeout: nil, open_timeout: 10)
    require 'faraday'

    Faraday.new(url: REPLICATE_BASE_URL) do |f|
      f.request :json
      f.headers['Authorization'] = "Bearer #{api_key}"
      f.headers['Content-Type'] = 'application/json'
      f.options.timeout = timeout || inferred_replicate_timeout
      f.options.open_timeout = open_timeout
    end
  end

  def resolve_model_version(conn, model_name)
    # Keep @version_cache for backward compatibility with existing tests and callers.
    @version_cache ||= {}
    return @version_cache[model_name] if @version_cache.key?(model_name)

    response = conn.get("models/#{model_name}")
    return nil unless response.success?

    data = JSON.parse(response.body)
    @version_cache[model_name] = data.dig('latest_version', 'id')
  rescue StandardError => e
    warn "[ReplicateClient] Failed to get latest version for #{model_name}: #{e.message}"
    nil
  end

  # Handle a Replicate prediction response with shared sync/async status flow.
  #
  # @param result [Hash]
  # @param api_key [String]
  # @param original_path [String]
  # @param failed_prefix [String]
  # @param poller [Proc] callable for async status polling
  # @param downloader [Proc] callable for succeeded output download
  # @return [Hash]
  def handle_prediction_result(result:, api_key:, original_path:, failed_prefix:, poller:, downloader:)
    case result['status']
    when 'succeeded'
      downloader.call(result['output'], original_path)
    when 'starting', 'processing'
      poller.call(result['urls']&.dig('get'), api_key, original_path)
    when 'failed'
      { success: false, error: "#{failed_prefix}: #{result['error']}" }
    else
      { success: false, error: "Unexpected status: #{result['status']}" }
    end
  end

  # Poll a Replicate prediction URL until completion.
  #
  # @param status_url [String]
  # @param api_key [String]
  # @param max_attempts [Integer]
  # @param poll_interval [Integer]
  # @param timeout_error [String]
  # @param on_success [Proc] receives result hash
  # @param on_failed [Proc, nil] receives result hash
  # @param on_canceled [Proc, nil] receives result hash
  # @return [Hash]
  def poll_prediction(
    status_url:,
    api_key:,
    max_attempts:,
    poll_interval:,
    timeout_error:,
    on_success:,
    on_failed: nil,
    on_canceled: nil
  )
    return { success: false, error: 'No status URL for polling' } unless status_url

    conn = build_connection(api_key)

    max_attempts.times do
      sleep(poll_interval)

      response = conn.get(status_url)
      result = JSON.parse(response.body)

      case result['status']
      when 'succeeded'
        return on_success.call(result)
      when 'failed'
        return on_failed.call(result) if on_failed
        return { success: false, error: "Prediction failed: #{result['error']}" }
      when 'canceled'
        return on_canceled.call(result) if on_canceled
        return { success: false, error: "Prediction canceled: #{result['error']}" }
      end
      # 'starting' or 'processing' — keep polling
    end

    { success: false, error: timeout_error }
  rescue StandardError => e
    { success: false, error: "Polling error: #{e.message}" }
  end

  def detect_mime_type(path)
    case File.extname(path.to_s.split('?').first).downcase
    when '.png' then 'image/png'
    when '.jpg', '.jpeg' then 'image/jpeg'
    when '.webp' then 'image/webp'
    else 'image/png'
    end
  end

  def inferred_replicate_timeout
    owner = is_a?(Class) ? self : self.class
    sync_timeout = owner.const_defined?(:SYNC_TIMEOUT, false) ? owner.const_get(:SYNC_TIMEOUT) : 60
    sync_timeout + 10
  end
end
