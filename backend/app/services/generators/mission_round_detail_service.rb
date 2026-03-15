# frozen_string_literal: true

module Generators
  # MissionRoundDetailService expands round sketches into fully detailed round data.
  #
  # Takes a concept plan from MissionSynthesisService and produces detailed fields
  # for each round in parallel using Sonnet via batch LLM calls.
  #
  # @example Expand round details
  #   result = Generators::MissionRoundDetailService.detail_rounds(
  #     concept_plan: plan,
  #     available_stats: [{ id: 1, name: 'Strength', abbreviation: 'STR' }],
  #     options: { timeout: 120 }
  #   )
  #
  class MissionRoundDetailService
    DETAIL_MODEL = { provider: 'anthropic', model: 'claude-sonnet-4-6' }.freeze

    # Round-type-specific JSON schemas for structured output
    ROUND_SCHEMAS = {
      'standard' => {
        type: 'object',
        properties: {
          emit: { type: 'string' },
          succ_text: { type: 'string' },
          fail_text: { type: 'string' },
          fail_repeat: { type: 'boolean' },
          knockout: { type: 'boolean' },
          actions: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                choice_text: { type: 'string' },
                output_string: { type: 'string' },
                fail_string: { type: 'string' },
                stat_ids: { type: 'array', items: { type: 'integer' } }
              },
              required: %w[choice_text output_string fail_string stat_ids],
              additionalProperties: false
            }
          }
        },
        required: %w[emit succ_text fail_text fail_repeat knockout actions],
        additionalProperties: false
      }.freeze,

      'combat' => {
        type: 'object',
        properties: {
          emit: { type: 'string' },
          succ_text: { type: 'string' },
          fail_text: { type: 'string' },
          fail_repeat: { type: 'boolean' },
          knockout: { type: 'boolean' },
          combat_encounter_name: { type: 'string' },
          combat_difficulty: { type: 'string', enum: %w[easy normal hard deadly] }
        },
        required: %w[emit succ_text fail_text fail_repeat knockout combat_encounter_name combat_difficulty],
        additionalProperties: false
      }.freeze,

      'persuade' => {
        type: 'object',
        properties: {
          emit: { type: 'string' },
          succ_text: { type: 'string' },
          fail_text: { type: 'string' },
          fail_repeat: { type: 'boolean' },
          knockout: { type: 'boolean' },
          persuade_npc_name: { type: 'string' },
          persuade_goal: { type: 'string' },
          persuade_base_dc: { type: 'integer' },
          persuade_npc_personality: { type: 'string' },
          persuade_stat_ids: { type: 'array', items: { type: 'integer' } }
        },
        required: %w[emit succ_text fail_text fail_repeat knockout persuade_npc_name persuade_goal persuade_base_dc persuade_npc_personality persuade_stat_ids],
        additionalProperties: false
      }.freeze,

      'reflex' => {
        type: 'object',
        properties: {
          emit: { type: 'string' },
          succ_text: { type: 'string' },
          fail_text: { type: 'string' },
          fail_repeat: { type: 'boolean' },
          knockout: { type: 'boolean' },
          reflex_stat_id: { type: 'integer' },
          timeout_seconds: { type: 'integer' }
        },
        required: %w[emit succ_text fail_text fail_repeat knockout reflex_stat_id timeout_seconds],
        additionalProperties: false
      }.freeze,

      'group_check' => {
        type: 'object',
        properties: {
          emit: { type: 'string' },
          succ_text: { type: 'string' },
          fail_text: { type: 'string' },
          fail_repeat: { type: 'boolean' },
          knockout: { type: 'boolean' },
          stat_set_a: { type: 'array', items: { type: 'integer' } }
        },
        required: %w[emit succ_text fail_text fail_repeat knockout stat_set_a],
        additionalProperties: false
      }.freeze,

      'branch' => {
        type: 'object',
        properties: {
          emit: { type: 'string' },
          branch_choices: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                text: { type: 'string' },
                description: { type: 'string' },
                leads_to_branch: { type: 'integer' }
              },
              required: %w[text description leads_to_branch],
              additionalProperties: false
            }
          }
        },
        required: %w[emit branch_choices],
        additionalProperties: false
      }.freeze,

      'free_roll' => {
        type: 'object',
        properties: {
          emit: { type: 'string' },
          succ_text: { type: 'string' },
          fail_text: { type: 'string' },
          fail_repeat: { type: 'boolean' },
          knockout: { type: 'boolean' },
          free_roll_context: { type: 'string' }
        },
        required: %w[emit succ_text fail_text fail_repeat knockout free_roll_context],
        additionalProperties: false
      }.freeze,

      'rest' => {
        type: 'object',
        properties: {
          emit: { type: 'string' }
        },
        required: %w[emit],
        additionalProperties: false
      }.freeze
    }.freeze

    class << self
      # Expand round sketches into detailed round data
      # @param concept_plan [Hash] Plan from MissionSynthesisService (concept-level)
      # @param available_stats [Array<Hash>] Stats with :id, :name, :abbreviation
      # @param options [Hash] Additional options
      # @return [Hash] { success:, plan:, errors: }
      def detail_rounds(concept_plan:, available_stats: [], options: {})
        rounds = concept_plan['rounds'] || []
        return { success: true, plan: concept_plan, errors: [] } if rounds.empty?

        # Build batch requests for all rounds in parallel
        requests = rounds.each_with_index.map do |round_sketch, idx|
          build_round_request(round_sketch, idx, concept_plan, available_stats, options)
        end

        # Submit all requests in parallel
        batch = LLM::Client.batch_submit(requests)
        wait_timeout = (options[:timeout] || 120) + 30
        batch.wait!(timeout: wait_timeout)

        # Merge results back into the plan
        errors = []
        detailed_rounds = []

        batch.results.each do |request|
          ctx = request.parsed_context
          round_idx = ctx['round_index']
          round_sketch = rounds[round_idx]

          if request.status == 'completed' && request.response_text
            begin
              detail = parse_json(request.response_text)
              # Merge sketch fields with detail
              merged = round_sketch.slice('round_number', 'branch', 'rtype', 'location_key', 'fail_con', 'is_finale')
              merged.merge!(detail)
              # For branch rounds, carry over branch_targets as branch_choices if not in detail
              if round_sketch['rtype'] == 'branch' && !merged['branch_choices'] && round_sketch['branch_targets']
                merged['branch_choices'] = round_sketch['branch_targets']
              end
              detailed_rounds << merged
            rescue JSON::ParserError => e
              warn "[MissionRoundDetail] Round #{round_sketch['round_number']}: JSON parse error: #{e.message}"
              errors << "Round #{round_sketch['round_number']}: JSON parse error: #{e.message}"
              detailed_rounds << fallback_round(round_sketch)
            end
          else
            error_msg = request.error_message || 'unknown error'
            warn "[MissionRoundDetail] Round #{round_sketch['round_number']}: #{error_msg}"
            errors << "Round #{round_sketch['round_number']}: #{error_msg}"
            detailed_rounds << fallback_round(round_sketch)
          end
        end

        # Sort by branch then round_number to maintain order
        detailed_rounds.sort_by! { |r| [r['branch'] || 0, r['round_number'] || 0] }

        # Replace rounds in plan with detailed versions
        enriched_plan = concept_plan.dup
        enriched_plan['rounds'] = detailed_rounds

        { success: errors.empty? || detailed_rounds.any?, plan: enriched_plan, errors: errors }
      end

      private

      # Build a batch request for a single round
      def build_round_request(round_sketch, round_index, concept_plan, available_stats, options)
        rtype = round_sketch['rtype'] || 'standard'
        schema = ROUND_SCHEMAS[rtype] || ROUND_SCHEMAS['standard']

        prompt = build_round_prompt(round_sketch, concept_plan, available_stats, rtype)

        {
          prompt: prompt,
          provider: DETAIL_MODEL[:provider],
          model: DETAIL_MODEL[:model],
          options: {
            max_tokens: options[:max_tokens] || 8000,
            temperature: options[:temperature] || 0.7,
            timeout: options[:timeout] || 120,
            json_schema: schema
          },
          json_mode: true,
          context: {
            round_index: round_index,
            round_number: round_sketch['round_number'],
            rtype: rtype
          }
        }
      end

      # Build the prompt for detailing a single round
      def build_round_prompt(round_sketch, concept_plan, available_stats, rtype)
        stats_text = if available_stats.any?
                       available_stats.map { |s| "- ID: #{s[:id]}, Name: #{s[:name]}, Abbreviation: #{s[:abbreviation]}" }.join("\n")
                     else
                       '(No stats available - use empty arrays for stat fields)'
                     end

        # Type-specific context
        type_context = build_type_context(round_sketch, concept_plan, rtype)

        GamePrompts.get('missions.round_detail',
                        title: concept_plan['title'],
                        summary: concept_plan['summary'],
                        theme: concept_plan['theme'],
                        tone: (concept_plan['tone_adjectives'] || []).join(', '),
                        round_number: round_sketch['round_number'],
                        rtype: rtype,
                        narrative: round_sketch['narrative'],
                        fail_con: round_sketch['fail_con'],
                        is_finale: round_sketch['is_finale'],
                        available_stats: stats_text,
                        type_context: type_context)
      end

      # Build type-specific context for the round detail prompt
      def build_type_context(round_sketch, concept_plan, rtype)
        case rtype
        when 'combat'
          adversaries = concept_plan['adversaries'] || []
          encounter_keys = adversaries.map { |a| a['combat_encounter_key'] }.compact
          "COMBAT CONTEXT:\nAvailable combat encounters (use one as combat_encounter_name): #{encounter_keys.join(', ')}\nAdversaries: #{adversaries.map { |a| "#{a['name']} (#{a['role']}) - #{a['description']}" }.join('; ')}"
        when 'branch'
          targets = round_sketch['branch_targets'] || []
          "BRANCH CONTEXT:\nBranch targets from concept plan:\n#{targets.map { |t| "- \"#{t['text']}\" -> branch #{t['leads_to_branch']}" }.join("\n")}\nExpand each into a branch_choice with text, description, and leads_to_branch."
        when 'persuade'
          "PERSUADE CONTEXT:\nDesign an NPC for this social encounter. Write persuade_npc_personality as a detailed system prompt that defines the NPC's personality, speech patterns, what they want, what scares them, what approach works, what makes them shut down, and what they'll never agree to."
        when 'free_roll'
          "FREE ROLL CONTEXT:\nWrite free_roll_context as a detailed scene description and set of constraints for open-ended player action. The AI GM will use this to set DCs and pick stats based on what players describe."
        when 'reflex'
          "REFLEX CONTEXT:\nThis is a fast danger check (timeout). Pick a stat that matches the danger type (typically DEX/AGI for physical reflexes). Set timeout_seconds between 60-180."
        when 'group_check'
          "GROUP CHECK CONTEXT:\nPick 2-3 stat IDs for stat_set_a. Players use whichever they're strongest in. Pick stats that thematically match the challenge."
        when 'rest'
          "REST CONTEXT:\nThis is a recovery round. Write emit as a brief atmospheric scene where the party catches their breath."
        else
          ''
        end
      end

      # Parse JSON from LLM response
      def parse_json(text)
        json_match = text.match(/\{[\s\S]*\}/)
        raise JSON::ParserError, 'No JSON object found' unless json_match

        JSON.parse(json_match[0])
      end

      # Create a fallback round from a sketch when detail fails
      def fallback_round(round_sketch)
        {
          'round_number' => round_sketch['round_number'],
          'branch' => round_sketch['branch'] || 0,
          'rtype' => round_sketch['rtype'] || 'standard',
          'emit' => round_sketch['narrative'] || 'The adventure continues...',
          'fail_con' => round_sketch['fail_con'] || 'none',
          'fail_repeat' => false,
          'knockout' => false,
          'is_finale' => round_sketch['is_finale'] || false,
          'location_key' => round_sketch['location_key']
        }
      end
    end
  end
end
