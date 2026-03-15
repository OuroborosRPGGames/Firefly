# frozen_string_literal: true

require 'faraday'
require 'json'

# Service for sending messages to Discord webhooks
# Uses Discord's embed format for rich formatting
module DiscordWebhookService
  extend StringHelper

  COLORS = {
    memo: 0x3498db,      # Blue
    pm: 0x2ecc71,        # Green
    mention: 0xe67e22,   # Orange
    test: 0x9b59b6       # Purple
  }.freeze

  # Send a message to a Discord webhook
  # @param webhook_url [String] Discord webhook URL
  # @param title [String] Embed title
  # @param body [String] Embed description
  # @param event_type [Symbol] :memo, :pm, :mention, :test
  # @return [Boolean] true if successful, false otherwise
  def self.send(webhook_url, title:, body:, event_type: :memo)
    return false unless webhook_url && !webhook_url.to_s.strip.empty?

    embed = {
      title: title,
      description: truncate(strip_html(body), 2000),
      color: COLORS[event_type] || 0x95a5a6,
      footer: { text: GameSetting.get('game_name') || 'Firefly' },
      timestamp: Time.now.utc.iso8601
    }

    payload = { embeds: [embed] }

    response = Faraday.post(webhook_url) do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = payload.to_json
      req.options.timeout = GameConfig::LLM::TIMEOUTS[:discord_webhook]
      req.options.open_timeout = GameConfig::LLM::TIMEOUTS[:discord_open]
    end

    response.success?
  rescue Faraday::Error => e
    Firefly.logger.warn("Discord webhook failed: #{e.message}") if defined?(Firefly)
    false
  rescue StandardError => e
    Firefly.logger.error("Discord webhook error: #{e.message}") if defined?(Firefly)
    false
  end

  # Validate that a webhook URL looks correct
  # @param url [String] URL to validate
  # @return [Boolean]
  def self.valid_webhook_url?(url)
    return false unless url.is_a?(String)
    url.match?(%r{\Ahttps://discord\.com/api/webhooks/\d+/[\w-]+\z}) ||
      url.match?(%r{\Ahttps://discordapp\.com/api/webhooks/\d+/[\w-]+\z})
  end

  # Strip HTML tags from text
  # @param text [String] Text with potential HTML
  # @return [String] Clean text
  def self.strip_html(text)
    return '' unless text
    text.to_s.gsub(/<[^>]+>/, '').strip
  end
end
