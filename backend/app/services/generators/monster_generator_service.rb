# frozen_string_literal: true

module Generators
  # MonsterGeneratorService determines when an NPC should be a large multi-segment monster
  # and generates appropriate MonsterTemplate + MonsterSegmentTemplate records.
  #
  # Only boss-role adversaries with monster keywords (dragon, behemoth, etc.) become monsters.
  #
  # @example Check and generate monster
  #   if Generators::MonsterGeneratorService.should_be_monster?(adversary: adv, role: :boss)
  #     result = Generators::MonsterGeneratorService.generate_monster(
  #       archetype: archetype,
  #       adversary: adv,
  #       setting: :fantasy
  #     )
  #   end
  #
  class MonsterGeneratorService
    # Model for monster template generation
    MONSTER_MODEL = { provider: 'google_gemini', model: 'gemini-3-flash-preview' }.freeze

    # Keywords that indicate a monster (multi-segment creature)
    MONSTER_KEYWORDS = %w[
      dragon wyrm serpent behemoth colossus titan giant hydra
      leviathan kraken golem construct massive enormous huge
      ancient elder great colossal towering worm beast demon
      elemental avatar aboleth beholder tarrasque kaiju
    ].freeze

    # Roles that can become monsters
    MONSTER_ROLES = %i[boss].freeze

    # Default segment configurations by monster type
    DEFAULT_SEGMENTS = {
      dragon: [
        { name: 'Head', segment_type: 'head', hp_percent: 20, attacks_per_round: 2, is_weak_point: true, attack_speed: 30, reach: 3, damage_dice: '3d8+4' },
        { name: 'Left Claw', segment_type: 'limb', hp_percent: 15, attacks_per_round: 1, required_for_mobility: true, attack_speed: 50, reach: 2, damage_dice: '2d8+2' },
        { name: 'Right Claw', segment_type: 'limb', hp_percent: 15, attacks_per_round: 1, required_for_mobility: true, attack_speed: 60, reach: 2, damage_dice: '2d8+2' },
        { name: 'Body', segment_type: 'body', hp_percent: 30, attacks_per_round: 0, attack_speed: 0, reach: 0, damage_dice: nil },
        { name: 'Tail', segment_type: 'tail', hp_percent: 10, attacks_per_round: 1, attack_speed: 70, reach: 4, damage_dice: '2d6+3' },
        { name: 'Wings', segment_type: 'wing', hp_percent: 10, attacks_per_round: 0, attack_speed: 0, reach: 0, damage_dice: nil }
      ],
      colossus: [
        { name: 'Core', segment_type: 'core', hp_percent: 25, attacks_per_round: 0, is_weak_point: true, attack_speed: 0, reach: 0, damage_dice: nil },
        { name: 'Left Arm', segment_type: 'limb', hp_percent: 20, attacks_per_round: 2, attack_speed: 40, reach: 3, damage_dice: '3d6+5' },
        { name: 'Right Arm', segment_type: 'limb', hp_percent: 20, attacks_per_round: 2, attack_speed: 50, reach: 3, damage_dice: '3d6+5' },
        { name: 'Torso', segment_type: 'body', hp_percent: 25, attacks_per_round: 0, attack_speed: 0, reach: 0, damage_dice: nil },
        { name: 'Legs', segment_type: 'limb', hp_percent: 10, attacks_per_round: 1, required_for_mobility: true, attack_speed: 80, reach: 2, damage_dice: '2d8+3' }
      ],
      hydra: [
        { name: 'Head 1', segment_type: 'head', hp_percent: 15, attacks_per_round: 1, is_weak_point: true, attack_speed: 25, reach: 4, damage_dice: '2d8+2' },
        { name: 'Head 2', segment_type: 'head', hp_percent: 15, attacks_per_round: 1, attack_speed: 35, reach: 4, damage_dice: '2d8+2' },
        { name: 'Head 3', segment_type: 'head', hp_percent: 15, attacks_per_round: 1, attack_speed: 45, reach: 4, damage_dice: '2d8+2' },
        { name: 'Body', segment_type: 'body', hp_percent: 35, attacks_per_round: 0, attack_speed: 0, reach: 0, damage_dice: nil },
        { name: 'Tail', segment_type: 'tail', hp_percent: 20, attacks_per_round: 1, attack_speed: 70, reach: 5, damage_dice: '2d10+4' }
      ],
      serpent: [
        { name: 'Head', segment_type: 'head', hp_percent: 25, attacks_per_round: 2, is_weak_point: true, attack_speed: 30, reach: 5, damage_dice: '3d6+3' },
        { name: 'Upper Coils', segment_type: 'body', hp_percent: 30, attacks_per_round: 1, attack_speed: 50, reach: 3, damage_dice: '2d8+4' },
        { name: 'Lower Coils', segment_type: 'body', hp_percent: 30, attacks_per_round: 1, required_for_mobility: true, attack_speed: 60, reach: 3, damage_dice: '2d8+4' },
        { name: 'Tail', segment_type: 'tail', hp_percent: 15, attacks_per_round: 1, attack_speed: 75, reach: 6, damage_dice: '2d6+2' }
      ],
      golem: [
        { name: 'Head', segment_type: 'head', hp_percent: 15, attacks_per_round: 0, is_weak_point: true, attack_speed: 0, reach: 0, damage_dice: nil },
        { name: 'Left Fist', segment_type: 'limb', hp_percent: 20, attacks_per_round: 2, attack_speed: 40, reach: 2, damage_dice: '4d6+6' },
        { name: 'Right Fist', segment_type: 'limb', hp_percent: 20, attacks_per_round: 2, attack_speed: 55, reach: 2, damage_dice: '4d6+6' },
        { name: 'Core', segment_type: 'core', hp_percent: 30, attacks_per_round: 0, attack_speed: 0, reach: 0, damage_dice: nil },
        { name: 'Legs', segment_type: 'limb', hp_percent: 15, attacks_per_round: 1, required_for_mobility: true, attack_speed: 80, reach: 2, damage_dice: '3d6+4' }
      ],
      beast: [
        { name: 'Head', segment_type: 'head', hp_percent: 25, attacks_per_round: 2, is_weak_point: true, attack_speed: 30, reach: 2, damage_dice: '3d8+3' },
        { name: 'Forelimbs', segment_type: 'limb', hp_percent: 20, attacks_per_round: 2, required_for_mobility: true, attack_speed: 45, reach: 2, damage_dice: '2d8+4' },
        { name: 'Body', segment_type: 'body', hp_percent: 35, attacks_per_round: 0, attack_speed: 0, reach: 0, damage_dice: nil },
        { name: 'Hindlimbs', segment_type: 'limb', hp_percent: 20, attacks_per_round: 1, required_for_mobility: true, attack_speed: 70, reach: 2, damage_dice: '2d6+3' }
      ]
    }.freeze

    # Monster type mappings
    MONSTER_TYPE_KEYWORDS = {
      dragon: %w[dragon wyrm drake wyvern],
      colossus: %w[colossus titan giant elemental golem construct avatar],
      hydra: %w[hydra multi-headed cerberus chimera],
      serpent: %w[serpent leviathan kraken worm tentacle aboleth],
      golem: %w[golem construct automaton statue animated],
      beast: %w[beast behemoth demon tarrasque kaiju creature massive enormous]
    }.freeze

    class << self
      # Check if adversary should become a monster
      # @param adversary [Hash] Adversary definition
      # @param role [Symbol] :boss, :lieutenant, :minion
      # @return [Boolean]
      def should_be_monster?(adversary:, role:)
        # Rule 1: Only boss role can be monsters
        return false unless MONSTER_ROLES.include?(role.to_sym)

        # Rule 2: Check for explicit flag
        return true if adversary['is_monster'] == true

        # Rule 3: Check description/name for monster keywords
        combined = "#{adversary['name']} #{adversary['description']}".downcase
        keyword_count = MONSTER_KEYWORDS.count { |kw| combined.include?(kw) }

        # Need at least 1 keyword match to be a monster
        keyword_count >= 1
      end

      # Generate monster template and segments
      # @param archetype [NpcArchetype] The linked archetype
      # @param adversary [Hash] Adversary definition
      # @param setting [Symbol] World setting
      # @return [Hash] { success:, monster_template:, segments:, error: }
      def generate_monster(archetype:, adversary:, setting:)
        name = adversary['name']
        description = adversary['description'] || name

        # Detect monster type from description
        monster_type = detect_monster_type(description)

        # Get segment config (default or generate)
        segment_config = DEFAULT_SEGMENTS[monster_type] || DEFAULT_SEGMENTS[:beast]

        # Calculate total HP (base 100, scaled by archetype HP)
        base_hp = archetype.combat_max_hp || 30
        total_hp = [base_hp * 3, 80].max # Monsters have 3x archetype HP, min 80

        # Create monster template
        monster_template = MonsterTemplate.create(
          name: name,
          monster_type: monster_type.to_s,
          total_hp: total_hp,
          hex_width: 3,
          hex_height: 3,
          climb_distance: 2,
          defeat_threshold_percent: 70,
          behavior_config: {
            shake_off_threshold: 3,
            segment_attack_count: [2, 3]
          },
          npc_archetype_id: archetype.id
        )

        # Create segment templates
        segments = create_segment_templates(monster_template, segment_config, total_hp)

        {
          success: true,
          monster_template: monster_template,
          segments: segments
        }
      rescue StandardError => e
        warn "[MonsterGeneratorService] Error creating monster: #{e.message}"
        { success: false, monster_template: nil, segments: [], error: e.message }
      end

      private

      # Detect monster type from description
      # @param description [String]
      # @return [Symbol] Monster type key
      def detect_monster_type(description)
        desc_lower = description.to_s.downcase

        MONSTER_TYPE_KEYWORDS.each do |type, keywords|
          return type if keywords.any? { |kw| desc_lower.include?(kw) }
        end

        # Default to beast
        :beast
      end

      # Create segment templates for monster
      # @param monster_template [MonsterTemplate]
      # @param segment_config [Array<Hash>]
      # @param total_hp [Integer]
      # @return [Array<MonsterSegmentTemplate>]
      def create_segment_templates(monster_template, segment_config, total_hp)
        segments = []
        position_offset = 0

        segment_config.each_with_index do |config, index|
          segment_hp = (total_hp * config[:hp_percent] / 100.0).round

          segment = MonsterSegmentTemplate.create(
            monster_template_id: monster_template.id,
            name: config[:name],
            segment_type: config[:segment_type],
            hp_allocation_percent: config[:hp_percent],
            attacks_per_round: config[:attacks_per_round] || 0,
            attack_speed: config[:attack_speed] || 50,
            damage_dice: config[:damage_dice],
            reach: config[:reach] || 2,
            is_weak_point: config[:is_weak_point] || false,
            required_for_mobility: config[:required_for_mobility] || false,
            relative_hex_x: position_offset % 3,
            relative_hex_y: position_offset / 3,
            attack_effects: config[:attack_effects] || {}
          )

          segments << segment
          position_offset += 1
        end

        segments
      end
    end
  end
end
