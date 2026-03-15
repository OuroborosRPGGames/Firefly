# frozen_string_literal: true

# ReplicateSam2Service runs automatic instance segmentation using meta/sam-2 on Replicate.
#
# Uses SAM2's automatic mask generator — no text prompts, segments everything.
# Returns a directory of individual binary mask PNGs (0/255) at the source image resolution.
# Caller is responsible for cleaning up the mask directory.
#
# Usage:
#   result = ReplicateSam2Service.auto_segment('/path/to/image.webp', masks_dir: '/tmp/masks')
#   # => { success: true, masks_dir: '/tmp/masks', mask_count: 196 }
#
#   ReplicateSam2Service.available?
#   # => true if Replicate API key is configured
#
class ReplicateSam2Service
  extend ReplicateClientHelper

  SYNC_TIMEOUT   = 60
  POLL_INTERVAL  = 3
  MAX_POLL_ATTEMPTS = 100  # up to 5 minutes at 3s intervals

  MODEL = 'meta/sam-2'

  # Points per side for automatic mask generation.
  # 16 → ~50-100 masks, fast (~25s); 32 → ~150-250 masks, slower (~60s).
  DEFAULT_POINTS_PER_SIDE = 16

  class << self
    # Run automatic segmentation on an image. Downloads all individual mask PNGs.
    #
    # @param image_path [String] path to the source image
    # @param masks_dir [String] directory to save individual mask PNGs (created if needed)
    # @param points_per_side [Integer] density of query points (16=fast, 32=dense)
    # @return [Hash] { success:, masks_dir:, mask_count:, error: }
    def auto_segment(image_path, masks_dir:, points_per_side: DEFAULT_POINTS_PER_SIDE)
      return { success: false, error: 'Image file not found' } unless image_path && File.exist?(image_path)

      api_key = replicate_api_key
      return { success: false, error: 'Replicate API key not configured' } unless api_key && !api_key.empty?

      mime = detect_mime_type(image_path)
      data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(image_path))}"

      conn = build_connection(api_key, timeout: 90)
      version = resolve_model_version(conn, MODEL)
      return { success: false, error: 'Could not resolve meta/sam-2 model version' } unless version

      response = conn.post('predictions') do |req|
        req.headers['Prefer'] = "wait=#{SYNC_TIMEOUT}"
        req.body = {
          version: version,
          input: {
            image: data_uri,
            points_per_side: points_per_side,
            pred_iou_thresh: 0.80,
            stability_score_thresh: 0.92,
          }
        }
      end

      unless response.success?
        return { success: false, error: "Replicate API error: #{response.status} #{response.body[0..200]}" }
      end

      result = JSON.parse(response.body)

      on_success = lambda do |r|
        output = r['output']
        mask_urls = output.is_a?(Hash) ? Array(output['individual_masks']) : []
        download_masks(mask_urls, masks_dir)
      end

      case result['status']
      when 'succeeded'
        on_success.call(result)
      when 'starting', 'processing'
        poll_prediction(
          status_url: result['urls']&.dig('get'),
          api_key: api_key,
          max_attempts: MAX_POLL_ATTEMPTS,
          poll_interval: POLL_INTERVAL,
          timeout_error: 'Polling timed out waiting for SAM2 result',
          on_success: on_success,
          on_failed:   ->(r) { { success: false, error: "Prediction failed: #{r['error']}" } },
          on_canceled: ->(r) { { success: false, error: 'Prediction canceled' } }
        )
      when 'failed'
        { success: false, error: "Prediction failed: #{result['error']}" }
      else
        { success: false, error: "Unexpected status: #{result['status']}" }
      end
    rescue StandardError => e
      warn "[ReplicateSam2Service] auto_segment failed: #{e.message}"
      { success: false, error: e.message }
    end

    # Check if Replicate API key is configured
    # @return [Boolean]
    def available?
      replicate_api_key_configured?
    end

    private

    # Download all individual mask URLs in parallel, saving to masks_dir.
    # @param mask_urls [Array<String>] URLs to binary mask PNGs
    # @param masks_dir [String] destination directory
    # @return [Hash] { success:, masks_dir:, mask_count: }
    def download_masks(mask_urls, masks_dir)
      return { success: false, error: 'No individual_masks in output' } if mask_urls.empty?

      FileUtils.mkdir_p(masks_dir)

      errors = []
      mutex  = Mutex.new

      threads = mask_urls.each_with_index.map do |url, i|
        Thread.new do
          resp = Faraday.get(url)
          if resp.success?
            path = File.join(masks_dir, "mask_#{i.to_s.rjust(4, '0')}.png")
            File.binwrite(path, resp.body)
          else
            mutex.synchronize { errors << "mask #{i}: HTTP #{resp.status}" }
          end
        rescue StandardError => e
          mutex.synchronize { errors << "mask #{i}: #{e.message}" }
        end
      end
      threads.each(&:join)

      saved = Dir.glob(File.join(masks_dir, 'mask_*.png')).length
      warn "[ReplicateSam2Service] Downloaded #{saved}/#{mask_urls.length} masks#{errors.any? ? " (#{errors.length} errors)" : ''}"

      { success: true, masks_dir: masks_dir, mask_count: saved }
    rescue StandardError => e
      { success: false, error: "Download error: #{e.message}" }
    end
  end
end
