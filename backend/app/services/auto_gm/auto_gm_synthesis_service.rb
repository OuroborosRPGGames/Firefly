# frozen_string_literal: true

module AutoGm
  # AutoGmSynthesisService synthesizes brainstorm outputs into a structured adventure sketch.
  #
  # Uses Claude Opus 4.5 to analyze multiple brainstorm outputs and create a coherent,
  # structured One Page One Shot adventure sketch that drives the GM loop.
  #
  # The output sketch follows this structure:
  # - noun: Central focus (type, adjective, name, description)
  # - setting: Primary location and atmosphere
  # - mission: Objective, success/failure conditions
  # - rewards_perils: Stakes involved
  # - secrets_twists: Hidden complications
  # - inciting_incident: How it starts
  # - structure: Three-act, countdown, or five-room
  # - stages: Sequence of adventure beats
  #
  class AutoGmSynthesisService
    # Model configuration for synthesis
    SYNTHESIS_MODEL = { provider: 'anthropic', model: 'claude-opus-4-6' }.freeze

    # Valid noun types
    NOUN_TYPES = %w[person artefact location creature plot].freeze

    # Valid noun adjectives
    NOUN_ADJECTIVES = %w[dangerous powerful valuable meaningful mysterious].freeze

    # Valid mission types
    MISSION_TYPES = %w[discover destroy defend investigate rescue escape].freeze

    # Valid inciting incident types
    INCIDENT_TYPES = %w[attack arrival discovery distress environmental].freeze

    # Valid twist types
    TWIST_TYPES = %w[betrayal test bigger_threat mistaken_identity cursed_item hidden_ally].freeze

    # Valid structure types
    STRUCTURE_TYPES = %w[three_act countdown five_room].freeze

    # Valid NPC roles
    NPC_ROLES = %w[antagonist ally victim witness guide obstacle].freeze

    class << self
      # Synthesize brainstorm outputs into a structured adventure sketch
      # @param brainstorm_outputs [Hash] { creative_a: String, creative_b: String }
      # @param context [Hash] context from AutoGmContextService
      # @param options [Hash] additional options
      # @return [Hash] { success:, sketch:, locations_used:, error: }
      def synthesize(brainstorm_outputs:, context:, options: {})
        brainstorm_a = brainstorm_outputs[:creative_a] || '[No output from model A]'
        brainstorm_b = brainstorm_outputs[:creative_b] || '[No output from model B]'

        prompt = build_prompt(brainstorm_a, brainstorm_b, context)

        result = LLM::Client.generate(
          prompt: prompt,
          provider: SYNTHESIS_MODEL[:provider],
          model: SYNTHESIS_MODEL[:model],
          options: {
            max_tokens: options[:max_tokens] || 4000,
            temperature: options[:temperature] || 0.7,
            timeout: options[:timeout] || 180
          },
          json_mode: true
        )

        return { success: false, error: result[:error] } unless result[:success]

        begin
          # Strip markdown code fences if present (```json ... ```)
          text = result[:text].strip
          text = text.sub(/\A```(?:json)?\s*\n?/, '').sub(/\n?\s*```\z/, '') if text.start_with?('```')
          sketch = JSON.parse(text)
          validation = validate_sketch(sketch, context)

          unless validation[:valid]
            return { success: false, error: "Validation failed: #{validation[:errors].join(', ')}" }
          end

          {
            success: true,
            sketch: normalize_sketch(sketch),
            locations_used: sketch['locations_used'] || [],
            raw_response: result[:text]
          }
        rescue JSON::ParserError => e
          { success: false, error: "JSON parse error: #{e.message}" }
        end
      end

      # Synthesize with a fallback for partial brainstorm outputs
      # @param brainstorm_outputs [Hash] may have only one output
      # @param context [Hash] context
      # @param options [Hash] options
      # @return [Hash] result
      def synthesize_with_fallback(brainstorm_outputs:, context:, options: {})
        # If we only have one output, duplicate it for both slots
        outputs = brainstorm_outputs.dup
        if outputs[:creative_a] && !outputs[:creative_b]
          outputs[:creative_b] = '[Model B unavailable - using single brainstorm]'
        elsif outputs[:creative_b] && !outputs[:creative_a]
          outputs[:creative_a] = '[Model A unavailable - using single brainstorm]'
        end

        synthesize(brainstorm_outputs: outputs, context: context, options: options)
      end

      private

      # Build the synthesis prompt
      # @param brainstorm_a [String] output from creative model A
      # @param brainstorm_b [String] output from creative model B
      # @param context [Hash] gathered context
      # @return [String] formatted prompt
      def build_prompt(brainstorm_a, brainstorm_b, context)
        GamePrompts.get('auto_gm.synthesis',
                        brainstorm_a: brainstorm_a,
                        brainstorm_b: brainstorm_b,
                        nearby_locations: format_locations_for_synthesis(context[:nearby_locations] || []),
                        room_context: format_room_context(context[:room_context] || {}),
                        participants: format_participants(context[:participant_context] || []),
                        available_stats: format_stat_names(context[:stat_names] || []))
      end

      # Format locations with IDs for synthesis
      # @param locations [Array<Hash>] location data
      # @return [String]
      def format_locations_for_synthesis(locations)
        return 'No nearby locations available.' if locations.empty?

        locations.map do |l|
          "- ID: #{l[:location_id]}, Room ID: #{l[:room_id]}, Name: #{l[:location_name]}/#{l[:room_name]}, Type: #{l[:type]}, Distance: #{l[:distance]} rooms"
        end.join("\n")
      end

      # Format room context for synthesis
      # @param room [Hash] room context
      # @return [String]
      def format_room_context(room)
        return 'No room context available.' if room.empty?

        parts = []
        parts << "Name: #{room[:name]}" if room[:name]
        parts << "Location: #{room[:location_name]}" if room[:location_name]
        parts << "Type: #{room[:room_type]}" if room[:room_type]
        parts << "Description: #{room[:description]}" if room[:description]
        parts.join("\n")
      end

      # Format stat names for synthesis
      # @param stat_names [Array<String>] stat names
      # @return [String]
      def format_stat_names(stat_names)
        return 'No stat system available — omit stat references in challenges.' if stat_names.empty?

        stat_names.join(', ')
      end

      # Format participants for synthesis
      # @param participants [Array<Hash>] participant context
      # @return [String]
      def format_participants(participants)
        return 'No participants.' if participants.empty?

        participants.map do |p|
          parts = [p[:name]]
          parts << "(#{p[:race]} #{p[:char_class]}, level #{p[:level]})" if p[:race] && p[:char_class]
          parts.join(' ')
        end.join(', ')
      end

      # Validate the sketch against schema requirements
      # @param sketch [Hash] parsed sketch
      # @param context [Hash] gathered context
      # @return [Hash] { valid: Boolean, errors: Array<String> }
      def validate_sketch(sketch, context)
        errors = []

        # Required top-level fields
        errors << 'Missing title' unless sketch['title']
        errors << 'Missing noun' unless sketch['noun']
        errors << 'Missing mission' unless sketch['mission']
        errors << 'Missing structure' unless sketch['structure']
        errors << 'Missing inciting_incident' unless sketch['inciting_incident']

        # Validate noun
        if sketch['noun']
          errors << 'Invalid noun type' unless NOUN_TYPES.include?(sketch.dig('noun', 'type'))
          errors << 'Invalid noun adjective' unless NOUN_ADJECTIVES.include?(sketch.dig('noun', 'adjective'))
        end

        # Validate mission
        if sketch['mission']
          errors << 'Invalid mission type' unless MISSION_TYPES.include?(sketch.dig('mission', 'type'))
        end

        # Validate structure
        if sketch['structure']
          errors << 'Invalid structure type' unless STRUCTURE_TYPES.include?(sketch.dig('structure', 'type'))
          stages = sketch.dig('structure', 'stages')
          errors << 'No stages defined' if stages.nil? || stages.empty?
          errors << 'Too few stages (need at least 3)' if stages && stages.length < 3

          # Normalize suggested_challenges on each stage (soft — don't reject if missing)
          if stages
            stages.each do |stage|
              stage['suggested_challenges'] ||= []
            end
          end
        end

        # Validate inciting incident
        if sketch['inciting_incident']
          errors << 'Invalid incident type' unless INCIDENT_TYPES.include?(sketch.dig('inciting_incident', 'type'))
        end

        # Validate twist type if present
        if sketch.dig('secrets_twists', 'twist_type')
          errors << 'Invalid twist type' unless TWIST_TYPES.include?(sketch.dig('secrets_twists', 'twist_type'))
        end

        # Validate location IDs exist in context
        if sketch['locations_used']
          valid_location_ids = (context[:nearby_locations] || []).map { |l| l[:location_id] }
          invalid_ids = sketch['locations_used'].reject { |id| valid_location_ids.include?(id) }
          errors << "Invalid location IDs: #{invalid_ids.join(', ')}" if invalid_ids.any?
        end

        { valid: errors.empty?, errors: errors }
      end

      # Normalize and fill in defaults for the sketch
      # @param sketch [Hash] the sketch to normalize
      # @return [Hash] normalized sketch
      def normalize_sketch(sketch)
        # Fill in defaults
        sketch['game_elements'] ||= ['exploration', 'social_skills']
        sketch['structure'] ||= {}
        sketch['structure']['type'] ||= 'three_act'
        sketch['locations_used'] ||= []
        sketch['npcs_to_spawn'] ||= []

        # Ensure rewards_perils exists
        sketch['rewards_perils'] ||= { 'rewards' => [], 'perils' => [] }

        # Ensure secrets_twists exists
        sketch['secrets_twists'] ||= { 'secrets' => [], 'twist_type' => nil }

        # Mark which stage is the climax if not already marked
        if sketch.dig('structure', 'stages')
          stages = sketch['structure']['stages']
          has_climax = stages.any? { |s| s['is_climax'] }
          unless has_climax
            # Mark the second-to-last stage as climax (last is typically resolution)
            climax_index = [stages.length - 2, 0].max
            stages[climax_index]['is_climax'] = true
          end
        end

        sketch
      end
    end
  end
end
