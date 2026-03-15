# frozen_string_literal: true

module AutoGm
  # AutoGmBrainstormService generates creative adventure ideas using multiple LLMs in parallel.
  #
  # Uses Kimi-k2 and GPT-5.2 simultaneously to generate diverse creative interpretations
  # based on gathered context. These outputs are then synthesized by Opus in the next phase.
  #
  # The service follows the One Page One Shot framework:
  # - Noun (focus): What is the adventure about?
  # - Mission: What must characters do?
  # - Setting: Where does it take place?
  # - Rewards & Perils: Stakes involved
  # - Secrets & Twists: Hidden complications
  # - Inciting Incident: How it starts NOW
  #
  class AutoGmBrainstormService
    extend StringHelper

    # Model configuration for brainstorming
    BRAINSTORM_MODELS = {
      creative_a: { provider: 'openrouter', model: 'moonshotai/kimi-k2-0905' },
      creative_b: { provider: 'openai', model: 'gpt-5.4' }
    }.freeze

    class << self
      # Generate brainstorm ideas from multiple models in parallel
      # @param session [AutoGmSession] the session
      # @param context [Hash] context from AutoGmContextService
      # @param options [Hash] additional options
      # @return [Hash] { success:, outputs: { creative_a:, creative_b: }, seed_terms:, errors: }
      def brainstorm(session:, context:, options: {})
        seed_terms = options[:seed_terms] || SeedTermService.for_generation(:adventure, count: 10)
        prompt = build_prompt(session, context, seed_terms)

        outputs = {}
        errors = []

        # Build batch requests for parallel processing via Sidekiq
        requests = BRAINSTORM_MODELS.map do |key, config|
          {
            prompt: prompt,
            provider: config[:provider],
            model: config[:model],
            options: {
              max_tokens: options[:max_tokens] || 3000,
              temperature: options[:temperature] || 0.9,
              timeout: options[:timeout] || 180
            },
            context: { model_key: key.to_s }
          }
        end

        batch = LLM::Client.batch_submit(requests)
        wait_timeout = (options[:timeout] || 180) + 30
        batch.wait!(timeout: wait_timeout)

        batch.results.each do |request|
          key = request.parsed_context['model_key']&.to_sym
          next unless key

          if request.status == 'completed' && request.response_text
            outputs[key] = request.response_text
          else
            error_msg = request.error_message || 'unknown error'
            errors << "#{key}: #{error_msg}"
          end
        end

        {
          success: outputs.any?,
          outputs: outputs,
          seed_terms: seed_terms,
          errors: errors
        }
      end

      # Generate brainstorm with a single model (for testing/fallback)
      # @param session [AutoGmSession] the session
      # @param context [Hash] context from AutoGmContextService
      # @param model_key [Symbol] :creative_a or :creative_b
      # @param options [Hash] additional options
      # @return [Hash] { success:, output:, model:, error: }
      def brainstorm_single(session:, context:, model_key:, options: {})
        config = BRAINSTORM_MODELS[model_key]
        return { success: false, error: "Unknown model key: #{model_key}" } unless config

        seed_terms = options[:seed_terms] || SeedTermService.for_generation(:adventure, count: 10)
        prompt = build_prompt(session, context, seed_terms)

        result = LLM::Client.generate(
          prompt: prompt,
          provider: config[:provider],
          model: config[:model],
          options: {
            max_tokens: options[:max_tokens] || 3000,
            temperature: options[:temperature] || 0.9,
            timeout: options[:timeout] || 180
          }
        )

        {
          success: result[:success],
          output: result[:text],
          model: config[:model],
          seed_terms: seed_terms,
          error: result[:error]
        }
      end

      # Check if brainstorm models are available
      # @return [Hash] { creative_a: Boolean, creative_b: Boolean }
      def models_available?
        {
          creative_a: AIProviderService.provider_available?('openrouter'),
          creative_b: AIProviderService.provider_available?('openai')
        }
      end

      private

      # Build the brainstorm prompt with context
      # @param session [AutoGmSession] the session
      # @param context [Hash] gathered context
      # @param seed_terms [Array<String>] inspiration terms
      # @return [String] formatted prompt
      def build_prompt(session, context, seed_terms)
        room_context = context[:room_context] || {}

        GamePrompts.get('auto_gm.brainstorm',
                        location_name: room_context[:location_name] || room_context[:name] || 'Unknown Location',
                        location_description: room_context[:description] || 'A mysterious place.',
                        character_summary: format_participants(context[:participant_context] || []),
                        nearby_locations: format_locations(context[:nearby_locations] || []),
                        nearby_memories: format_memories(context[:nearby_memories] || []),
                        character_memories: format_memories(context[:character_memories] || []),
                        local_npcs: format_npcs(context[:local_npcs] || []),
                        narrative_threads: format_narrative_threads(context[:narrative_threads] || []),
                        participant_narrative: format_participant_narrative(context[:participant_narrative] || []),
                        available_stats: format_stat_list(context[:available_stats] || []),
                        seed_terms: seed_terms.join(', '))
      end

      # Format participant context for the prompt
      # @param participants [Array<Hash>] participant context
      # @return [String]
      def format_participants(participants)
        return 'No characters present.' if participants.empty?

        participants.map do |p|
          parts = ["- #{p[:name]}"]
          parts << "(#{p[:race]} #{p[:char_class]}, level #{p[:level]})" if p[:race] && p[:char_class]
          parts << "- Background: #{truncate(p[:background], 100)}" if p[:background]
          if p[:stat_values].is_a?(Array) && p[:stat_values].any?
            stat_str = p[:stat_values].map { |s| "#{s[:name]} #{s[:value]}" }.join(', ')
            parts << "- Stats: #{stat_str}"
          end
          parts.join(' ')
        end.join("\n")
      end

      # Format nearby locations for the prompt
      # @param locations [Array<Hash>] location data
      # @return [String]
      def format_locations(locations)
        return 'No interesting locations found nearby.' if locations.empty?

        locations.map do |l|
          "- #{l[:location_name]}/#{l[:room_name]} (#{l[:type]}, #{l[:distance]} rooms away)"
        end.join("\n")
      end

      # Format memories for the prompt
      # @param memories [Array<Hash>] memory data
      # @return [String]
      def format_memories(memories)
        return 'No relevant memories.' if memories.empty?

        memories.map do |m|
          chars = m[:characters_involved]&.join(', ') || 'unknown'
          "- #{m[:summary]} (involving: #{chars})"
        end.join("\n")
      end

      # Format NPCs for the prompt
      # @param npcs [Array<Hash>] NPC data
      # @return [String]
      def format_npcs(npcs)
        return 'No NPCs nearby.' if npcs.empty?

        npcs.map do |n|
          location = n[:is_in_starting_room] ? 'here' : 'nearby'
          "- #{n[:name]} (#{n[:archetype] || 'unknown type'}, #{location})"
        end.join("\n")
      end

      # Format narrative threads for the prompt
      # @param threads [Array<Hash>] thread data from context
      # @return [String]
      def format_narrative_threads(threads)
        return 'No active storylines.' if threads.empty?

        threads.map do |t|
          line = "- [#{t[:status]}] #{t[:name]}: #{t[:summary] || 'no summary'}"
          pcs = t[:pc_participants]
          if pcs.is_a?(Array) && pcs.any?
            pc_lines = pcs.map { |p| "#{p[:name]} (#{p[:role] || 'involved'}#{p[:reputation] ? ": #{truncate(p[:reputation], 80)}" : ''})" }
            line += "\n  Involved PCs: #{pc_lines.join(', ')}"
          end
          line
        end.join("\n")
      end

      # Format participant narrative profiles for the prompt
      # @param profiles [Array<Hash>] participant narrative data
      # @return [String]
      def format_participant_narrative(profiles)
        return '' if profiles.empty?

        profiles.map do |p|
          parts = ["- #{p[:name]}"]
          parts << "| Reputation: #{truncate(p[:reputation], 100)}" if p[:reputation]
          if p[:active_threads].is_a?(Array) && p[:active_threads].any?
            thread_labels = p[:active_threads].map { |t| "#{t[:name]} (#{t[:role] || 'involved'})" }
            parts << "| In storylines: #{thread_labels.join(', ')}"
          end
          parts.join(' ')
        end.join("\n")
      end

      # Format available stats for prompts
      # @param stats [Array<Hash>] stat data
      # @return [String]
      def format_stat_list(stats)
        return 'No stat system available.' if stats.nil? || stats.empty?

        stats.map { |s| s[:name] }.join(', ')
      end

      # NOTE: truncate method is inherited from StringHelper
    end
  end
end
