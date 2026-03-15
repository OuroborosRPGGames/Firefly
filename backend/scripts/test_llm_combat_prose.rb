# frozen_string_literal: true

# Test LLM improvement of combat paragraphs
# Generates various combat scenarios and tests multiple LLMs for prose improvement
# Measures latency and compares outputs

require 'net/http'
require 'uri'
require 'json'
require 'benchmark'

# Load Rails app to access GameSetting
begin
  require_relative '../config/application'
rescue StandardError
  # Continue without database access
end

# Helper to get API keys from environment or database
def get_api_key(env_names, db_key = nil)
  # Try environment variables first
  env_names.each do |name|
    val = ENV[name]
    return val if val && !val.empty?
  end

  # Try database if GameSetting is available
  if db_key && defined?(GameSetting)
    begin
      val = GameSetting.get(db_key)
      return val if val && !val.empty?
    rescue StandardError
      # Database not available
    end
  end

  nil
end

# Combat paragraph generator - creates different permutations
class CombatParagraphGenerator
  SCENARIOS = [
    {
      name: 'One-sided beating (all hits)',
      paragraph: 'Alpha Agent presses the attack on Beta Agent, throwing five punches and kicks with fists. Beta Agent defends desperately, but Alpha Agent lands four hits, inflicting a devastating strike.'
    },
    {
      name: 'All misses',
      paragraph: 'Gamma Agent throws three punches and kicks at Beta Agent but she manages to dodge every one.'
    },
    {
      name: 'Mixed hits and misses',
      paragraph: 'Alpha Agent presses the attack on Beta Agent, throwing three punches and kicks with fists. Beta Agent defends desperately, but Alpha Agent lands two hits, inflicting a jarring blow.'
    },
    {
      name: 'Two-way exchange',
      paragraph: 'Alpha Agent and Beta Agent go back and forth with punches and kicks, each throwing five. Alpha Agent inflicts bruising while Beta Agent lands a solid hit.'
    },
    {
      name: 'Three-way melee',
      paragraph: 'A chaotic melee ensues. Alpha Agent swings 3 times with fists, landing a brutal impact. Beta Agent attacks with fists but can\'t find an opening. Gamma Agent swings once with fists, landing a light bruise.'
    },
    {
      name: 'Movement and combat',
      paragraph: 'Alpha Agent closes in on Gamma Agent. Beta Agent retreats. Alpha Agent presses the attack on Gamma Agent, throwing five punches and kicks with fists. Gamma Agent defends desperately, but Alpha Agent lands three hits, inflicting severe bruises.'
    },
    {
      name: 'Weapon combat',
      paragraph: 'The sword-wielding man slashes at his opponent with deadly precision, his blade finding its mark twice. The defender barely manages to parry the third strike, steel ringing against steel.'
    },
    {
      name: 'Critical damage',
      paragraph: 'Gamma Agent batters Alpha Agent with five punches and kicks, inflicting broken bones. Alpha Agent staggers but remains standing, blood dripping from multiple wounds.'
    }
  ].freeze

  def self.all_scenarios
    SCENARIOS
  end
end

# LLM API clients
class LLMClient
  IMPROVEMENT_PROMPT = <<~PROMPT
    Rewrite this combat paragraph to be more vivid and engaging. Keep ALL events, participants, hits, misses, and damage exactly the same. Output ONLY the improved paragraph, nothing else.

    %<paragraph>s
  PROMPT

  def self.clients
    [
      GeminiClient.new('gemini-3-flash-preview', 'Gemini 3 Flash Preview'),
      GeminiClient.new('gemini-2.5-flash', 'Gemini 2.5 Flash'),
      GeminiClient.new('gemini-2.5-flash-lite', 'Gemini 2.5 Flash-Lite'),
      GeminiClient.new('gemini-2.0-flash', 'Gemini 2.0 Flash'),
      HaikuClient.new,
      OpenRouterClient.new('deepseek/deepseek-chat', 'DeepSeek (OpenRouter)')
    ]
  end
end

