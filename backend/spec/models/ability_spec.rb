# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Ability do
  # Shared universe for all tests
  let(:universe) { create(:universe) }

  # Helper to build ability with universe
  def build_ability(**attrs)
    build(:ability, universe: universe, **attrs)
  end

  # ========================================
  # Validations
  # ========================================

  describe 'validations' do

    it 'requires name' do
      ability = build_ability( name: nil)
      expect(ability.valid?).to be false
      expect(ability.errors[:name]).to include('is not present')
    end

    it 'requires ability_type' do
      ability = build_ability( ability_type: nil)
      expect(ability.valid?).to be false
      expect(ability.errors[:ability_type]).to include('is not present')
    end

    it 'requires name to be at most 100 characters' do
      ability = build_ability( name: 'A' * 101)
      expect(ability.valid?).to be false
      expect(ability.errors[:name]).to include('is longer than 100 characters')
    end

    it 'requires unique name within universe' do
      create(:ability, universe: universe, name: 'Fireball')
      duplicate = build_ability( name: 'Fireball')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[[:universe_id, :name]]).to include('is already taken')
    end

    it 'allows same name in different universes' do
      universe2 = create(:universe)
      create(:ability, universe: universe, name: 'Fireball')
      ability2 = build_ability( universe: universe2, name: 'Fireball')
      expect(ability2.valid?).to be true
    end

    it 'validates ability_type is in ABILITY_TYPES' do
      ability = build_ability( ability_type: 'invalid')
      expect(ability.valid?).to be false
      expect(ability.errors[:ability_type]).to include('is not in range or set: ["combat", "utility", "passive", "social", "crafting"]')
    end

    it 'validates action_type is in ACTION_TYPES when set' do
      ability = build_ability( action_type: 'invalid')
      expect(ability.valid?).to be false
      expect(ability.errors[:action_type]).to include('is not in range or set: ["main", "tactical", "free", "passive", "reaction"]')
    end

    it 'validates target_type is in TARGET_TYPES when set' do
      ability = build_ability( target_type: 'invalid')
      expect(ability.valid?).to be false
      expect(ability.errors[:target_type]).to include('is not in range or set: ["self", "ally", "enemy"]')
    end

    it 'validates aoe_shape is in AOE_SHAPES when set' do
      ability = build_ability( aoe_shape: 'invalid')
      expect(ability.valid?).to be false
      expect(ability.errors[:aoe_shape]).to include('is not in range or set: ["single", "circle", "cone", "line"]')
    end

    it 'validates user_type is in USER_TYPES when set' do
      ability = build_ability( user_type: 'invalid')
      expect(ability.valid?).to be false
      expect(ability.errors[:user_type]).to include('is not in range or set: ["pc", "npc"]')
    end

    it 'allows valid activation_segment values' do
      ability = build_ability(activation_segment: 50)
      expect(ability.valid?).to be true
    end

    it 'rejects activation_segment values above 100' do
      ability = build_ability(activation_segment: 101)
      expect(ability.valid?).to be false
      expect(ability.errors[:activation_segment]).to include('must be between 0 and 100')
    end

    it 'allows valid aoe_radius values' do
      ability = build_ability(aoe_radius: 3)
      expect(ability.valid?).to be true
    end

    it 'allows valid aoe_length values' do
      ability = build_ability(aoe_length: 5)
      expect(ability.valid?).to be true
    end

    it 'allows valid aoe_angle values' do
      ability = build_ability(aoe_angle: 90)
      expect(ability.valid?).to be true
    end

    it 'rejects aoe_angle values above 360' do
      ability = build_ability(aoe_angle: 361)
      expect(ability.valid?).to be false
      expect(ability.errors[:aoe_angle]).to include('must be between 0 and 360')
    end

    it 'accepts all valid ability types' do
      Ability::ABILITY_TYPES.each do |type|
        ability = build_ability( ability_type: type)
        expect(ability.valid?).to eq(true), "Expected ability_type '#{type}' to be valid"
      end
    end

    it 'accepts all valid action types' do
      Ability::ACTION_TYPES.each do |type|
        ability = build_ability( action_type: type)
        expect(ability.valid?).to eq(true), "Expected action_type '#{type}' to be valid"
      end
    end

    it 'accepts all valid target types' do
      Ability::TARGET_TYPES.each do |type|
        ability = build_ability( target_type: type)
        expect(ability.valid?).to eq(true), "Expected target_type '#{type}' to be valid"
      end
    end

    it 'accepts all valid AoE shapes' do
      Ability::AOE_SHAPES.each do |shape|
        ability = build_ability( aoe_shape: shape)
        expect(ability.valid?).to eq(true), "Expected aoe_shape '#{shape}' to be valid"
      end
    end

    it 'accepts all valid user types' do
      Ability::USER_TYPES.each do |type|
        ability = build_ability( user_type: type)
        expect(ability.valid?).to eq(true), "Expected user_type '#{type}' to be valid"
      end
    end

    it 'validates base_damage_dice notation' do
      ability = build_ability(base_damage_dice: '1d0')
      expect(ability.valid?).to be false
      expect(ability.errors[:base_damage_dice]).to include(a_string_matching(/valid dice notation/i))
    end

    it 'allows valid base_damage_dice notation' do
      ability = build_ability(base_damage_dice: '2d6+3')
      expect(ability.valid?).to be true
    end

    it 'validates signed damage_modifier_dice notation' do
      ability = build_ability(damage_modifier_dice: '+1d0')
      expect(ability.valid?).to be false
      expect(ability.errors[:damage_modifier_dice]).to include(a_string_matching(/valid dice notation/i))
    end
  end

  # ========================================
  # Before Save Hooks
  # ========================================

  describe 'before_save hooks' do
    it 'sets default action_type to main' do
      ability = create(:ability, action_type: nil)
      expect(ability.action_type).to eq('main')
    end

    it 'sets default target_type to enemy' do
      ability = create(:ability, target_type: nil)
      expect(ability.target_type).to eq('enemy')
    end

    it 'sets default aoe_shape to single' do
      ability = create(:ability, aoe_shape: nil)
      expect(ability.aoe_shape).to eq('single')
    end

    it 'sets default user_type to npc' do
      ability = create(:ability, user_type: nil)
      expect(ability.user_type).to eq('npc')
    end

    it 'sets default activation_segment from GameConfig' do
      ability = build_ability
      ability.activation_segment = nil
      ability.save
      expect(ability.activation_segment).to eq(GameConfig::AbilityDefaults::ACTIVATION_SEGMENT)
    end

    it 'sets default cooldown_seconds from GameConfig' do
      ability = build_ability
      ability.cooldown_seconds = nil
      ability.save
      expect(ability.cooldown_seconds).to eq(GameConfig::AbilityDefaults::COOLDOWN_SECONDS)
    end
  end

  # ========================================
  # Type Check Methods
  # ========================================

  describe 'type check methods' do
    describe '#combat?' do
      it 'returns true for combat abilities' do
        ability = build_ability( ability_type: 'combat')
        expect(ability.combat?).to be true
      end

      it 'returns false for non-combat abilities' do
        ability = build_ability( ability_type: 'utility')
        expect(ability.combat?).to be false
      end
    end

    describe '#passive?' do
      it 'returns true for passive action type' do
        ability = build_ability( action_type: 'passive')
        expect(ability.passive?).to be true
      end

      it 'returns false for non-passive action type' do
        ability = build_ability( action_type: 'main')
        expect(ability.passive?).to be false
      end
    end

    describe '#main_action?' do
      it 'returns true for main action type' do
        ability = build_ability( action_type: 'main')
        expect(ability.main_action?).to be true
      end

      it 'returns false for non-main action type' do
        ability = build_ability( action_type: 'tactical')
        expect(ability.main_action?).to be false
      end
    end

    describe '#tactical_action?' do
      it 'returns true for tactical action type' do
        ability = build_ability( action_type: 'tactical')
        expect(ability.tactical_action?).to be true
      end

      it 'returns false for non-tactical action type' do
        ability = build_ability( action_type: 'main')
        expect(ability.tactical_action?).to be false
      end
    end

    describe '#pc_ability?' do
      it 'returns true for PC user type' do
        ability = build_ability( user_type: 'pc')
        expect(ability.pc_ability?).to be true
      end

      it 'returns false for NPC user type' do
        ability = build_ability( user_type: 'npc')
        expect(ability.pc_ability?).to be false
      end
    end

    describe '#npc_ability?' do
      it 'returns true for NPC user type' do
        ability = build_ability( user_type: 'npc')
        expect(ability.npc_ability?).to be true
      end

      it 'returns false for PC user type' do
        ability = build_ability( user_type: 'pc')
        expect(ability.npc_ability?).to be false
      end
    end

    describe '#has_cooldown?' do
      it 'returns true when cooldown_seconds is positive' do
        ability = build_ability( cooldown_seconds: 10)
        expect(ability.has_cooldown?).to be true
      end

      it 'returns false when cooldown_seconds is zero' do
        ability = build_ability( cooldown_seconds: 0)
        expect(ability.has_cooldown?).to be false
      end

      it 'returns false when cooldown_seconds is nil' do
        ability = build_ability
        ability.cooldown_seconds = nil
        expect(ability.has_cooldown?).to be false
      end
    end

  end

  # ========================================
  # AoE Helpers
  # ========================================

  describe 'AoE helpers' do
    describe '#single_target?' do
      it 'returns true for single aoe_shape' do
        ability = build_ability( aoe_shape: 'single')
        expect(ability.single_target?).to be true
      end

      it 'returns true for nil aoe_shape' do
        ability = build_ability
        ability.aoe_shape = nil
        expect(ability.single_target?).to be true
      end

      it 'returns false for circle aoe_shape' do
        ability = build_ability( aoe_shape: 'circle')
        expect(ability.single_target?).to be false
      end
    end

    describe '#has_aoe?' do
      it 'returns false for single target abilities' do
        ability = build_ability( aoe_shape: 'single')
        expect(ability.has_aoe?).to be false
      end

      it 'returns true for circle abilities' do
        ability = build_ability( aoe_shape: 'circle')
        expect(ability.has_aoe?).to be true
      end

      it 'returns true for cone abilities' do
        ability = build_ability( aoe_shape: 'cone')
        expect(ability.has_aoe?).to be true
      end

      it 'returns true for line abilities' do
        ability = build_ability( aoe_shape: 'line')
        expect(ability.has_aoe?).to be true
      end
    end

    describe '#self_targeted?' do
      it 'returns true for self target_type' do
        ability = build_ability( target_type: 'self')
        expect(ability.self_targeted?).to be true
      end

      it 'returns false for enemy target_type' do
        ability = build_ability( target_type: 'enemy')
        expect(ability.self_targeted?).to be false
      end
    end

    describe '#healing_ability?' do
      it 'returns true when is_healing is true' do
        ability = build_ability( is_healing: true)
        expect(ability.healing_ability?).to be true
      end

      it 'returns true when damage_type is healing' do
        ability = build_ability( damage_type: 'healing')
        expect(ability.healing_ability?).to be true
      end

      it 'returns false for non-healing abilities' do
        ability = build_ability( is_healing: false, damage_type: 'fire')
        expect(ability.healing_ability?).to be false
      end
    end
  end

  # ========================================
  # Range Calculation
  # ========================================

  describe '#range_in_hexes' do
    it 'returns 0 for self-targeted abilities' do
      ability = build_ability( target_type: 'self')
      expect(ability.range_in_hexes).to eq(0)
    end

    it 'returns aoe_length for line abilities' do
      ability = build_ability( aoe_shape: 'line', aoe_length: 5)
      expect(ability.range_in_hexes).to eq(5)
    end

    it 'returns aoe_length for cone abilities' do
      ability = build_ability( aoe_shape: 'cone', aoe_length: 4)
      expect(ability.range_in_hexes).to eq(4)
    end

    it 'returns aoe_radius for circle abilities' do
      ability = build_ability( aoe_shape: 'circle', aoe_radius: 3)
      expect(ability.range_in_hexes).to eq(3)
    end

    it 'returns default range for single target abilities' do
      ability = build_ability( aoe_shape: 'single')
      expect(ability.range_in_hexes).to eq(GameConfig::AbilityDefaults::DEFAULT_RANGE_HEXES)
    end
  end

  # ========================================
  # Cost Parsing
  # ========================================

  describe 'cost parsing' do
    describe '#parsed_costs' do
      it 'returns empty hash when costs is nil' do
        ability = build_ability
        ability.costs = nil
        expect(ability.parsed_costs).to eq({})
      end

      it 'parses JSONB costs correctly' do
        ability = build_ability( costs: { 'willpower_cost' => 2, 'health_cost' => 5 })
        expect(ability.parsed_costs).to include('willpower_cost' => 2)
        expect(ability.parsed_costs).to include('health_cost' => 5)
      end
    end

    describe '#ability_penalty_config' do
      it 'returns empty hash when no ability_penalty' do
        ability = build_ability( costs: {})
        expect(ability.ability_penalty_config).to eq({})
      end

      it 'returns ability_penalty config when present' do
        ability = build_ability( costs: { 'ability_penalty' => { 'amount' => -6, 'decay_per_round' => 2 } })
        expect(ability.ability_penalty_config).to eq({ 'amount' => -6, 'decay_per_round' => 2 })
      end
    end

    describe '#all_roll_penalty_config' do
      it 'returns empty hash when no all_roll_penalty' do
        ability = build_ability( costs: {})
        expect(ability.all_roll_penalty_config).to eq({})
      end

      it 'returns all_roll_penalty config when present' do
        ability = build_ability( costs: { 'all_roll_penalty' => { 'amount' => -4 } })
        expect(ability.all_roll_penalty_config).to eq({ 'amount' => -4 })
      end
    end

    describe '#specific_cooldown_rounds' do
      it 'returns 0 when no specific_cooldown' do
        ability = build_ability( costs: {})
        expect(ability.specific_cooldown_rounds).to eq(0)
      end

      it 'returns rounds when specific_cooldown present' do
        ability = build_ability( costs: { 'specific_cooldown' => { 'rounds' => 3 } })
        expect(ability.specific_cooldown_rounds).to eq(3)
      end
    end

    describe '#global_cooldown_rounds' do
      it 'returns 0 when no global_cooldown' do
        ability = build_ability( costs: {})
        expect(ability.global_cooldown_rounds).to eq(0)
      end

      it 'returns rounds when global_cooldown present' do
        ability = build_ability( costs: { 'global_cooldown' => { 'rounds' => 1 } })
        expect(ability.global_cooldown_rounds).to eq(1)
      end
    end

    describe '#has_cost?' do
      it 'returns false when no costs defined' do
        ability = build_ability( costs: {})
        expect(ability.has_cost?).to be false
      end

      it 'returns true when ability_penalty defined' do
        ability = build_ability( costs: { 'ability_penalty' => { 'amount' => -6 } })
        expect(ability.has_cost?).to be true
      end

      it 'returns true when specific_cooldown defined' do
        ability = build_ability( costs: { 'specific_cooldown' => { 'rounds' => 2 } })
        expect(ability.has_cost?).to be true
      end
    end
  end

  # ========================================
  # Status Effect Parsing
  # ========================================

  describe 'status effect parsing' do
    describe '#parsed_status_effects' do
      it 'returns empty array when applied_status_effects is nil' do
        ability = build_ability
        ability.applied_status_effects = nil
        expect(ability.parsed_status_effects).to eq([])
      end

      it 'parses status effects array correctly' do
        effects = [{ 'name' => 'burning', 'duration' => 3 }]
        ability = build_ability( applied_status_effects: effects)
        expect(ability.parsed_status_effects).to eq(effects)
      end
    end

    describe '#applies_status_effects?' do
      it 'returns false when no status effects' do
        ability = build_ability( applied_status_effects: [])
        expect(ability.applies_status_effects?).to be false
      end

      it 'returns true when status effects present' do
        ability = build_ability( applied_status_effects: [{ 'name' => 'stun' }])
        expect(ability.applies_status_effects?).to be true
      end
    end
  end

  # ========================================
  # Damage Calculation
  # ========================================

  describe 'damage calculation' do
    describe '#roll_damage' do
      it 'returns 0 when no base_damage_dice' do
        ability = build_ability( base_damage_dice: nil)
        expect(ability.roll_damage).to eq(0)
      end

      it 'rolls damage with dice notation' do
        ability = build_ability( base_damage_dice: '2d6')
        # Roll should be between 2 and 12 for 2d6
        100.times do
          result = ability.roll_damage
          expect(result).to be >= 2
          expect(result).to be <= 12
        end
      end

      it 'adds stat_modifier to damage' do
        ability = build_ability( base_damage_dice: '1d1') # Always rolls 1
        result = ability.roll_damage(stat_modifier: 5)
        expect(result).to eq(6)
      end

      it 'adds bonus to damage' do
        ability = build_ability( base_damage_dice: '1d1')
        result = ability.roll_damage(bonus: 3)
        expect(result).to eq(4)
      end
    end

    describe '#min_damage' do
      it 'returns 0 when no base_damage_dice' do
        ability = build_ability( base_damage_dice: nil)
        expect(ability.min_damage).to eq(0)
      end

      it 'returns minimum possible roll' do
        ability = build_ability( base_damage_dice: '3d6')
        expect(ability.min_damage).to eq(3) # 3 dice, minimum 1 each
      end
    end

    describe '#max_damage' do
      it 'returns 0 when no base_damage_dice' do
        ability = build_ability( base_damage_dice: nil)
        expect(ability.max_damage).to eq(0)
      end

      it 'returns maximum possible roll' do
        ability = build_ability( base_damage_dice: '2d8')
        expect(ability.max_damage).to eq(16) # 2 dice, maximum 8 each
      end
    end

    describe '#average_damage' do
      it 'returns 0.0 when no base_damage_dice' do
        ability = build_ability( base_damage_dice: nil, action_type: 'tactical')
        expect(ability.average_damage).to eq(0.0)
      end

      it 'calculates average for NPC abilities' do
        ability = build_ability( base_damage_dice: '2d6', user_type: 'npc')
        # 2d6 average = 7
        expect(ability.average_damage).to be_within(0.1).of(7.0)
      end

      it 'uses PC_UNIFIED_ROLL_EXPECTED for PC main actions' do
        ability = build_ability( base_damage_dice: '2d6', user_type: 'pc', action_type: 'main')
        expect(ability.average_damage(for_pc: true)).to be_within(0.1).of(GameConfig::Mechanics::UNIFIED_ROLL[:expected_value])
      end

      it 'adds damage_modifier to average' do
        ability = build_ability( base_damage_dice: '1d6', damage_modifier: 5, user_type: 'npc')
        # 1d6 average = 3.5, plus 5 modifier = 8.5
        expect(ability.average_damage).to be_within(0.1).of(8.5)
      end
    end

    describe '#calculate_modifier_dice' do
      it 'returns 0 when no damage_modifier_dice' do
        ability = build_ability( damage_modifier_dice: nil)
        expect(ability.calculate_modifier_dice).to eq(0)
      end

      it 'rolls positive modifier dice' do
        ability = build_ability( damage_modifier_dice: '+1d6')
        100.times do
          result = ability.calculate_modifier_dice
          expect(result).to be >= 1
          expect(result).to be <= 6
        end
      end

      it 'rolls negative modifier dice' do
        ability = build_ability( damage_modifier_dice: '-1d6')
        100.times do
          result = ability.calculate_modifier_dice
          expect(result).to be >= -6
          expect(result).to be <= -1
        end
      end
    end

    describe '#average_modifier_dice' do
      it 'returns 0.0 when no damage_modifier_dice' do
        ability = build_ability( damage_modifier_dice: nil)
        expect(ability.average_modifier_dice).to eq(0.0)
      end

      it 'calculates average for positive dice' do
        ability = build_ability( damage_modifier_dice: '+1d6')
        expect(ability.average_modifier_dice).to be_within(0.1).of(3.5)
      end

      it 'calculates negative average for negative dice' do
        ability = build_ability( damage_modifier_dice: '-1d6')
        expect(ability.average_modifier_dice).to be_within(0.1).of(-3.5)
      end
    end
  end

  # ========================================
  # Segment Timing
  # ========================================

  describe '#calculate_activation_segment' do
    it 'returns segment within variance range' do
      ability = build_ability( activation_segment: 50, segment_variance: 5)
      100.times do
        result = ability.calculate_activation_segment
        expect(result).to be >= 45
        expect(result).to be <= 55
      end
    end

    it 'clamps result to 1-100 range' do
      ability = build_ability( activation_segment: 1, segment_variance: 5)
      100.times do
        result = ability.calculate_activation_segment
        expect(result).to be >= 1
        expect(result).to be <= 100
      end
    end

    it 'uses defaults when nil' do
      ability = build_ability
      ability.activation_segment = nil
      ability.segment_variance = nil
      result = ability.calculate_activation_segment
      expect(result).to be >= 1
      expect(result).to be <= 100
    end
  end

  # ========================================
  # Narrative Helpers
  # ========================================

  describe 'narrative helpers' do
    describe '#random_cast_verb' do
      it 'returns default when no cast_verbs' do
        ability = build_ability( name: 'Fireball', cast_verbs: [])
        expect(ability.random_cast_verb).to eq('uses Fireball')
      end

      it 'returns random verb from cast_verbs' do
        verbs = ['hurls a fireball', 'launches flame']
        ability = build_ability( cast_verbs: verbs)
        expect(verbs).to include(ability.random_cast_verb)
      end
    end

    describe '#random_hit_verb' do
      it 'returns default when no hit_verbs' do
        ability = build_ability( hit_verbs: [])
        expect(ability.random_hit_verb).to eq('hits')
      end

      it 'returns random verb from hit_verbs' do
        verbs = ['burns', 'scorches']
        ability = build_ability( hit_verbs: verbs)
        expect(verbs).to include(ability.random_hit_verb)
      end
    end

    describe '#random_aoe_description' do
      it 'returns default when no aoe_descriptions' do
        ability = build_ability( aoe_descriptions: [])
        expect(ability.random_aoe_description).to eq('also hits')
      end

      it 'returns random description from aoe_descriptions' do
        descs = ['engulfs', 'spreads to']
        ability = build_ability( aoe_descriptions: descs)
        expect(descs).to include(ability.random_aoe_description)
      end
    end
  end

  # ========================================
  # Display Helpers
  # ========================================

  describe '#menu_description' do
    it 'includes damage dice and type' do
      ability = build_ability( base_damage_dice: '2d8', damage_type: 'fire')
      expect(ability.menu_description).to include('2d8 fire')
    end

    it 'indicates healing abilities' do
      ability = build_ability( is_healing: true, base_damage_dice: nil)
      expect(ability.menu_description).to include('heals')
    end

    it 'shows AoE radius' do
      ability = build_ability( aoe_shape: 'circle', aoe_radius: 3)
      expect(ability.menu_description).to include('AoE 3hex')
    end

    it 'shows activation segment' do
      ability = build_ability( activation_segment: 75)
      expect(ability.menu_description).to include('segment 75')
    end

    it 'shows cooldown rounds' do
      ability = build_ability( costs: { 'specific_cooldown' => { 'rounds' => 2 } })
      expect(ability.menu_description).to include('2rd CD')
    end
  end

  # ========================================
  # Advanced Combat Mechanics
  # ========================================

  describe 'advanced combat mechanics' do
    describe '#parsed_conditional_damage' do
      it 'returns empty array when no conditional_damage' do
        ability = build_ability
        ability.conditional_damage = nil
        expect(ability.parsed_conditional_damage).to eq([])
      end

      it 'parses conditional damage array' do
        cond = [{ 'condition' => 'target_has_status', 'status' => 'burning', 'bonus_dice' => '1d6' }]
        ability = build_ability( conditional_damage: cond)
        expect(ability.parsed_conditional_damage).to eq(cond)
      end
    end

    describe '#parsed_damage_types' do
      it 'returns empty array when no damage_types' do
        ability = build_ability
        ability.damage_types = nil
        expect(ability.parsed_damage_types).to eq([])
      end

      it 'parses split damage types' do
        types = [{ 'type' => 'fire', 'value' => '50%' }, { 'type' => 'physical', 'value' => '50%' }]
        ability = build_ability( damage_types: types)
        expect(ability.parsed_damage_types).to eq(types)
      end
    end

    describe '#parsed_chain_config' do
      it 'returns empty hash when no chain_config' do
        ability = build_ability
        ability.chain_config = nil
        # parse_jsonb_hash returns {} for nil values
        expect(ability.parsed_chain_config).to eq({})
      end

      it 'parses chain configuration' do
        config = { 'max_targets' => 3, 'range_per_jump' => 2 }
        ability = build_ability(chain_config: config)
        expect(ability.parsed_chain_config).to eq(config)
      end
    end

    describe '#has_chain?' do
      it 'returns false when no chain_config' do
        ability = build_ability( chain_config: nil)
        expect(ability.has_chain?).to be false
      end

      it 'returns false when chain_config is empty' do
        ability = build_ability( chain_config: {})
        expect(ability.has_chain?).to be false
      end

      it 'returns true when chain_config present' do
        ability = build_ability( chain_config: { 'max_targets' => 3 })
        expect(ability.has_chain?).to be true
      end
    end

    describe '#has_forced_movement?' do
      it 'returns false when no forced_movement' do
        ability = build_ability( forced_movement: nil)
        expect(ability.has_forced_movement?).to be false
      end

      it 'returns true when forced_movement present' do
        ability = build_ability( forced_movement: { 'direction' => 'away', 'distance' => 2 })
        expect(ability.has_forced_movement?).to be true
      end
    end

    describe '#has_execute?' do
      it 'returns false when execute_threshold is 0' do
        ability = build_ability( execute_threshold: 0)
        expect(ability.has_execute?).to be false
      end

      it 'returns true when execute_threshold is positive' do
        ability = build_ability( execute_threshold: 20)
        expect(ability.has_execute?).to be true
      end
    end

    describe '#has_combo?' do
      it 'returns false when no combo_condition' do
        ability = build_ability( combo_condition: nil)
        expect(ability.has_combo?).to be false
      end

      it 'returns true when combo_condition present' do
        ability = build_ability( combo_condition: { 'requires_status' => 'burning' })
        expect(ability.has_combo?).to be true
      end
    end

    describe '#has_conditional_damage?' do
      it 'returns false when no conditional_damage' do
        ability = build_ability( conditional_damage: [])
        expect(ability.has_conditional_damage?).to be false
      end

      it 'returns true when conditional_damage present' do
        ability = build_ability( conditional_damage: [{ 'condition' => 'test' }])
        expect(ability.has_conditional_damage?).to be true
      end
    end

    describe '#has_lifesteal?' do
      it 'returns false when lifesteal_max is 0' do
        ability = build_ability( lifesteal_max: 0)
        expect(ability.has_lifesteal?).to be false
      end

      it 'returns true when lifesteal_max is positive' do
        ability = build_ability( lifesteal_max: 5)
        expect(ability.has_lifesteal?).to be true
      end
    end

    describe '#has_split_damage?' do
      it 'returns false when no damage_types' do
        ability = build_ability( damage_types: [])
        expect(ability.has_split_damage?).to be false
      end

      it 'returns true when damage_types present' do
        ability = build_ability( damage_types: [{ 'type' => 'fire', 'value' => '100%' }])
        expect(ability.has_split_damage?).to be true
      end
    end
  end

  # ========================================
  # Associations
  # ========================================

  describe 'associations' do
    it 'belongs to universe' do
      universe = create(:universe)
      ability = create(:ability, universe: universe)
      expect(ability.universe).to eq(universe)
    end
  end

  # ========================================
  # Constants
  # ========================================

  describe 'constants' do
    it 'defines ABILITY_TYPES' do
      expect(Ability::ABILITY_TYPES).to eq(%w[combat utility passive social crafting])
    end

    it 'defines ACTION_TYPES' do
      expect(Ability::ACTION_TYPES).to eq(%w[main tactical free passive reaction])
    end

    it 'defines TARGET_TYPES' do
      expect(Ability::TARGET_TYPES).to eq(%w[self ally enemy])
    end

    it 'defines AOE_SHAPES' do
      expect(Ability::AOE_SHAPES).to eq(%w[single circle cone line])
    end

    it 'defines DAMAGE_TYPES' do
      expect(Ability::DAMAGE_TYPES).to eq(%w[fire ice lightning physical holy shadow poison healing])
    end

    it 'defines USER_TYPES' do
      expect(Ability::USER_TYPES).to eq(%w[pc npc])
    end

    it 'uses GameConfig for UNIFIED_ROLL expected_value' do
      expect(GameConfig::Mechanics::UNIFIED_ROLL[:expected_value]).to eq(10.3)
    end
  end
end
