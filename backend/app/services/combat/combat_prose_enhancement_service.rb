# frozen_string_literal: true

# Enhances combat narrative paragraphs using LLM for more vivid prose.
# Processes paragraphs in parallel for speed.
#
# @example
#   service = CombatProseEnhancementService.new
#   enhanced = service.enhance_paragraphs(["Alpha attacks Beta...", "Beta retreats..."])
#
class CombatProseEnhancementService
  # Model to use for enhancement
  DEFAULT_MODEL = 'gemini-3.1-flash-lite-preview'

  # Minimum paragraph length to consider for enhancement
  MIN_PARAGRAPH_LENGTH = 20

  # Total timeout for all parallel requests (seconds)
  TOTAL_TIMEOUT = 10

  # Timeout for individual requests (seconds)
  REQUEST_TIMEOUT = 8

  def initialize(model: nil)
    @model = model || DEFAULT_MODEL
  end

  # Check if enhancement is available (provider configured)
  # @return [Boolean]
  def available?
    AIProviderService.provider_available?('google_gemini')
  end

  # Check if enhancement is enabled in settings
  # @return [Boolean]
  def self.enabled?
    GameSetting.boolean('combat_llm_enhancement_enabled')
  end

  # Enhance multiple paragraphs in parallel
  # @param paragraphs [Array<String>] paragraphs to enhance
  # @param name_mapping [Hash<String,String>] full_name => short_name mapping for LLM simplification
  # @return [Array<String>] enhanced paragraphs (or originals on failure)
  def enhance_paragraphs(paragraphs, name_mapping: {})
    return paragraphs unless available?
    return paragraphs if paragraphs.empty?

    # Filter out very short paragraphs (not worth enhancing)
    enhanceable = paragraphs.map.with_index do |para, idx|
      { index: idx, text: para, enhance: para.length >= GameConfig::LLM::COMBAT_PROSE[:min_paragraph_length] }
    end

    # Fire off parallel requests for enhanceable paragraphs
    threads = []
    results = Array.new(paragraphs.length)

    enhanceable.each do |item|
      if item[:enhance]
        threads << Thread.new(item) do |it|
          # Pre-process: simplify names, strip HTML
          processed_text, html_mapping = preprocess_for_llm(it[:text], name_mapping)

          # Enhance via LLM
          enhanced = enhance_single(processed_text)

          if enhanced
            results[it[:index]] = postprocess_from_llm(enhanced, name_mapping, html_mapping)
          else
            results[it[:index]] = it[:text]
          end
        end
      else
        # Keep short paragraphs as-is
        results[item[:index]] = item[:text]
      end
    end

    # Wait for all threads with timeout
    deadline = Time.now + GameConfig::LLM::COMBAT_PROSE[:total_timeout]
    threads.each do |thread|
      remaining = deadline - Time.now
      break if remaining <= 0

      thread.join(remaining)
    end

    # Fill in any nil results with originals (timeout or error)
    results.each_with_index do |result, idx|
      results[idx] = paragraphs[idx] if result.nil?
    end

    results
  end

  # Enhance a single paragraph
  # @param paragraph [String] the paragraph to enhance
  # @return [String, nil] enhanced text or nil on failure
  def enhance_single(paragraph)
    return nil unless available?

    prompt = GamePrompts.get('combat.prose_enhancement', paragraph: paragraph)

    response = LLM::Client.generate(
      prompt: prompt,
      provider: 'google_gemini',
      model: @model,
      options: {
        max_tokens: 300,
        temperature: 0.7,
        timeout: GameConfig::LLM::COMBAT_PROSE[:request_timeout]
      }
    )
    return nil unless response[:success]

    # Normalize smart/curly quotes back to straight quotes.
    # LLMs often convert ' to \u2018/\u2019 and " to \u201C/\u201D,
    # which breaks character name matching in MessagePersonalizationService
    # (e.g., "Linis 'Lin' Dao" becomes "Linis \u2018Lin\u2019 Dao").
    normalize_quotes(response[:text])
  rescue StandardError => e
    log_error("Enhancement failed: #{e.message}")
    nil
  end

  private

  # Strip HTML spans and simplify character names before sending to LLM
  # @param paragraph [String] original paragraph text
  # @param name_mapping [Hash<String,String>] full_name => short_name
  # @return [Array(String, Hash)] processed text and html_mapping for restoration
  def preprocess_for_llm(paragraph, name_mapping)
    text = paragraph.dup

    # Step 1: Extract and strip HTML color spans
    text, html_mapping = extract_html_spans(text)

    # Step 2: Replace full names with short names (longest-first to avoid partial matches)
    name_mapping.sort_by { |full, _| -full.length }.each do |full_name, short_name|
      text.gsub!(/(?<=\A|\W)#{Regexp.escape(full_name)}(?=\W|\z)/, short_name)
    end

    [text, html_mapping]
  end

  # Restore full names and re-apply color spans after LLM enhancement
  # @param enhanced [String] LLM-enhanced text
  # @param name_mapping [Hash<String,String>] full_name => short_name
  # @param html_mapping [Hash<String,String>] plain_text => colored_html
  # @return [String] text with full names and color spans restored
  def postprocess_from_llm(enhanced, name_mapping, html_mapping)
    text = normalize_quotes(enhanced)

    # Step 1: Restore full names from short names (longest-first)
    reverse = name_mapping.each_with_object({}) { |(full, short), h| h[short] = full }
    reverse.sort_by { |short, _| -short.length }.each do |short_name, full_name|
      text.gsub!(/(?<=\A|\W)#{Regexp.escape(short_name)}(?=\W|\z)/, full_name)
    end

    # Step 2: Re-apply color spans where plain text survived unchanged (longest-first)
    html_mapping.sort_by { |plain, _| -plain.length }.each do |plain, colored|
      text.gsub!(/(?<=\A|\W)#{Regexp.escape(plain)}(?=\W|\z)/, colored)
    end

    text
  end

  # Find contiguous HTML span groups, return stripped text + mapping
  # @param text [String] text potentially containing HTML color spans
  # @return [Array(String, Hash)] stripped text and {plain_text => colored_html} mapping
  def extract_html_spans(text)
    return [text, {}] unless text.include?('<span')

    html_mapping = {}
    stripped = text.gsub(/(?:<span\s+style="[^"]*">[^<]*<\/span>)+/) do |match|
      plain = match.gsub(/<[^>]+>/, '')
      html_mapping[plain] = match unless plain.strip.empty?
      plain
    end

    [stripped, html_mapping]
  end

  # Normalize smart/curly quotes to straight ASCII quotes
  def normalize_quotes(text)
    return text if text.nil?

    text.gsub(/[\u2018\u2019\u201A]/, "'")
        .gsub(/[\u201C\u201D\u201E]/, '"')
  end

  def log_error(message)
    warn "[CombatProseEnhancement] #{message}" if ENV['DEBUG'] || ENV['LOG_LLM']
  end
end