class GeminiClient
  def initialize(model, display_name)
    @model = model
    @display_name = display_name
    @api_key = get_api_key(%w[GEMINI_API_KEY GOOGLE_AI_API_KEY], 'google_gemini_api_key')
  end

  attr_reader :display_name

  def available?
    !@api_key.nil? && !@api_key.empty?
  end

  def improve(paragraph)
    return { error: 'No API key' } unless available?

    uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{@model}:generateContent?key=#{@api_key}")

    body = {
      contents: [{
        parts: [{ text: format(LLMClient::IMPROVEMENT_PROMPT, paragraph: paragraph) }]
      }],
      generationConfig: {
        temperature: 0.7,
        maxOutputTokens: 500
      }
    }

    response = make_request(uri, body)
    parse_gemini_response(response)
  rescue StandardError => e
    { error: e.message }
  end

  private

  def make_request(uri, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    http.request(request)
  end

  def parse_gemini_response(response)
    return { error: "HTTP #{response.code}" } unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    text = data.dig('candidates', 0, 'content', 'parts', 0, 'text')
    { text: text&.strip }
  rescue JSON::ParserError => e
    { error: "JSON parse error: #{e.message}" }
  end
end

class HaikuClient
  def initialize
    @api_key = get_api_key(%w[ANTHROPIC_API_KEY], 'anthropic_api_key')
  end

  def display_name
    'Claude 3.5 Haiku'
  end

  def available?
    !@api_key.nil? && !@api_key.empty?
  end

  def improve(paragraph)
    return { error: 'No API key' } unless available?

    uri = URI('https://api.anthropic.com/v1/messages')

    body = {
      model: 'claude-3-5-haiku-latest',
      max_tokens: 500,
      messages: [{
        role: 'user',
        content: format(LLMClient::IMPROVEMENT_PROMPT, paragraph: paragraph)
      }]
    }

    response = make_request(uri, body)
    parse_anthropic_response(response)
  rescue StandardError => e
    { error: e.message }
  end

  private

  def make_request(uri, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['x-api-key'] = @api_key
    request['anthropic-version'] = '2023-06-01'
    request.body = body.to_json

    http.request(request)
  end

  def parse_anthropic_response(response)
    return { error: "HTTP #{response.code}: #{response.body}" } unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    text = data.dig('content', 0, 'text')
    { text: text&.strip }
  rescue JSON::ParserError => e
    { error: "JSON parse error: #{e.message}" }
  end
end

class DeepSeekClient
  def initialize
    @api_key = get_api_key(%w[DEEPSEEK_API_KEY], 'deepseek_api_key')
  end

  def display_name
    'DeepSeek Chat'
  end

  def available?
    !@api_key.nil? && !@api_key.empty?
  end

  def improve(paragraph)
    return { error: 'No API key' } unless available?

    uri = URI('https://api.deepseek.com/chat/completions')

    body = {
      model: 'deepseek-chat',
      messages: [{
        role: 'user',
        content: format(LLMClient::IMPROVEMENT_PROMPT, paragraph: paragraph)
      }],
      temperature: 0.7,
      max_tokens: 500
    }

    response = make_request(uri, body)
    parse_openai_response(response)
  rescue StandardError => e
    { error: e.message }
  end

  private

  def make_request(uri, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{@api_key}"
    request.body = body.to_json

    http.request(request)
  end

  def parse_openai_response(response)
    return { error: "HTTP #{response.code}: #{response.body}" } unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    text = data.dig('choices', 0, 'message', 'content')
    { text: text&.strip }
  rescue JSON::ParserError => e
    { error: "JSON parse error: #{e.message}" }
  end
end

class KimiClient
  def initialize
    @api_key = get_api_key(%w[KIMI_API_KEY MOONSHOT_API_KEY], 'moonshot_api_key')
  end

  def display_name
    'Kimi (Moonshot)'
  end

  def available?
    !@api_key.nil? && !@api_key.empty?
  end

  def improve(paragraph)
    return { error: 'No API key' } unless available?

    uri = URI('https://api.moonshot.cn/v1/chat/completions')

    body = {
      model: 'moonshot-v1-8k',
      messages: [{
        role: 'user',
        content: format(LLMClient::IMPROVEMENT_PROMPT, paragraph: paragraph)
      }],
      temperature: 0.7,
      max_tokens: 500
    }

    response = make_request(uri, body)
    parse_openai_response(response)
  rescue StandardError => e
    { error: e.message }
  end

  private

  def make_request(uri, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{@api_key}"
    request.body = body.to_json

    http.request(request)
  end

  def parse_openai_response(response)
    return { error: "HTTP #{response.code}: #{response.body}" } unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    text = data.dig('choices', 0, 'message', 'content')
    { text: text&.strip }
  rescue JSON::ParserError => e
    { error: "JSON parse error: #{e.message}" }
  end
end

class OpenRouterClient
  def initialize(model, display_name)
    @model = model
    @display_name = display_name
    @api_key = get_api_key(%w[OPENROUTER_API_KEY], 'openrouter_api_key')
  end

  attr_reader :display_name

  def available?
    !@api_key.nil? && !@api_key.empty?
  end

  def improve(paragraph)
    return { error: 'No API key' } unless available?

    uri = URI('https://openrouter.ai/api/v1/chat/completions')

    body = {
      model: @model,
      messages: [{
        role: 'user',
        content: format(LLMClient::IMPROVEMENT_PROMPT, paragraph: paragraph)
      }],
      temperature: 0.7,
      max_tokens: 500
    }

    response = make_request(uri, body)
    parse_openai_response(response)
  rescue StandardError => e
    { error: e.message }
  end

  private

  def make_request(uri, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{@api_key}"
    request['HTTP-Referer'] = 'https://firefly-mud.local'
    request['X-Title'] = 'Firefly MUD Combat Prose Test'
    request.body = body.to_json

    http.request(request)
  end

  def parse_openai_response(response)
    return { error: "HTTP #{response.code}: #{response.body}" } unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    text = data.dig('choices', 0, 'message', 'content')
    { text: text&.strip }
  rescue JSON::ParserError => e
    { error: "JSON parse error: #{e.message}" }
  end
end

# Main test runner
class LLMProseTestRunner
  def initialize
    @clients = LLMClient.clients
    @scenarios = CombatParagraphGenerator.all_scenarios
    @results = []
  end

  def run
    puts "=" * 80
    puts "LLM COMBAT PROSE IMPROVEMENT TEST"
    puts "=" * 80
    puts

    # Check available clients
    available = @clients.select(&:available?)
    unavailable = @clients.reject(&:available?)

    puts "Available LLMs: #{available.map(&:display_name).join(', ')}"
    puts "Unavailable (no API key): #{unavailable.map(&:display_name).join(', ')}" if unavailable.any?
    puts

    if available.empty?
      puts "ERROR: No LLM API keys configured!"
      puts "Set environment variables:"
      puts "  GEMINI_API_KEY or GOOGLE_AI_API_KEY"
      puts "  ANTHROPIC_API_KEY"
      puts "  DEEPSEEK_API_KEY"
      puts "  KIMI_API_KEY or MOONSHOT_API_KEY"
      return
    end

    # Test each scenario with each available client
    @scenarios.each_with_index do |scenario, idx|
      puts "-" * 80
      puts "SCENARIO #{idx + 1}: #{scenario[:name]}"
      puts "-" * 80
      puts
      puts "ORIGINAL:"
      puts scenario[:paragraph]
      puts

      available.each do |client|
        test_client(client, scenario)
      end
    end

    # Print summary
    print_summary(available)
  end

  private

  def test_client(client, scenario)
    print "Testing #{client.display_name}... "

    result = nil
    latency = Benchmark.realtime do
      result = client.improve(scenario[:paragraph])
    end
    latency_ms = (latency * 1000).round

    if result[:error]
      puts "ERROR (#{latency_ms}ms)"
      puts "  #{result[:error]}"
    else
      puts "OK (#{latency_ms}ms)"
      puts
      puts "#{client.display_name}:"
      puts result[:text]
      puts
    end

    @results << {
      client: client.display_name,
      scenario: scenario[:name],
      latency_ms: latency_ms,
      success: result[:error].nil?,
      error: result[:error],
      output: result[:text]
    }
  end

  def print_summary(clients)
    puts "=" * 80
    puts "SUMMARY"
    puts "=" * 80
    puts

    # Latency summary by client
    puts "Average Latency by LLM:"
    puts "-" * 40

    clients.each do |client|
      client_results = @results.select { |r| r[:client] == client.display_name && r[:success] }
      if client_results.any?
        avg_latency = client_results.sum { |r| r[:latency_ms] } / client_results.length
        puts "  #{client.display_name.ljust(20)} #{avg_latency}ms avg (#{client_results.length} successful)"
      else
        puts "  #{client.display_name.ljust(20)} No successful results"
      end
    end

    puts
    puts "Success Rate by LLM:"
    puts "-" * 40

    clients.each do |client|
      client_results = @results.select { |r| r[:client] == client.display_name }
      successful = client_results.count { |r| r[:success] }
      total = client_results.length
      pct = total > 0 ? (successful.to_f / total * 100).round : 0
      puts "  #{client.display_name.ljust(20)} #{successful}/#{total} (#{pct}%)"
    end
  end
end

# Run the tests
if __FILE__ == $PROGRAM_NAME
  LLMProseTestRunner.new.run
end
