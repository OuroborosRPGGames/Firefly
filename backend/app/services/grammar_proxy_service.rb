# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

class GrammarProxyService
  LANGUAGETOOL_URL = 'http://127.0.0.1:8742/v2/check'
  LANGUAGES_URL = 'http://127.0.0.1:8742/v2/languages'
  REDIS_KEY_PREFIX = 'grammar_rate'
  RATE_LIMIT = 10
  RATE_WINDOW_SECONDS = 60
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  class << self
    def check(text, language)
      uri = URI(LANGUAGETOOL_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri.path)
      request.set_form_data('text' => text, 'language' => language)

      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        parsed = JSON.parse(response.body)
        { success: true, matches: parsed['matches'] || [] }
      else
        { success: false, status: response.code.to_i, error: "LanguageTool returned #{response.code}" }
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET => e
      warn "[GrammarProxyService] LanguageTool unavailable: #{e.message}"
      { success: false, status: 503, error: 'Grammar service unavailable' }
    rescue StandardError => e
      warn "[GrammarProxyService] Unexpected error: #{e.message}"
      { success: false, status: 500, error: 'Internal error' }
    end

    def rate_limited?(user_id)
      request_count(user_id) >= RATE_LIMIT
    end

    def record_request(user_id)
      key = redis_key(user_id)
      REDIS_POOL.with do |redis|
        count = redis.incr(key)
        redis.expire(key, RATE_WINDOW_SECONDS) if count == 1
        count
      end
    end

    def request_count(user_id)
      REDIS_POOL.with do |redis|
        redis.get(redis_key(user_id)).to_i
      end
    end

    def available_languages
      GrammarLanguage.ready.map { |l| { code: l.language_code, name: l.language_name } }
    end

    def healthy?
      uri = URI(LANGUAGES_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      response = http.get(uri.path)
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError
      false
    end

    private

    def redis_key(user_id)
      "#{REDIS_KEY_PREFIX}:#{user_id}"
    end
  end
end
