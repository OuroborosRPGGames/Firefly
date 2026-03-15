# frozen_string_literal: true

require 'net/http'
require 'json'

# YouTubeMetadataService fetches video metadata from YouTube.
#
# Uses oEmbed (no API key required) as primary method.
# Falls back to YouTube Data API v3 if oEmbed fails and API key is configured.
#
# Usage:
#   result = YouTubeMetadataService.fetch_video_info('dQw4w9WgXcQ')
#   # => { video_id: '...', title: '...', duration_seconds: 212, ... }
#
module YouTubeMetadataService
  API_BASE_URL = 'https://www.googleapis.com/youtube/v3/videos'
  OEMBED_URL = 'https://www.youtube.com/oembed'
  DEFAULT_TIMEOUT = 10
  DEFAULT_DURATION = 300 # 5 minutes default if duration unknown

  class << self
    # Check if a URL is a YouTube URL
    #
    # @param url [String] URL to check
    # @return [Boolean]
    def youtube_url?(url)
      return false if url.nil? || url.to_s.empty?

      url.to_s.match?(/youtube\.com|youtu\.be/i)
    end

    # Fetch video metadata via oEmbed (no API key needed)
    #
    # @param video_id [String] YouTube video ID
    # @return [Hash, nil] Video info or nil if not found/error
    def fetch_via_oembed(video_id)
      return nil if video_id.nil? || video_id.empty?

      uri = URI(OEMBED_URL)
      uri.query = URI.encode_www_form(
        'url' => "https://www.youtube.com/watch?v=#{video_id}",
        'format' => 'json'
      )

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = DEFAULT_TIMEOUT
      http.read_timeout = DEFAULT_TIMEOUT

      response = http.request(Net::HTTP::Get.new(uri))
      return nil unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)

      {
        video_id: video_id,
        title: data['title'],
        channel_title: data['author_name'],
        thumbnail_url: "https://img.youtube.com/vi/#{video_id}/hqdefault.jpg",
        duration_seconds: nil, # oEmbed doesn't provide duration
        is_embeddable: true    # if oEmbed works, it's embeddable
      }
    rescue StandardError => e
      warn "[YouTubeMetadataService] oEmbed error: #{e.message}"
      nil
    end

    # Fetch video metadata from YouTube Data API v3
    #
    # @param video_id [String] YouTube video ID
    # @return [Hash, nil] Video info or nil if not found/error
    def fetch_video_info(video_id)
      return nil if video_id.nil? || video_id.empty?

      key = api_key
      return nil unless key

      uri = build_uri(video_id, key)
      response = make_request(uri)
      parse_response(response, video_id)
    rescue StandardError => e
      warn "[YouTubeMetadataService] Error fetching video info: #{e.message}"
      nil
    end

    # Extract video ID from a YouTube URL
    #
    # @param url [String] YouTube URL
    # @return [String, nil] Video ID or nil
    def extract_video_id(url)
      return nil if url.nil? || url.empty?

      if url.include?('youtu.be/')
        url.split('youtu.be/').last.split(/[?&#]/).first
      elsif url.include?('v=')
        url.split('v=').last.split(/[?&#]/).first
      elsif url.include?('/embed/')
        url.split('/embed/').last.split(/[?&#]/).first
      end
    end

    # Fetch video info from a YouTube URL
    # Tries oEmbed first (no API key), falls back to Data API if available
    #
    # @param url [String] YouTube URL
    # @return [Hash, nil] Video info or nil
    def fetch_from_url(url)
      video_id = extract_video_id(url)
      return nil unless video_id

      # Try oEmbed first (no API key needed)
      info = fetch_via_oembed(video_id)
      return info if info

      # Fall back to Data API if key is configured
      fetch_video_info(video_id)
    end

    # Check if API is configured
    #
    # @return [Boolean]
    def configured?
      !api_key.nil?
    end

    private

    def api_key
      # Try environment variable first
      key = ENV['YOUTUBE_API_KEY']
      return key if key && !key.empty?

      # Fall back to game setting
      if defined?(GameSetting)
        begin
          key = GameSetting.get('youtube_api_key')
          return key if key && !key.empty?
        rescue StandardError => e
          warn "[YoutubeMetadataService] Failed to get youtube_api_key from GameSetting: #{e.message}"
        end
      end

      nil
    end

    def build_uri(video_id, api_key)
      params = {
        'part' => 'snippet,contentDetails,status',
        'id' => video_id,
        'key' => api_key
      }
      uri = URI(API_BASE_URL)
      uri.query = URI.encode_www_form(params)
      uri
    end

    def make_request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = DEFAULT_TIMEOUT
      http.read_timeout = DEFAULT_TIMEOUT

      request = Net::HTTP::Get.new(uri)
      request['Accept'] = 'application/json'

      http.request(request)
    end

    def parse_response(response, video_id)
      unless response.is_a?(Net::HTTPSuccess)
        warn "[YouTubeMetadataService] API returned #{response.code}: #{response.body[0..200]}"
        return nil
      end

      data = JSON.parse(response.body)
      items = data['items']

      return nil if items.nil? || items.empty?

      item = items.first
      snippet = item['snippet'] || {}
      content_details = item['contentDetails'] || {}
      status = item['status'] || {}

      {
        video_id: video_id,
        title: snippet['title'],
        description: snippet['description'],
        channel_title: snippet['channelTitle'],
        published_at: snippet['publishedAt'],
        thumbnail_url: snippet.dig('thumbnails', 'high', 'url') || snippet.dig('thumbnails', 'default', 'url'),
        duration_seconds: parse_duration(content_details['duration']),
        duration_iso: content_details['duration'],
        is_embeddable: status['embeddable'],
        privacy_status: status['privacyStatus']
      }
    end

    # Parse ISO 8601 duration (PT4M12S) to seconds
    #
    # @param iso_duration [String] ISO 8601 duration like "PT4M12S" or "PT1H2M30S"
    # @return [Integer, nil] Duration in seconds
    def parse_duration(iso_duration)
      return nil if iso_duration.nil? || iso_duration.empty?

      # Match PT[nH][nM][nS] format
      match = iso_duration.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/)
      return nil unless match

      hours = match[1]&.to_i || 0
      minutes = match[2]&.to_i || 0
      seconds = match[3]&.to_i || 0

      (hours * 3600) + (minutes * 60) + seconds
    end
  end
end
