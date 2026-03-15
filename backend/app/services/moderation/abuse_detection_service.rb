# frozen_string_literal: true

# Service for detecting abusive content using two-tier AI moderation.
#
# Uses Gemini Flash Lite for fast initial screening and
# Claude Opus 4.6 for verification of flagged content.
#
# The key distinction is between IC (in-character) conflict which is acceptable
# and OOC (out-of-character) harassment which is not.
#
class AbuseDetectionService
  # Model configuration
  GEMINI_MODEL = 'gemini-3.1-flash-lite-preview'
  GEMINI_PROVIDER = 'google_gemini'
  CLAUDE_MODEL = 'claude-opus-4-6'
  CLAUDE_PROVIDER = 'anthropic'

  class << self
    # First-pass check with Gemini Flash
    #
    # @param check [AbuseCheck] The abuse check record
    # @return [Hash] { flagged: Boolean, confidence: Float, reasoning: String, category: String }
    def gemini_check(check)
      prompt = GamePrompts.get('abuse_detection.first_pass',
                               message_type: check.message_type,
                               content: check.message_content)

      result = LLM::Client.generate(
        prompt: prompt,
        model: GEMINI_MODEL,
        provider: GEMINI_PROVIDER,
        json_mode: true,
        options: {
          max_tokens: 500,
          temperature: 0.1
        }
      )

      if result[:success]
        parse_gemini_response(result[:text])
      else
        # On error, don't flag (fail open for first pass)
        warn "[AbuseDetection] Gemini error: #{result[:error]}"
        default_gemini_result(false, "API error: #{result[:error]}")
      end
    rescue StandardError => e
      warn "[AbuseDetection] Gemini exception: #{e.message}"
      default_gemini_result(false, "Exception: #{e.message}")
    end

    # Second-pass verification with Claude Opus
    #
    # @param check [AbuseCheck] The abuse check record (already flagged by Gemini)
    # @return [Hash] { confirmed: Boolean, confidence: Float, reasoning: String, category: String, severity: String }
    def claude_verify(check)
      context = check.parsed_context
      recent_messages = context['recent_messages'] || []

      prompt = GamePrompts.get('abuse_detection.verification',
                               message_type: check.message_type,
                               content: check.message_content,
                               gemini_category: check.abuse_category || 'unknown',
                               gemini_confidence: check.gemini_confidence || 0.0,
                               gemini_reasoning: check.gemini_reasoning || 'No reasoning provided',
                               room_name: context['room_name'] || 'Unknown',
                               recent_messages: format_recent_messages(recent_messages))

      result = LLM::Client.generate(
        prompt: prompt,
        model: CLAUDE_MODEL,
        provider: CLAUDE_PROVIDER,
        json_mode: true,
        options: {
          max_tokens: 1000,
          temperature: 0.0  # Deterministic for moderation
        }
      )

      if result[:success]
        parse_claude_response(result[:text])
      else
        # On error, don't confirm (fail safe for second pass)
        warn "[AbuseDetection] Claude error: #{result[:error]}"
        default_claude_result(false, "API error: #{result[:error]}")
      end
    rescue StandardError => e
      warn "[AbuseDetection] Claude exception: #{e.message}"
      default_claude_result(false, "Exception: #{e.message}")
    end

    private

    # Parse Gemini JSON response
    def parse_gemini_response(text)
      json = extract_json(text)
      {
        flagged: json['flagged'] == true,
        confidence: (json['confidence'] || 0.0).to_f.clamp(0.0, 1.0),
        reasoning: json['reasoning'] || 'No reasoning provided',
        category: normalize_category(json['category'])
      }
    rescue JSON::ParserError => e
      warn "[AbuseDetection] Failed to parse Gemini response: #{e.message}"
      default_gemini_result(false, "JSON parse error")
    end

    # Parse Claude JSON response
    def parse_claude_response(text)
      json = extract_json(text)
      {
        confirmed: json['confirmed'] == true,
        confidence: (json['confidence'] || 0.0).to_f.clamp(0.0, 1.0),
        reasoning: json['reasoning'] || 'No reasoning provided',
        category: normalize_category(json['category']),
        severity: normalize_severity(json['severity']),
        recommended_action: json['recommended_action'] || 'none'
      }
    rescue JSON::ParserError => e
      warn "[AbuseDetection] Failed to parse Claude response: #{e.message}"
      default_claude_result(false, "JSON parse error")
    end

    # Extract JSON from text (handles markdown code blocks)
    def extract_json(text)
      # Try to extract JSON from markdown code block
      if text =~ /```(?:json)?\s*(\{.*?\})\s*```/m
        JSON.parse(::Regexp.last_match(1))
      elsif text =~ /(\{.*\})/m
        # Try to find any JSON object
        JSON.parse(::Regexp.last_match(1))
      else
        JSON.parse(text)
      end
    end

    # Normalize category to valid values
    def normalize_category(category)
      valid = %w[harassment hate_speech threats doxxing spam csam other false_positive none]
      cat = category.to_s.downcase.strip
      valid.include?(cat) ? cat : 'other'
    end

    # Normalize severity to valid values
    def normalize_severity(severity)
      valid = %w[low medium high critical]
      sev = severity.to_s.downcase.strip
      valid.include?(sev) ? sev : 'medium'
    end

    # Format recent messages for context
    def format_recent_messages(messages)
      return "(no recent messages)" if messages.nil? || messages.empty?

      messages.first(5).map.with_index do |msg, i|
        "#{i + 1}. #{msg}"
      end.join("\n")
    end

    # Default Gemini result on error
    def default_gemini_result(flagged, reasoning)
      {
        flagged: flagged,
        confidence: 0.0,
        reasoning: reasoning,
        category: 'none'
      }
    end

    # Default Claude result on error
    def default_claude_result(confirmed, reasoning)
      {
        confirmed: confirmed,
        confidence: 0.0,
        reasoning: reasoning,
        category: 'false_positive',
        severity: 'low',
        recommended_action: 'none'
      }
    end
  end
end
