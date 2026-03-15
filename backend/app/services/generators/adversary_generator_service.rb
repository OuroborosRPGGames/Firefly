# frozen_string_literal: true

module Generators
  # AdversaryGeneratorService generates NpcArchetype records for mission combat encounters
  #
  # Creates combat-ready NPCs with stats scaled by difficulty tier and role (boss/lieutenant/minion).
  # Uses LLM to generate appropriate combat stats based on adversary description.
  #
  # @example Generate adversaries from mission plan
  #   result = Generators::AdversaryGeneratorService.generate(
  #     adversaries: plan['adversaries'],
  #     setting: :fantasy,
  #     difficulty: :normal,
  #     activity_id: activity.id
  #   )
  #
  class AdversaryGeneratorService
    # Model for stat generation
    STATS_MODEL = { provider: 'google_gemini', model: 'gemini-3-flash-preview' }.freeze

    # Base stat ranges by role
    ROLE_STATS = {
      boss: {
        hp_range: 25..40,
        damage_bonus_range: 4..6,
        defense_bonus_range: 2..4,
        dice_count: 3..4,
        dice_sides: 8
      },
      lieutenant: {
        hp_range: 15..25,
        damage_bonus_range: 2..4,
        defense_bonus_range: 1..3,
        dice_count: 2..3,
        dice_sides: 8
      },
      minion: {
        hp_range: 5..12,
        damage_bonus_range: 0..2,
        defense_bonus_range: 0..2,
        dice_count: 1..2,
        dice_sides: 8
      }
    }.freeze

    # Difficulty multipliers
    DIFFICULTY_MULTIPLIERS = {
      easy: 0.8,
      normal: 1.0,
      hard: 1.2,
      deadly: 1.4
    }.freeze

    # Behavior to AI profile mapping
    BEHAVIOR_TO_AI_PROFILE = {
      'aggressive' => 'aggressive',
      'berserker' => 'berserker',
      'reckless' => 'berserker',
      'defensive' => 'defensive',
      'cautious' => 'defensive',
      'guardian' => 'guardian',
      'protective' => 'guardian',
      'cunning' => 'balanced',
      'tactical' => 'balanced',
      'coward' => 'coward',
      'fearful' => 'coward'
    }.freeze

    class << self
      # Generate adversaries from mission plan
      # @param adversaries [Array<Hash>] Adversary definitions from synthesis plan
      # @param setting [Symbol] World setting
      # @param difficulty [Symbol] Difficulty tier
      # @param activity_id [Integer, nil] Activity ID for tracking
      # @param options [Hash] Additional options
      # @return [Hash] { success:, archetypes: { key => NpcArchetype }, errors: }
      def generate(adversaries:, setting:, difficulty:, activity_id: nil, options: {})
        return { success: true, archetypes: {}, errors: [] } if adversaries.nil? || adversaries.empty?

        archetypes = {}
        errors = []

        # Deduplicate by name — each unique adversary should only be created once
        seen_names = {}
        adversaries.each do |adv|
          name = adv['name']
          key = adv['combat_encounter_key'] || name

          if seen_names[name]
            # Already created this adversary — just register it under the additional key
            archetypes[key] ||= []
            archetypes[key] << seen_names[name]
            next
          end

          result = generate_adversary(
            adversary: adv,
            setting: setting,
            difficulty: difficulty,
            activity_id: activity_id,
            options: options
          )

          if result[:success]
            seen_names[name] = result[:archetype]
            archetypes[key] ||= []
            archetypes[key] << result[:archetype]
          else
            errors << "Failed to generate #{name}: #{result[:error]}"
          end
        end

        {
          success: archetypes.any? || adversaries.empty?,
          archetypes: archetypes,
          errors: errors
        }
      end

      # Generate a single adversary archetype
      # @param adversary [Hash] Adversary definition
      # @param setting [Symbol] World setting
      # @param difficulty [Symbol] Difficulty tier
      # @param activity_id [Integer, nil] Activity ID
      # @param options [Hash]
      # @return [Hash] { success:, archetype:, error: }
      def generate_adversary(adversary:, setting:, difficulty:, activity_id: nil, options: {})
        name = adversary['name']
        description = adversary['description'] || name
        role = (adversary['role'] || 'minion').to_sym
        behavior = adversary['behavior'] || 'aggressive'

        # Generate stats (LLM or fallback)
        stats = if options[:use_llm_stats] != false
                  llm_stats = generate_stats_with_llm(
                    name: name,
                    description: description,
                    role: role,
                    behavior: behavior,
                    difficulty: difficulty,
                    setting: setting
                  )
                  llm_stats[:success] ? llm_stats[:stats] : generate_fallback_stats(role, difficulty, behavior)
                else
                  generate_fallback_stats(role, difficulty, behavior)
                end

        # Create the archetype
        archetype = NpcArchetype.create(
          name: name,
          description: description,
          behavior_pattern: map_behavior_to_pattern(behavior),
          combat_ai_profile: stats['ai_profile'] || map_behavior_to_ai_profile(behavior),
          combat_max_hp: stats['max_hp'],
          damage_dice_count: stats['damage_dice_count'],
          damage_dice_sides: stats['damage_dice_sides'],
          combat_damage_bonus: stats['damage_bonus'],
          combat_defense_bonus: stats['defense_bonus'],
          combat_speed_modifier: stats['speed_modifier'] || 0,
          combat_ability_chance: stats['ability_chance'] || 0,
          flee_health_percent: stats['flee_threshold'] || 0,
          is_humanoid: !description.to_s.downcase.match?(/beast|creature|monster|animal|dragon|demon/),
          is_generated: true,
          generated_for_activity_id: activity_id
        )

        # Check if this adversary should become a large multi-segment monster
        if MonsterGeneratorService.should_be_monster?(adversary: adversary, role: role)
          monster_result = MonsterGeneratorService.generate_monster(
            archetype: archetype,
            adversary: adversary,
            setting: setting
          )
          if monster_result[:success]
            archetype.update(
              is_monster: true,
              monster_template_id: monster_result[:monster_template].id
            )
          end
        end

        # Assign combat abilities (hybrid: select existing or generate new)
        ability_result = AbilityGeneratorService.assign_abilities(
          archetype: archetype,
          role: role,
          description: description,
          difficulty: difficulty,
          options: { setting: setting }
        )
        if ability_result[:success] && ability_result[:ability_ids].any?
          archetype.update(combat_ability_ids: Sequel.pg_array(ability_result[:ability_ids]))
        end

        { success: true, archetype: archetype }
      rescue StandardError => e
        { success: false, archetype: nil, error: e.message }
      end

      # Generate stats using LLM
      # @return [Hash] { success:, stats:, error: }
      def generate_stats_with_llm(name:, description:, role:, behavior:, difficulty:, setting:)
        prompt = GamePrompts.get(
          'generators.adversary_stats',
          setting: setting.to_s.split('_').map(&:capitalize).join(' '),
          name: name,
          description: description,
          role: role.to_s,
          behavior: behavior,
          difficulty: difficulty.to_s
        )

        result = LLM::Client.generate(
          prompt: prompt,
          provider: STATS_MODEL[:provider],
          model: STATS_MODEL[:model],
          options: { max_tokens: 500, temperature: 0.5 },
          json_mode: true
        )

        return { success: false, error: result[:error] } unless result[:success]

        begin
          json_match = result[:text].match(/\{[\s\S]*\}/)
          stats = JSON.parse(json_match[0]) if json_match

          if stats && valid_stats?(stats)
            { success: true, stats: stats }
          else
            { success: false, error: 'Invalid stats structure' }
          end
        rescue JSON::ParserError => e
          { success: false, error: "JSON parse error: #{e.message}" }
        end
      end

      # Generate fallback stats without LLM
      # @return [Hash] stat values
      def generate_fallback_stats(role, difficulty, behavior)
        role_config = ROLE_STATS[role] || ROLE_STATS[:minion]
        multiplier = DIFFICULTY_MULTIPLIERS[difficulty.to_sym] || 1.0

        {
          'max_hp' => scale_stat(rand(role_config[:hp_range]), multiplier),
          'damage_dice_count' => rand(role_config[:dice_count]),
          'damage_dice_sides' => role_config[:dice_sides],
          'damage_bonus' => scale_stat(rand(role_config[:damage_bonus_range]), multiplier),
          'defense_bonus' => scale_stat(rand(role_config[:defense_bonus_range]), multiplier),
          'speed_modifier' => 0,
          'ability_chance' => role == :boss ? 30 : (role == :lieutenant ? 15 : 0),
          'flee_threshold' => role == :minion ? 20 : 0,
          'ai_profile' => map_behavior_to_ai_profile(behavior)
        }
      end

      # Generate appearance description for adversary
      # @param adversary [Hash] Adversary definition
      # @param setting [Symbol]
      # @return [Hash] { success:, description: }
      def generate_appearance(adversary:, setting:)
        seed_terms = SeedTermService.for_generation(:creature, count: 5)

        Generators::NPCGeneratorService.generate_appearance(
          name: adversary['name'],
          gender: 'creature',
          role: adversary['role'] || 'enemy',
          setting: setting,
          seed_terms: seed_terms
        )
      end

      private

      # Scale a stat by difficulty multiplier
      def scale_stat(value, multiplier)
        (value * multiplier).round
      end

      # Validate stats structure
      def valid_stats?(stats)
        required = %w[max_hp damage_dice_count damage_dice_sides damage_bonus defense_bonus]
        required.all? { |key| stats[key].is_a?(Integer) || stats[key].is_a?(Float) }
      end

      # Map behavior string to behavior_pattern enum
      def map_behavior_to_pattern(behavior)
        case behavior.to_s.downcase
        when /aggress|berser|rage|hostile/ then 'hostile'
        when /defen|protect|guard/ then 'guard'
        when /caut|calc|patient|neutral/ then 'neutral'
        when /coward|flee|retreat|passive/ then 'passive'
        when /friend|ally|help/ then 'friendly'
        else 'hostile'
        end
      end

      # Map behavior string to AI profile
      def map_behavior_to_ai_profile(behavior)
        behavior_key = behavior.to_s.downcase
        BEHAVIOR_TO_AI_PROFILE.each do |pattern, profile|
          return profile if behavior_key.include?(pattern)
        end
        'balanced'
      end
    end
  end
end
