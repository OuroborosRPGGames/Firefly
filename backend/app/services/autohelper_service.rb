# frozen_string_literal: true

# AutohelperService - AI-powered contextual help assistant
#
# Provides intelligent help responses when standard help lookup fails
# or when users ask questions (queries ending with "?").
#
# Uses:
#   - Voyage AI embeddings for semantic helpfile search
#   - Gemini Flash for response synthesis
#   - 10-minute context memory for follow-up questions
#
# Usage:
#   result = AutohelperService.assist(
#     query: "how do I fight someone?",
#     character_instance: player,
#     suggestions: ["fight", "attack"]  # from suggest_help
#   )
#   result[:response]  # => "To initiate combat, use the 'fight' command..."
#
class AutohelperService
  # Cache TTL for follow-up question context (from centralized config)
  CONTEXT_WINDOW_SECONDS = GameConfig::Cache::AUTOHELPER_WINDOW

  # Maximum helpfiles to retrieve for context
  MAX_HELPFILE_MATCHES = 5

  # Embedding similarity threshold for semantic search
  SIMILARITY_THRESHOLD = 0.3

  # Severity levels ordered from least to most severe (for doc ticket threshold)
  SEVERITY_LEVELS = %w[minor notable critical].freeze

  # Maximum recent rp logs to include in context
  MAX_RECENT_LOGS = 10

  # LLM settings
  LLM_PROVIDER = 'google_gemini'
  LLM_MODEL = 'gemini-3-flash-preview'
  MAX_TOKENS = GameConfig::LLM::MAX_TOKENS[:default]
  TEMPERATURE = GameConfig::LLM::TEMPERATURES[:summary]

  class << self
    # Main entry point - generate AI help response
    #
    # @param query [String] the user's help query
    # @param character_instance [CharacterInstance] the requesting player
    # @param suggestions [Array<String>] Levenshtein suggestions from suggest_help
    # @return [Hash] { success: Boolean, response: String, sources: Array, error: String }
    # @param query [String] the user's help query
    # @param character_instance [CharacterInstance] the requesting player
    # @param suggestions [Array<String>] Levenshtein suggestions from suggest_help
    # @param cached_helpfiles [Array<Hash>, nil] pre-fetched embedding results to avoid duplicate API calls
    def assist(query:, character_instance:, suggestions: [], cached_helpfiles: nil)
      return error_response('No query provided') if query.nil? || query.strip.empty?
      return error_response('Character instance required') unless character_instance
      return error_response('LLM not available') unless llm_available?

      # Strip trailing "?" for cleaner matching
      clean_query = query.gsub(/\?+$/, '').strip

      # Check for prior context (follow-up question detection)
      prior_context = find_prior_context(character_instance.id)

      # Use cached results if provided, otherwise fetch fresh
      matched_helpfiles = if cached_helpfiles
                            format_cached_helpfiles(cached_helpfiles)
                          else
                            search_helpfiles(clean_query)
                          end

      # Gather player context
      player_context = gather_player_context(character_instance)

      # Build and execute LLM prompt
      result = generate_response(
        query: query,
        clean_query: clean_query,
        matched_helpfiles: matched_helpfiles,
        suggestions: suggestions,
        player_context: player_context,
        prior_context: prior_context
      )

      # Cache this request for follow-up context
      if result[:success]
        cache_request(
          character_instance_id: character_instance.id,
          query: query,
          response: result[:response],
          matched_topics: matched_helpfiles.map { |h| h[:topic] }
        )
      end

      # Log the request for analytics
      log_request(
        character_instance: character_instance,
        query: query,
        clean_query: clean_query,
        result: result,
        sources: matched_helpfiles.map { |h| h[:topic] }
      )

      result
    end

    # Check if autohelper should trigger
    #
    # Triggers when:
    # - Feature is enabled in admin settings
    # - Query ends with "?" (explicit question)
    # - OR no suggestions found (standard help completely failed)
    #
    # @param topic [String] the help topic
    # @param has_matches [Boolean] whether suggest_help found matches
    # @return [Boolean]
    def should_trigger?(topic, has_matches:)
      # Check if autohelper is enabled in game settings
      return false unless GameSetting.boolean('autohelper_enabled')

      return true if topic&.strip&.end_with?('?')
      return true unless has_matches

      false
    end

    private

    # Convert pre-fetched Helpfile.search_helpfiles results to autohelper format
    def format_cached_helpfiles(cached)
      cached.map do |r|
        hf = r[:helpfile]
        {
          topic: hf.topic,
          command: hf.command_name,
          summary: hf.summary,
          syntax: hf.syntax,
          description: hf.description,
          aliases: hf.aliases&.to_a || [],
          similarity: r[:similarity]
        }
      end
    rescue StandardError => e
      warn "[AutohelperService] Failed to format cached helpfiles: #{e.message}"
      []
    end

    # Search for semantically similar helpfiles
    def search_helpfiles(query)
      results = Helpfile.search_helpfiles(query, limit: MAX_HELPFILE_MATCHES)

      results.map do |r|
        hf = r[:helpfile]
        {
          topic: hf.topic,
          command: hf.command_name,
          summary: hf.summary,
          syntax: hf.syntax,
          description: hf.description,
          aliases: hf.aliases&.to_a || [],
          similarity: r[:similarity]
        }
      end
    rescue StandardError => e
      warn "[AutohelperService] Helpfile search failed: #{e.message}"
      []
    end

    # Gather recent player context
    def gather_player_context(character_instance)
      context = {}

      # Recent RP logs (what the player has been doing)
      begin
        if defined?(RpLog) && RpLog.respond_to?(:visible_to)
          recent_logs = RpLog.visible_to(character_instance, GameConfig::LLM::AUTOHELPER[:max_recent_logs])
          context[:recent_activity] = recent_logs.map do |log|
            {
              type: log.log_type,
              content: truncate_text(log.content, 100),
              timestamp: log.respond_to?(:display_timestamp) ? log.display_timestamp : log.created_at
            }
          end
        end
      rescue StandardError => e
        warn "[AutohelperService] Failed to get RP logs: #{e.message}"
      end

      # Current room (for context about where they are)
      begin
        if character_instance.respond_to?(:current_room) && character_instance.current_room
          room = character_instance.current_room
          context[:current_room] = {
            name: room.name,
            type: room.respond_to?(:room_type) ? room.room_type : nil
          }
        end
      rescue StandardError => e
        warn "[AutohelperService] Failed to get room: #{e.message}"
      end

      # Combat state
      context[:in_combat] = character_instance.in_combat? if character_instance.respond_to?(:in_combat?)

      context
    end

    # Find prior help request from this player within context window
    def find_prior_context(character_instance_id)
      HelpRequestCache.recent_for(character_instance_id, window: CONTEXT_WINDOW_SECONDS)
    end

    # Cache this request for follow-up context
    def cache_request(character_instance_id:, query:, response:, matched_topics:)
      HelpRequestCache.store(
        character_instance_id: character_instance_id,
        query: query,
        response: response,
        matched_topics: matched_topics
      )
    end

    # Generate LLM response
    def generate_response(query:, clean_query:, matched_helpfiles:, suggestions:, player_context:, prior_context:)
      prompt = build_prompt(
        query: query,
        clean_query: clean_query,
        matched_helpfiles: matched_helpfiles,
        suggestions: suggestions,
        player_context: player_context,
        prior_context: prior_context
      )

      result = LLM::Client.generate(
        prompt: prompt,
        provider: LLM_PROVIDER,
        model: LLM_MODEL,
        json_mode: true,
        options: {
          max_tokens: MAX_TOKENS,
          temperature: TEMPERATURE
        }
      )

      if result[:success] && result[:text]
        parsed = parse_structured_response(result[:text])
        response_text = parsed[:answer]
        doc_assessment = parsed[:doc_assessment]

        # Attempt ticket creation (never block the player response)
        ticket_info = maybe_create_ticket(doc_assessment: doc_assessment, query: query) if doc_assessment

        {
          success: true,
          response: response_text,
          sources: matched_helpfiles.map { |h| h[:topic] },
          error: nil,
          ticket_created: ticket_info&.[](:created) || false,
          ticket_id: ticket_info&.[](:id)
        }
      else
        error_response(result[:error] || 'Failed to generate response')
      end
    rescue StandardError => e
      warn "[AutohelperService] LLM generation failed: #{e.message}"
      error_response("AI help unavailable: #{e.message}")
    end

    def system_prompt
      GamePrompts.get_safe('help.autohelper_with_assessment') || GamePrompts.get('help.system')
    end

    def build_prompt(query:, clean_query:, matched_helpfiles:, suggestions:, player_context:, prior_context:)
      parts = []

      # System context
      parts << system_prompt.strip
      parts << ''

      # Prior context (follow-up question)
      if prior_context
        parts << "PREVIOUS QUESTION (#{prior_context[:seconds_ago]} seconds ago):"
        parts << "Q: #{prior_context[:query]}"
        parts << "A: #{prior_context[:response]}"
        if prior_context[:matched_topics]&.any?
          parts << "Topics covered: #{prior_context[:matched_topics].join(', ')}"
        end
        parts << ''
        parts << 'The player may be asking a follow-up question or is stuck on the same topic.'
        parts << ''
      end

      # Matched helpfiles
      if matched_helpfiles.any?
        parts << 'RELEVANT HELP TOPICS:'
        matched_helpfiles.each do |hf|
          parts << "- #{hf[:command] || hf[:topic]}: #{hf[:summary]}"
          parts << "  Syntax: #{hf[:syntax]}" if hf[:syntax] && !hf[:syntax].to_s.strip.empty?
          if hf[:aliases]&.any?
            parts << "  Aliases: #{hf[:aliases].join(', ')}"
          end
        end
        parts << ''
      end

      # Levenshtein suggestions
      if suggestions&.any?
        parts << "SIMILAR COMMANDS (by spelling): #{suggestions.join(', ')}"
        parts << ''
      end

      # Player context
      if player_context[:in_combat]
        parts << 'NOTE: Player is currently in combat.'
      end
      if player_context[:current_room]
        parts << "LOCATION: #{player_context[:current_room][:name]}"
      end
      parts << ''

      # The actual question
      parts << "PLAYER'S QUESTION: #{query}"
      parts << ''
      parts << 'Respond with valid JSON containing "answer" and "doc_assessment" fields as specified in your instructions.'

      parts.join("\n")
    end

    def llm_available?
      return false unless defined?(LLM::Client)
      return false unless LLM::Client.respond_to?(:available?)

      LLM::Client.available?
    rescue StandardError => e
      warn "[AutohelperService] LLM availability check error: #{e.message}" if ENV['DEBUG']
      false
    end

    def truncate_text(text, max_length)
      return '' if text.nil?

      text = text.to_s
      return text if text.length <= max_length

      "#{text[0, max_length - 3]}..."
    end

    def error_response(message)
      { success: false, response: nil, sources: [], error: message }
    end

    # Parse structured JSON response from LLM
    # Falls back to treating full text as the answer if JSON parsing fails
    def parse_structured_response(text)
      # Strip markdown code fences (known Gemini behavior)
      cleaned = text.strip
      cleaned = cleaned.sub(/\A```(?:json)?\s*\n?/, '').sub(/\n?\s*```\z/, '')

      parsed = JSON.parse(cleaned, symbolize_names: true)
      answer = parsed[:answer] || cleaned
      doc_assessment = parsed[:doc_assessment]

      { answer: answer, doc_assessment: doc_assessment }
    rescue JSON::ParserError
      warn "[AutohelperService] Failed to parse JSON response, falling back to plain text"
      { answer: text.strip, doc_assessment: nil }
    end

    # Create a documentation ticket if severity meets threshold and no duplicate exists
    def maybe_create_ticket(doc_assessment:, query:)
      return unless doc_assessment.is_a?(Hash)
      return unless doc_assessment[:has_issue] == true

      issue_type = doc_assessment[:issue_type]
      severity = doc_assessment[:severity]
      topic = doc_assessment[:topic]
      description = doc_assessment[:description]

      return if StringHelper.blank?(topic) || StringHelper.blank?(description)

      # Check severity against threshold
      threshold = GameSetting.get('autohelper_ticket_threshold') || 'notable'
      return unless severity_meets_threshold?(severity, threshold)

      # Deduplicate against open documentation tickets
      return if duplicate_ticket_exists?(topic)

      # Create the ticket
      ticket = Ticket.create(
        user_id: nil,
        category: 'documentation',
        system_generated: true,
        subject: "[#{issue_type}] #{topic}"[0, 200],
        content: "#{description}\n\nTriggered by player query: #{query}"[0, 5000],
        status: 'open',
        game_context: query&.[](0, 500)
      )
      warn "[AutohelperService] Created documentation ticket ##{ticket.id}: #{topic}"
      { created: true, id: ticket.id }
    rescue StandardError => e
      warn "[AutohelperService] Failed to create documentation ticket: #{e.message}"
      nil
    end

    def severity_meets_threshold?(severity, threshold)
      severity_index = SEVERITY_LEVELS.index(severity.to_s)
      threshold_index = SEVERITY_LEVELS.index(threshold.to_s)
      return false unless severity_index && threshold_index

      severity_index >= threshold_index
    end

    # Log every autohelper request for analytics
    def log_request(character_instance:, query:, clean_query:, result:, sources:)
      AutohelperRequest.create(
        user_id: character_instance.character&.user_id,
        character_instance_id: character_instance.id,
        query: query[0, 500],
        clean_query: clean_query[0, 500],
        success: result[:success] || false,
        sources: Sequel.pg_array(sources || []),
        ticket_created: result[:ticket_created] || false,
        ticket_id: result[:ticket_id],
        error_message: result[:error]
      )
    rescue StandardError => e
      warn "[AutohelperService] Failed to log request: #{e.message}"
    end

    def duplicate_ticket_exists?(topic)
      escaped = topic.to_s.gsub('%', '\%').gsub('_', '\_')
      Ticket.where(category: 'documentation', system_generated: true)
            .status_open
            .where(Sequel.ilike(:subject, "%#{escaped}%"))
            .any?
    rescue StandardError => e
      warn "[AutohelperService] Deduplication check failed: #{e.message}"
      false
    end
  end
end
