# frozen_string_literal: true

module Generators
  # MissionSynthesisService synthesizes brainstorm outputs into a concept-level mission plan
  #
  # Uses Claude Opus to analyze multiple brainstorm outputs and create a coherent,
  # concept-level mission plan. Round details (emit, actions, stats) are produced
  # separately by MissionRoundDetailService.
  #
  # @example Synthesize brainstorm outputs
  #   result = Generators::MissionSynthesisService.synthesize(
  #     brainstorm_outputs: { creative_a: "...", creative_b: "..." },
  #     description: "A heist to steal the Duke's ledger",
  #     setting: :fantasy,
  #     difficulty: :normal,
  #     location_mode: :mission_specific
  #   )
  #
  class MissionSynthesisService
    # Model configuration for synthesis
    SYNTHESIS_MODEL = { provider: 'anthropic', model: 'claude-opus-4-6' }.freeze

    # Valid round types for activities
    VALID_ROUND_TYPES = %w[standard combat branch free_roll persuade rest reflex group_check].freeze

    # Energy categories for pacing validation
    HIGH_ENERGY_TYPES = %w[combat].freeze
    LOW_ENERGY_TYPES = %w[persuade].freeze

    # Valid activity types
    VALID_ACTIVITY_TYPES = %w[mission adventure encounter survival].freeze

    # Difficulty tiers
    DIFFICULTY_TIERS = %w[easy normal hard].freeze

    # JSON Schema for concept-level structured output via Anthropic API
    CONCEPT_SCHEMA = {
      type: 'object',
      properties: {
        title: { type: 'string' },
        summary: { type: 'string' },
        atype: { type: 'string', enum: VALID_ACTIVITY_TYPES },
        theme: { type: 'string' },
        tone_adjectives: { type: 'array', items: { type: 'string' } },
        chekhov_details: { type: 'array', items: { type: 'string' } },
        rounds: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              round_number: { type: 'integer' },
              branch: { type: 'integer' },
              rtype: { type: 'string', enum: VALID_ROUND_TYPES },
              narrative: { type: 'string' },
              location_key: { type: 'string' },
              fail_con: { type: 'string', enum: %w[none difficulty injury harder_finale branch] },
              is_finale: { type: 'boolean' },
              branch_targets: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    text: { type: 'string' },
                    description: { type: 'string' },
                    leads_to_branch: { type: 'integer' }
                  },
                  required: %w[text leads_to_branch],
                  additionalProperties: false
                }
              },
              combat_encounter_key: { type: 'string' }
            },
            required: %w[round_number branch rtype narrative fail_con is_finale],
            additionalProperties: false
          }
        },
        locations: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              key: { type: 'string' },
              name: { type: 'string' },
              description: { type: 'string' },
              room_type: { type: 'string' }
            },
            required: %w[key name],
            additionalProperties: false
          }
        },
        adversaries: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              role: { type: 'string', enum: %w[boss lieutenant minion] },
              behavior: { type: 'string' },
              description: { type: 'string' },
              combat_encounter_key: { type: 'string' }
            },
            required: %w[name role combat_encounter_key],
            additionalProperties: false
          }
        }
      },
      required: %w[title summary atype theme tone_adjectives chekhov_details rounds locations adversaries],
      additionalProperties: false
    }.freeze

    class << self
      # Synthesize brainstorm outputs into a concept-level mission plan
      # @param brainstorm_outputs [Hash] { creative_a:, creative_b: } from MissionBrainstormService
      # @param description [String] Original mission description
      # @param setting [Symbol] World setting
      # @param difficulty [Symbol] Difficulty tier
      # @param location_mode [Symbol] How to handle locations
      # @param options [Hash] Additional options
      # @return [Hash] { success:, plan:, error: }
      def synthesize(brainstorm_outputs:, description:, setting:, difficulty:, location_mode:, activity_type: 'mission', options: {})
        # Handle case where only one brainstorm succeeded
        brainstorm_a = brainstorm_outputs[:creative_a] || '[No output from model A]'
        brainstorm_b = brainstorm_outputs[:creative_b] || '[No output from model B]'

        prompt = build_synthesis_prompt(
          description: description,
          setting: setting,
          difficulty: difficulty,
          location_mode: location_mode,
          brainstorm_a: brainstorm_a,
          brainstorm_b: brainstorm_b,
          activity_type: activity_type
        )

        result = LLM::Client.generate(
          prompt: prompt,
          provider: SYNTHESIS_MODEL[:provider],
          model: SYNTHESIS_MODEL[:model],
          options: {
            max_tokens: options[:max_tokens] || 16000,
            temperature: options[:temperature] || 0.7,
            timeout: options[:timeout] || 300,
            json_schema: CONCEPT_SCHEMA
          },
          json_mode: true
        )

        return { success: false, plan: nil, error: result[:error] } unless result[:success]

        # Parse and validate JSON
        begin
          plan = parse_json_response(result[:text])
          validation = validate_plan(plan, location_mode)

          unless validation[:valid]
            return { success: false, plan: nil, error: "Plan validation failed: #{validation[:errors].join(', ')}" }
          end

          # Normalize the plan
          plan = normalize_plan(plan, location_mode)

          { success: true, plan: plan }
        rescue JSON::ParserError => e
          { success: false, plan: nil, error: "JSON parse error: #{e.message}" }
        end
      end

      # Check if synthesis model is available
      # @return [Boolean]
      def available?
        AIProviderService.provider_available?('anthropic')
      end

      private

      # Build the synthesis prompt
      def build_synthesis_prompt(description:, setting:, difficulty:, location_mode:, brainstorm_a:, brainstorm_b:, activity_type: 'mission')
        GamePrompts.get('missions.synthesis',
                        description: description,
                        setting: setting.to_s.split('_').map(&:capitalize).join(' '),
                        difficulty: difficulty.to_s,
                        location_mode: location_mode.to_s,
                        brainstorm_a: brainstorm_a,
                        brainstorm_b: brainstorm_b,
                        activity_type: activity_type)
      end

      # Parse JSON from LLM response
      def parse_json_response(text)
        # Try to extract JSON from response (may have markdown wrapping)
        json_match = text.match(/\{[\s\S]*\}/)
        raise JSON::ParserError, 'No JSON object found in response' unless json_match

        JSON.parse(json_match[0])
      end

      # Validate the concept-level mission plan structure
      def validate_plan(plan, location_mode)
        errors = []

        # Required top-level fields
        errors << 'Missing title' unless plan['title'].is_a?(String) && !plan['title'].empty?
        errors << 'Missing summary' unless plan['summary'].is_a?(String) && !plan['summary'].empty?

        # Activity type validation
        if plan['atype'] && !VALID_ACTIVITY_TYPES.include?(plan['atype'])
          errors << "Invalid activity type: #{plan['atype']}"
        end

        # Rounds validation
        rounds = plan['rounds']
        unless rounds.is_a?(Array) && rounds.any?
          errors << 'Missing or empty rounds array'
        else
          rounds.each_with_index do |round, i|
            round_errors = validate_round(round, i, location_mode)
            errors.concat(round_errors)
          end

          # Validate branch structure
          branch_errors = validate_branch_structure(rounds)
          errors.concat(branch_errors)
        end

        # Locations validation (if not using existing)
        if location_mode != :existing
          locations = plan['locations']
          if locations.is_a?(Array)
            locations.each_with_index do |loc, i|
              errors << "Location #{i + 1} missing key" unless loc['key']
              errors << "Location #{i + 1} missing name" unless loc['name']
            end
          end
        end

        # Adversaries validation
        adversaries = plan['adversaries']
        if adversaries.is_a?(Array)
          adversaries.each_with_index do |adv, i|
            errors << "Adversary #{i + 1} missing name" unless adv['name']
            if adv['role'] && !%w[boss lieutenant minion].include?(adv['role'])
              errors << "Adversary #{i + 1} has invalid role: #{adv['role']}"
            end
          end
        end

        { valid: errors.empty?, errors: errors }
      end

      # Validate a single round at concept level
      def validate_round(round, index, location_mode)
        errors = []
        idx = index + 1

        # Required fields
        errors << "Round #{idx} missing round_number" unless round['round_number']
        errors << "Round #{idx} missing rtype" unless round['rtype']
        errors << "Round #{idx} missing narrative" unless round['narrative']

        # Round type validation
        if round['rtype'] && !VALID_ROUND_TYPES.include?(round['rtype'])
          errors << "Round #{idx} has invalid rtype: #{round['rtype']}"
        end

        # Branch ID validation (allow up to 10 distinct branches for complex missions)
        branch = round['branch'] || 0
        if branch > 10
          errors << "Round #{idx} branch ID (#{branch}) exceeds maximum (10)"
        end

        # Type-specific validation (concept-level only)
        case round['rtype']
        when 'combat'
          errors << "Round #{idx} (combat) missing combat_encounter_key" unless round['combat_encounter_key']
        when 'branch'
          unless round['branch_targets'].is_a?(Array) && round['branch_targets'].any?
            errors << "Round #{idx} (branch) missing branch_targets"
          end
        end

        # Location validation
        if location_mode == :existing && round['location_key'] && round['location_key'] != 'existing'
          errors << "Round #{idx} specifies location but location_mode is :existing"
        end

        errors
      end

      # Validate branch structure (connectivity, no orphans)
      def validate_branch_structure(rounds)
        errors = []

        # Group by branch
        branches = rounds.group_by { |r| r['branch'] || 0 }

        # Main branch (0) must exist
        unless branches[0]&.any?
          errors << 'No main branch (branch: 0) rounds found'
          return errors
        end

        # Check each branch has unique round numbers (no duplicates within a branch)
        branches.each do |branch_id, branch_rounds|
          numbers = branch_rounds.map { |r| r['round_number'] }.compact
          if numbers.length != numbers.uniq.length
            errors << "Branch #{branch_id} has duplicate round numbers: #{numbers.inspect}"
          end
        end

        # Check that branch_targets reference valid branches
        rounds.each do |round|
          next unless round['rtype'] == 'branch' && round['branch_targets']

          round['branch_targets'].each do |choice|
            target_branch = choice['leads_to_branch']
            next unless target_branch

            unless branches[target_branch]
              errors << "Branch target references non-existent branch #{target_branch}"
            end
          end
        end

        errors
      end

      # Normalize the concept plan (fill defaults, fix minor issues)
      def normalize_plan(plan, location_mode)
        # Set defaults
        plan['atype'] ||= 'mission'

        # Normalize rounds
        plan['rounds']&.each do |round|
          round['branch'] ||= 0
          round['fail_con'] ||= 'none'
          round['is_finale'] = false if round['is_finale'].nil?

          # Ensure location_key for existing mode
          if location_mode == :existing
            round['location_key'] = 'existing'
          end
        end

        # Ensure arrays exist
        plan['locations'] ||= []
        plan['adversaries'] ||= []

        # Check pacing (soft warnings, not errors)
        plan['pacing_warnings'] = check_pacing(plan['rounds'] || [])

        plan
      end

      # Check pacing rules and return warnings (soft validation, never rejects)
      def check_pacing(rounds)
        warnings = []
        main_rounds = rounds.select { |r| (r['branch'] || 0) == 0 }
                            .sort_by { |r| r['round_number'] || 0 }

        main_rounds.each_cons(2) do |a, b|
          if HIGH_ENERGY_TYPES.include?(a['rtype']) && HIGH_ENERGY_TYPES.include?(b['rtype'])
            warnings << "Rounds #{a['round_number']}-#{b['round_number']}: adjacent combat rounds"
          end
          if LOW_ENERGY_TYPES.include?(a['rtype']) && LOW_ENERGY_TYPES.include?(b['rtype'])
            warnings << "Rounds #{a['round_number']}-#{b['round_number']}: adjacent persuade rounds"
          end
        end

        main_rounds.each do |round|
          if round['is_finale'] && round['fail_con'] == 'branch'
            warnings << "Round #{round['round_number']}: climax fail_con is 'branch' (should produce a different ending, not a dead branch)"
          end
        end

        warnings
      end
    end
  end
end
