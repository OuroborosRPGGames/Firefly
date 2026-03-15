# frozen_string_literal: true

require 'faraday'
require 'fileutils'
require 'securerandom'

module LLM
  # ImageDownloader downloads generated images from provider URLs
  # and stores them via CloudStorageService (R2 or local).
  #
  # Provider URLs typically expire after a short time (e.g., 1 hour),
  # so we download immediately and store in cloud storage for permanent access.
  #
  class ImageDownloader
    MAX_FILE_SIZE = GameConfig::LLM::FILE_LIMITS[:max_image_size]
    TIMEOUT = GameConfig::LLM::TIMEOUTS[:image_download]

    class << self
      # Download an image from URL and store it
      # @param url [String] the image URL to download
      # @param request [LLMRequest] the request for context
      # @return [String, nil] public URL or nil on failure
      def download(url, request = nil)
        return nil if url.nil? || url.empty?

        begin
          response = fetch_image(url)
          return nil unless response

          storage_key = generate_storage_key(url, request)
          content_type = detect_content_type(url, response)

          save_image(response, storage_key, content_type)
        rescue StandardError => e
          log_error("Failed to download image: #{e.message}")
          nil
        end
      end

      private

      def generate_storage_key(url, request)
        date_dir = Time.now.strftime('%Y/%m')
        extension = extract_extension(url)
        filename = if request
                     "#{SecureRandom.hex(8)}-#{request.id}.#{extension}"
                   else
                     "#{SecureRandom.hex(12)}.#{extension}"
                   end

        "generated/#{date_dir}/#{filename}"
      end

      def extract_extension(url)
        # Try to get extension from URL
        uri_path = URI.parse(url).path rescue ''
        ext = File.extname(uri_path).delete('.')
        ext = 'png' if ext.empty? || ext.length > 5

        # Normalize common extensions
        case ext.downcase
        when 'jpeg'
          'jpg'
        when 'webp', 'gif', 'jpg', 'png'
          ext.downcase
        else
          'png'
        end
      end

      def detect_content_type(url, _response = nil)
        extension = extract_extension(url)
        case extension
        when 'jpg' then 'image/jpeg'
        when 'png' then 'image/png'
        when 'webp' then 'image/webp'
        when 'gif' then 'image/gif'
        else 'image/png'
        end
      end

      def fetch_image(url)
        conn = Faraday.new do |c|
          c.adapter Faraday.default_adapter
          c.options.timeout = TIMEOUT
          c.options.open_timeout = GameConfig::LLM::TIMEOUTS[:http_open]
        end

        response = conn.get(url)

        unless response.success?
          log_error("Image download failed: HTTP #{response.status}")
          return nil
        end

        if response.body.length > MAX_FILE_SIZE
          log_error("Image too large: #{response.body.length} bytes")
          return nil
        end

        response.body
      end

      def save_image(data, key, content_type)
        url = CloudStorageService.upload(data, key, content_type: content_type)
        log_info("Saved image to #{url}")
        url
      end

      def log_error(message)
        warn "[LLM::ImageDownloader] ERROR: #{message}"
      end

      def log_info(message)
        warn "[LLM::ImageDownloader] #{message}" if ENV['LOG_LLM_REQUESTS']
      end
    end
  end
end
