# frozen_string_literal: true

module Generators
  # AbilityGeneratorService handles hybrid ability assignment for LLM-created NPCs.
  #
  # Uses a hybrid approach:
  # 1. Search existing abilities matching NPC role/description
  # 2. Score matches by relevance (keyword, damage type, power level)
  # 3. If good matches (score > 50), select from them
  # 4. If no matches, generate NEW ability via LLM
  #
  # @example Assign abilities to an archetype
  #   result = Generators::AbilityGeneratorService.assign_abilities(
  #     archetype: archetype,
  #     role: :boss,
  #     description: 'Ancient fire dragon',
  #     difficulty: :hard
  #   )
  #
  class AbilityGeneratorService
    # Model for ability generation
    ABILITY_MODEL = { provider: 'google_gemini', model: 'gemini-3-flash-preview' }.freeze

    # Number of abilities by role
    ROLE_ABILITY_COUNTS = {
      boss: 2..3,
      lieutenant: 1..2,
      minion: 0..1
    }.freeze

    # Target power levels by role
    TARGET_POWER = {
      boss: 150,
      lieutenant: 100,
      minion: 60
    }.freeze

    # Minimum match score to use existing ability
    MATCH_THRESHOLD = 50

    # Keywords for matching abilities to descriptions
    ELEMENT_KEYWORDS = {
      'fire' => %w[fire flame burn ember blazing infernal volcanic ash dragon phoenix],
      'ice' => %w[ice frost cold freeze frozen chill winter arctic glacial blizzard],
      'lightning' => %w[lightning thunder storm electric shock spark tempest],
      'poison' => %w[poison venom toxic snake spider scorpion plague disease decay],
      'shadow' => %w[shadow dark darkness void night death undead spectral ghost],
      'holy' => %w[holy light radiant divine angel celestial sacred sun dawn],
      'arcane' => %w[arcane magic spell wizard mage sorcerer mystic eldritch]
    }.freeze


    class << self
      # Assign abilities to an archetype using hybrid approach
      # @param archetype [NpcArchetype] The archetype to assign abilities to
      # @param role [Symbol] :boss, :lieutenant, :minion
      # @param description [String] NPC description for matching
      # @param difficulty [Symbol] :easy, :normal, :hard, :deadly
      # @param options [Hash] Additional options
      # @return [Hash] { success:, ability_ids:, generated_count:, selected_count:, errors: }
      def assign_abilities(archetype:, role:, description:, difficulty:, options: {})
        role = role.to_sym
        role_range = ROLE_ABILITY_COUNTS[role] || ROLE_ABILITY_COUNTS[:minion]
        count = rand(role_range)

        return { success: true, ability_ids: [], generated_count: 0, selected_count: 0, errors: [] } if count == 0

        target_power = TARGET_POWER[role] || 80
        universe_id = options[:universe_id]
        ability_ids = []
        generated_count = 0
        selected_count = 0
        errors = []

        # Search existing abilities
        matches = search_existing_abilities(description: description, role: role, target_power: target_power)

        count.times do |i|
          if matches[i] && matches[i][:score] >= MATCH_THRESHOLD
            # Use existing ability
            ability_ids << matches[i][:ability].id
            selected_count += 1
          else
            # Generate new ability
            result = generate_new_ability(
              name: archetype.name,
              description: description,
              role: role,
              target_power: target_power,
              setting: options[:setting] || :fantasy,
              universe_id: universe_id
            )

            if result[:success]
              ability_ids << result[:ability].id
              generated_count += 1
            else
              errors << result[:error]
            end
          end
        end

        {
          success: ability_ids.any?,
          ability_ids: ability_ids,
          generated_count: generated_count,
          selected_count: selected_count,
          errors: errors
        }
      end

      # Search existing abilities matching criteria
      # @param description [String] NPC description
      # @param role [Symbol] NPC role
      # @param target_power [Integer] Target power level
      # @return [Array<Hash>] { ability:, score: } sorted by score desc
      def search_existing_abilities(description:, role:, target_power:)
        abilities = Ability.where(user_type: 'npc').all
        return [] if abilities.empty?

        # Extract keywords from description
        desc_lower = description.to_s.downcase
        detected_elements = detect_elements(desc_lower)

        scored = abilities.map do |ability|
          score = calculate_match_score(
            ability: ability,
            description: desc_lower,
            detected_elements: detected_elements,
            target_power: target_power,
            role: role
          )
          { ability: ability, score: score }
        end

        # Sort by score desc, filter minimum threshold
        scored.sort_by { |s| -s[:score] }
              .select { |s| s[:score] > 0 }
      end

      # Generate a new ability using LLM
      # @param name [String] NPC name
      # @param description [String] NPC description
      # @param role [Symbol] :boss, :lieutenant, :minion
      # @param target_power [Integer] Target power level
      # @param setting [Symbol] World setting
      # @return [Hash] { success:, ability:, error: }
      def generate_new_ability(name:, description:, role:, target_power:, setting: :fantasy, universe_id: nil)
        prompt = GamePrompts.get('ability_generation.new_ability',
                                 setting: setting.to_s.split('_').map(&:capitalize).join(' '),
                                 name: name,
                                 description: description,
                                 role: role.to_s,
                                 target_power: target_power)

        result = LLM::Client.generate(
          prompt: prompt,
          provider: ABILITY_MODEL[:provider],
          model: ABILITY_MODEL[:model],
          options: { max_tokens: 600, temperature: 0.7 },
          json_mode: true
        )

        unless result[:success]
          return create_fallback_ability(name, description, role, target_power, universe_id: universe_id)
        end

        begin
          json_match = result[:text].match(/\{[\s\S]*\}/)
          ability_data = JSON.parse(json_match[0]) if json_match

          unless ability_data && valid_ability_data?(ability_data)
            return create_fallback_ability(name, description, role, target_power, universe_id: universe_id)
          end

          ability = create_ability_from_data(ability_data, universe_id: universe_id)
          balanced_ability = balance_ability(ability, target_power)

          { success: true, ability: balanced_ability }
        rescue JSON::ParserError, StandardError => e
          warn "[AbilityGeneratorService] Error parsing LLM response: #{e.message}"
          create_fallback_ability(name, description, role, target_power, universe_id: universe_id)
        end
      end

      # Validate and adjust ability to target power
      # @param ability [Ability] The ability to balance
      # @param target_power [Integer] Target power level
      # @return [Ability] The balanced ability
      def balance_ability(ability, target_power)
        current_power = begin
                          ability.power
                        rescue StandardError => e
                          warn "[AbilityGeneratorService] Power calculation failed: #{e.message}"
                          0
                        end
        return ability if current_power == 0

        # If within 25% of target, accept as-is
        tolerance = [target_power.to_f * 0.25, 1.0].max
        delta = current_power - target_power
        return ability if delta.abs <= tolerance

        # Scale adjustment by distance from target so large misses converge faster.
        # Uses tolerance-sized bands (outside ±25%) to avoid dead zones.
        steps = [(delta.abs / tolerance).ceil, 1].max
        adjustment = 3 * steps
        current_modifier = ability.damage_modifier.to_i

        new_modifier = if delta.positive?
                         [current_modifier - adjustment, 0].max
                       else
                         current_modifier + adjustment
                       end

        ability.update(damage_modifier: new_modifier) if new_modifier != current_modifier

        ability
      end

      private

      # Detect elemental themes in description
      # @param desc_lower [String] Lowercase description
      # @return [Array<String>] Detected element types
      def detect_elements(desc_lower)
        detected = []
        ELEMENT_KEYWORDS.each do |element, keywords|
          detected << element if keywords.any? { |kw| desc_lower.include?(kw) }
        end
        detected
      end

      # Calculate match score between ability and NPC
      # @return [Integer] Match score 0-100
      def calculate_match_score(ability:, description:, detected_elements:, target_power:, role:)
        score = 0

        # Element match (30 points)
        if detected_elements.any?
          ability_element = ability.damage_type.to_s.downcase
          score += 30 if detected_elements.include?(ability_element)
        end

        # Power fit (25 points) - how close to target power
        ability_power = begin
                          ability.power
                        rescue StandardError => e
                          warn "[AbilityGeneratorService] Power calculation failed for '#{ability.name}': #{e.message}"
                          0
                        end
        if ability_power > 0
          power_diff = (ability_power - target_power).abs
          power_score = [25 - (power_diff / 10).to_i, 0].max
          score += power_score
        end

        # Name/description keyword match (20 points)
        ability_name = ability.name.to_s.downcase
        ability_desc = ability.description.to_s.downcase
        if description.split(/\W+/).any? { |word| ability_name.include?(word) || ability_desc.include?(word) }
          score += 20
        end

        # AoE fit for role (15 points)
        aoe = ability.aoe_shape.to_s
        case role
        when :boss
          score += 15 if %w[circle cone line].include?(aoe)
        when :lieutenant
          score += 15 if %w[single cone].include?(aoe)
        when :minion
          score += 15 if aoe == 'single'
        end

        # Has status effect (10 points for bosses)
        if role == :boss && ability.respond_to?(:applied_status_effects)
          effects = ability.applied_status_effects
          score += 10 if effects.is_a?(Array) && effects.any?
        end

        score
      end

      # Validate ability data from LLM
      def valid_ability_data?(data)
        data['name'].is_a?(String) && !data['name'].empty?
      end

      # Create ability record from LLM data
      def create_ability_from_data(data, universe_id: nil)
        Ability.create(
          universe_id: universe_id,
          name: data['name'],
          description: data['description'],
          ability_type: data['ability_type'] || 'combat',
          action_type: data['action_type'] || 'main',
          user_type: 'npc',
          target_type: data['target_type'] || 'enemy',
          aoe_shape: data['aoe_shape'] || 'single',
          aoe_radius: data['aoe_radius'].to_i,
          aoe_length: data['aoe_length'].to_i,
          base_damage_dice: data['base_damage_dice'],
          damage_type: data['damage_type'] || 'physical',
          damage_modifier: data['damage_modifier'].to_i,
          activation_segment: data['activation_segment'].to_i.nonzero? || 50,
          cooldown_seconds: data['cooldown_seconds'].to_i
        )
      end

      # Create fallback ability when LLM fails
      def create_fallback_ability(name, description, role, target_power, universe_id: nil)
        desc_lower = description.to_s.downcase
        elements = detect_elements(desc_lower)
        damage_type = elements.first || 'physical'

        # Simple damage based on role
        dice = case role
               when :boss then '4d8'
               when :lieutenant then '3d6'
               else '2d6'
               end

        ability = Ability.create(
          universe_id: universe_id,
          name: "#{name}'s Strike",
          description: "A powerful attack",
          ability_type: 'combat',
          action_type: 'main',
          user_type: 'npc',
          target_type: 'enemy',
          aoe_shape: role == :boss ? 'cone' : 'single',
          aoe_length: role == :boss ? 3 : 0,
          base_damage_dice: dice,
          damage_type: damage_type,
          activation_segment: 50
        )

        { success: true, ability: ability }
      rescue StandardError => e
        { success: false, ability: nil, error: e.message }
      end
    end
  end
end
