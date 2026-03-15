# frozen_string_literal: true

# Iterative prompt testing for combat prose improvement
# Tests different prompts with Gemini 2.5 Flash-Lite to find the optimal balance

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

def get_api_key(env_names, db_key = nil)
  env_names.each do |name|
    val = ENV[name]
    return val if val && !val.empty?
  end

  if db_key && defined?(GameSetting)
    begin
      val = GameSetting.get(db_key)
      return val if val && !val.empty?
    rescue StandardError
    end
  end

  nil
end

# Test paragraphs - different combat scenarios
PARAGRAPHS = [
  {
    name: 'One-sided beating',
    text: 'Alpha presses the attack on Beta, throwing five punches and kicks. Beta defends desperately, but Alpha lands four hits, inflicting severe bruises.'
  },
  {
    name: 'All misses',
    text: 'Gamma throws three punches at Beta but she dodges every one.'
  },
  {
    name: 'Two-way exchange',
    text: 'Alpha and Beta trade blows, each throwing five strikes. Alpha inflicts bruising while Beta lands a solid hit.'
  },
  {
    name: 'Three-way melee',
    text: 'A chaotic melee ensues. Alpha swings 3 times with fists, landing a brutal impact. Beta attacks but finds no opening. Gamma swings once, landing a light bruise.'
  }
].freeze

# Prompts to test - from verbose to minimal
PROMPTS = {
  'v1_original' => <<~PROMPT,
    Rewrite this combat paragraph to be more vivid and engaging. Keep ALL events, participants, hits, misses, and damage exactly the same. Output ONLY the improved paragraph, nothing else.

    %<paragraph>s
  PROMPT

  'v2_concise' => <<~PROMPT,
    Rewrite this combat paragraph. Make it vivid but concise - no purple prose. Keep all hits, misses, and damage exactly as stated. Output only the rewritten paragraph.

    %<paragraph>s
  PROMPT

  'v3_punchy' => <<~PROMPT,
    Rewrite this combat text. Be punchy and visceral, not verbose. Preserve all mechanical details (who hit whom, damage dealt). One paragraph only.

    %<paragraph>s
  PROMPT

  'v4_word_limit' => <<~PROMPT,
    Improve this combat paragraph in under 50 words. Keep it vivid but tight. Preserve all hits, misses, and damage exactly.

    %<paragraph>s
  PROMPT

  'v5_pulp_style' => <<~PROMPT,
    Rewrite in pulp fiction style - short, punchy sentences. Keep all combat details exact. No flowery language. Output only the paragraph.

    %<paragraph>s
  PROMPT

  'v6_show_dont_tell' => <<~PROMPT,
    Rewrite this combat. Show the action through specific details, not adjectives. Keep all hits/misses/damage exact. Be concise.

    %<paragraph>s
  PROMPT

  'v7_hemingway' => <<~PROMPT,
    Rewrite this combat in Hemingway's spare style. Short sentences. No adverbs. Keep all mechanical details exact.

    %<paragraph>s
  PROMPT

  'v8_balanced' => <<~PROMPT,
    Improve this combat paragraph. Goals:
    - Vivid but not verbose (aim for similar length to original)
    - Preserve ALL mechanical details: who attacked, hits landed, damage inflicted
    - Punchy prose, avoid cliches like "whirlwind" or "blur of motion"
    Output only the improved paragraph.

    %<paragraph>s
  PROMPT
}.freeze

class GeminiTester
  def initialize
    @api_key = get_api_key(%w[GEMINI_API_KEY GOOGLE_AI_API_KEY], 'google_gemini_api_key')
    @model = 'gemini-2.5-flash-lite'
  end

  def available?
    !@api_key.nil? && !@api_key.empty?
  end

  def test(prompt, paragraph)
    return { error: 'No API key' } unless available?

    full_prompt = format(prompt, paragraph: paragraph)
    uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{@model}:generateContent?key=#{@api_key}")

    body = {
      contents: [{ parts: [{ text: full_prompt }] }],
      generationConfig: {
        temperature: 0.7,
        maxOutputTokens: 300
      }
    }

    response = make_request(uri, body)
    parse_response(response)
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

  def parse_response(response)
    return { error: "HTTP #{response.code}" } unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    text = data.dig('candidates', 0, 'content', 'parts', 0, 'text')
    { text: text&.strip }
  rescue JSON::ParserError => e
    { error: "JSON parse error: #{e.message}" }
  end
end

def word_count(text)
  text.to_s.split.length
end

def run_tests
  tester = GeminiTester.new

  unless tester.available?
    puts "ERROR: No Gemini API key found"
    return
  end

  puts "=" * 80
  puts "COMBAT PROMPT ITERATION TEST"
  puts "Model: Gemini 2.5 Flash-Lite"
  puts "=" * 80

  # Test each prompt with each paragraph
  PROMPTS.each do |prompt_name, prompt|
    puts "\n" + "=" * 80
    puts "PROMPT: #{prompt_name}"
    puts "=" * 80
    puts prompt.gsub('%<paragraph>s', '[PARAGRAPH]').strip
    puts "-" * 80

    total_input_words = 0
    total_output_words = 0
    total_latency = 0

    PARAGRAPHS.each do |para|
      print "  #{para[:name]}... "

      latency = 0
      result = nil
      latency = Benchmark.realtime { result = tester.test(prompt, para[:text]) }
      latency_ms = (latency * 1000).round

      if result[:error]
        puts "ERROR: #{result[:error]}"
        next
      end

      input_words = word_count(para[:text])
      output_words = word_count(result[:text])
      ratio = (output_words.to_f / input_words * 100).round

      total_input_words += input_words
      total_output_words += output_words
      total_latency += latency_ms

      puts "#{latency_ms}ms | #{input_words}w -> #{output_words}w (#{ratio}%)"
      puts "    IN:  #{para[:text]}"
      puts "    OUT: #{result[:text]}"
      puts
    end

    avg_ratio = total_input_words > 0 ? (total_output_words.to_f / total_input_words * 100).round : 0
    avg_latency = total_latency / PARAGRAPHS.length

    puts "-" * 80
    puts "  SUMMARY: #{avg_latency}ms avg | #{total_input_words}w -> #{total_output_words}w total (#{avg_ratio}% of original)"
  end

  puts "\n" + "=" * 80
  puts "TEST COMPLETE"
  puts "=" * 80
end

run_tests if __FILE__ == $PROGRAM_NAME
