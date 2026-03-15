# frozen_string_literal: true

# Uses Gemini Flash to determine if NPC behavior matches trigger conditions.
# Returns confidence score and reasoning for audit trail.
module TriggerLLMMatcherService
  LLM_MODEL = 'gemini-3-flash-preview'
  LLM_PROVIDER = 'google_gemini'

  class << self
    # Check if content matches the trigger condition using LLM
    # @param content [String] The NPC emote or behavior text
    # @param prompt [String] The trigger condition description
    # @param threshold [Float] Minimum confidence (0.0-1.0)
    # @return [Hash] { matched: Boolean, confidence: Float, reasoning: String, details: String }
    def check_match(content:, prompt:, threshold: 0.7)
      return no_match('Empty content') if content.nil? || content.strip.empty?
      return no_match('Empty prompt') if prompt.nil? || prompt.strip.empty?

      llm_prompt = build_prompt(content, prompt)

      result = LLM::Client.generate(
        prompt: llm_prompt,
        model: LLM_MODEL,
        provider: LLM_PROVIDER,
        options: { max_tokens: 200, temperature: 0.1 },
        json_mode: true
      )

      unless result[:success]
        return no_match("LLM error: #{result[:error]}")
      end

      parse_response(result[:text], threshold)
    rescue StandardError => e
      no_match("Error: #{e.message}")
    end

    private

    # Build the LLM prompt for behavior matching
    def build_prompt(content, trigger_condition)
      GamePrompts.get('triggers.behavior_matching',
                      content: content,
                      trigger_condition: trigger_condition)
    end

    # Parse the LLM response
    def parse_response(text, threshold)
      # Strip markdown code fences if present
      clean_text = text.strip
        .gsub(/\A```(?:json)?\s*/, '')
        .gsub(/\s*```\z/, '')

      parsed = JSON.parse(clean_text)

      confidence = parsed['confidence'].to_f.clamp(0.0, 1.0)
      matches = parsed['matches'] == true
      reasoning = parsed['reasoning'].to_s

      # Only match if confidence meets threshold
      matched = matches && confidence >= threshold

      {
        matched: matched,
        confidence: confidence,
        reasoning: reasoning,
        details: "LLM match (confidence: #{(confidence * 100).round(1)}%, threshold: #{(threshold * 100).round(1)}%)"
      }
    rescue JSON::ParserError => e
      no_match("Failed to parse LLM response: #{e.message}")
    end

    # Return a non-match result
    def no_match(reason)
      {
        matched: false,
        confidence: 0.0,
        reasoning: reason,
        details: reason
      }
    end
  end
end
