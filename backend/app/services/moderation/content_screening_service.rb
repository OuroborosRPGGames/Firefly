# frozen_string_literal: true

# Service for fast, code-based content screening before LLM moderation.
# Detects technical exploits (SQL injection, XSS, prompt injection) without API calls.
#
# Usage:
#   result = ContentScreeningService.screen(
#     content: "hello",
#     character_instance: ci,
#     message_type: 'say'
#   )
#   # => { flagged: false } or { flagged: true, category: 'exploit_attempt', ... }
#
class ContentScreeningService
  # Exploit pattern regexes (pre-compiled for performance)
  EXPLOIT_PATTERNS = {
    sql_injection: [
      /['";]\s*(OR|AND)\s+['"]?\d+['"]?\s*=\s*['"]?\d+/i,
      /UNION\s+(ALL\s+)?SELECT/i,
      /;\s*(DROP|DELETE|UPDATE|INSERT|ALTER)\s/i,
      /--\s*$/,
      /;\s*TRUNCATE\s/i,
      /'\s*OR\s+'[^']*'\s*=\s*'[^']*/i
    ],
    command_injection: [
      /[;&|`]\s*(rm|cat|ls|wget|curl|nc|bash|sh|python|ruby|perl)\s/i,
      /\$\([^)]+\)/,
      /`[^`]+`/,
      /\|\s*(bash|sh|zsh|fish)\b/i
    ],
    xss: [
      /<script[^>]*>/i,
      /javascript:/i,
      /on(load|error|click|mouseover|submit|focus|blur)\s*=/i,
      /<iframe[^>]*>/i,
      /<img[^>]+onerror/i,
      /data:\s*text\/html/i
    ],
    path_traversal: [
      /\.\.[\/\\]/,
      /%2e%2e[\/\\%]/i,
      /\.\.%2f/i,
      /%2e%2e%2f/i
    ],
    prompt_injection: [
      /ignore\s+(all\s+)?previous\s+instructions/i,
      /disregard\s+(all\s+)?(previous|prior|above)\s+(instructions|prompts)/i,
      /forget\s+(everything|all|your)\s+(you('ve)?|instructions)/i,
      /new\s+instructions?:\s/i,
      /you\s+are\s+now\s+(a|an)\s/i,
      /act\s+as\s+(if\s+you\s+are|a)\s/i,
      /system\s*:\s*/i,
      /\[\s*SYSTEM\s*\]/i,
      /pretend\s+you('re|\s+are)\s+(a|an|not)\s/i,
      /override\s+(your\s+)?(programming|instructions|rules)/i,
      /jailbreak/i,
      /DAN\s+mode/i,
      /developer\s+mode/i,
      /ignore\s+safety/i,
      /bypass\s+(your\s+)?(restrictions|filters|rules)/i
    ]
  }.freeze

  class << self
    # Main entry point for pre-LLM screening
    #
    # @param content [String] Message content
    # @param character_instance [CharacterInstance] The sender
    # @param message_type [String] Type of message
    # @return [Hash] { flagged: Boolean, category: String|nil, details: Hash|nil }
    def screen(content:, character_instance:, message_type:)
      return { flagged: false } if StringHelper.blank?(content)

      # Check exploit patterns (security critical)
      exploit_result = check_exploit_patterns(content)
      return exploit_result if exploit_result[:flagged]

      # Spam/obnoxious behavior is LLM-judged, not code-based
      { flagged: false }
    end

    # Check for technical exploit patterns
    #
    # @param content [String] Message content
    # @return [Hash] { flagged: Boolean, category: String|nil, exploit_type: String|nil }
    def check_exploit_patterns(content)
      return { flagged: false } if StringHelper.blank?(content)

      normalized = content.to_s

      EXPLOIT_PATTERNS.each do |exploit_type, patterns|
        patterns.each do |pattern|
          if normalized.match?(pattern)
            return {
              flagged: true,
              category: 'exploit_attempt',
              exploit_type: exploit_type.to_s,
              severity: 'critical',
              details: {
                pattern_matched: pattern.source,
                exploit_category: exploit_type.to_s
              }
            }
          end
        end
      end

      { flagged: false }
    end

    # Check if content contains potential prompt injection
    # More lenient version that just returns true/false
    #
    # @param content [String] Message content
    # @return [Boolean]
    def contains_prompt_injection?(content)
      return false if StringHelper.blank?(content)

      EXPLOIT_PATTERNS[:prompt_injection].any? { |pattern| content.match?(pattern) }
    end

    # Get all exploit types that match the content
    #
    # @param content [String] Message content
    # @return [Array<Symbol>] List of matched exploit types
    def matched_exploit_types(content)
      return [] if StringHelper.blank?(content)

      matches = []
      EXPLOIT_PATTERNS.each do |exploit_type, patterns|
        matches << exploit_type if patterns.any? { |pattern| content.match?(pattern) }
      end
      matches
    end
  end
end
