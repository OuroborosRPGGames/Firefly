# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatusEffect do
  # ========================================
  # Validations
  # ========================================

  describe 'validations' do
    it 'requires name' do
      effect = build(:status_effect, name: nil)
      expect(effect.valid?).to be false
      expect(effect.errors[:name]).to include('is not present')
    end

    it 'requires effect_type' do
      effect = build(:status_effect, effect_type: nil)
      expect(effect.valid?).to be false
      expect(effect.errors[:effect_type]).to include('is not present')
    end

    it 'requires unique name' do
      create(:status_effect, name: 'Burning')
      duplicate = build(:status_effect, name: 'Burning')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:name]).to include('is already taken')
    end

    it 'requires name to be at most 50 characters' do
      effect = build(:status_effect, name: 'A' * 51)
      expect(effect.valid?).to be false
      expect(effect.errors[:name]).to include('is longer than 50 characters')
    end

    it 'validates effect_type is in EFFECT_TYPES' do
      effect = build(:status_effect, effect_type: 'invalid')
      expect(effect.valid?).to be false
      expect(effect.errors[:effect_type]).not_to be_empty
    end

    it 'validates stacking_behavior is in STACKING_BEHAVIORS when set' do
      effect = build(:status_effect, stacking_behavior: 'invalid')
      expect(effect.valid?).to be false
      expect(effect.errors[:stacking_behavior]).not_to be_empty
    end

    it 'accepts all valid effect types' do
      StatusEffect::EFFECT_TYPES.each do |type|
        effect = build(:status_effect, effect_type: type)
        expect(effect.valid?).to eq(true), "Expected effect_type '#{type}' to be valid"
      end
    end

    it 'accepts all valid stacking behaviors' do
      StatusEffect::STACKING_BEHAVIORS.each do |behavior|
        effect = build(:status_effect, stacking_behavior: behavior)
        expect(effect.valid?).to eq(true), "Expected stacking_behavior '#{behavior}' to be valid"
      end
    end
  end

  # ========================================
  # Mechanics Parsing
  # ========================================

  describe '#parsed_mechanics' do
    it 'returns empty hash when mechanics is nil' do
      effect = build(:status_effect)
      effect.mechanics = nil
      expect(effect.parsed_mechanics).to eq({})
    end

    it 'parses JSONB mechanics correctly' do
      effect = build(:status_effect, mechanics: { 'modifier' => 5, 'can_move' => false })
      expect(effect.parsed_mechanics).to include('modifier' => 5)
      expect(effect.parsed_mechanics).to include('can_move' => false)
    end
  end

  # ========================================
  # Buff/Debuff Methods
  # ========================================

  describe '#buff?' do
    it 'returns true when is_buff is true' do
      effect = build(:status_effect, is_buff: true)
      expect(effect.buff?).to be true
    end

    it 'returns false when is_buff is false' do
      effect = build(:status_effect, is_buff: false)
      expect(effect.buff?).to be false
    end

    it 'returns false when is_buff is nil' do
      effect = build(:status_effect)
      effect.is_buff = nil
      expect(effect.buff?).to be false
    end
  end

  describe '#debuff?' do
    it 'returns true when is_buff is false' do
      effect = build(:status_effect, is_buff: false)
      expect(effect.debuff?).to be true
    end

    it 'returns false when is_buff is true' do
      effect = build(:status_effect, is_buff: true)
      expect(effect.debuff?).to be false
    end
  end

  # ========================================
  # Modifier Value
  # ========================================

  describe '#modifier_value' do
    it 'returns modifier from mechanics' do
      effect = build(:status_effect, mechanics: { 'modifier' => 10 })
      expect(effect.modifier_value).to eq(10)
    end

    it 'returns negative modifier' do
      effect = build(:status_effect, mechanics: { 'modifier' => -5 })
      expect(effect.modifier_value).to eq(-5)
    end

    it 'returns 0 when no modifier in mechanics' do
      effect = build(:status_effect, mechanics: {})
      expect(effect.modifier_value).to eq(0)
    end

    it 'returns 0 when mechanics is nil' do
      effect = build(:status_effect)
      effect.mechanics = nil
      expect(effect.modifier_value).to eq(0)
    end
  end

  # ========================================
  # Movement Blocking
  # ========================================

  describe '#blocks_movement?' do
    it 'returns true for movement effect with can_move false' do
      effect = build(:status_effect, effect_type: 'movement', mechanics: { 'can_move' => false })
      expect(effect.blocks_movement?).to be true
    end

    it 'returns false for movement effect with can_move true' do
      effect = build(:status_effect, effect_type: 'movement', mechanics: { 'can_move' => true })
      expect(effect.blocks_movement?).to be false
    end

    it 'returns false for non-movement effect types' do
      effect = build(:status_effect, effect_type: 'stat_modifier', mechanics: { 'can_move' => false })
      expect(effect.blocks_movement?).to be false
    end

    it 'returns false when mechanics has no can_move key' do
      effect = build(:status_effect, effect_type: 'movement', mechanics: {})
      expect(effect.blocks_movement?).to be false
    end
  end

  # ========================================
  # Stacking Behavior
  # ========================================

  describe '#stackable?' do
    it 'returns true when stacking_behavior is stack' do
      effect = build(:status_effect, stacking_behavior: 'stack')
      expect(effect.stackable?).to be true
    end

    it 'returns false when stacking_behavior is refresh' do
      effect = build(:status_effect, stacking_behavior: 'refresh')
      expect(effect.stackable?).to be false
    end

    it 'returns false when stacking_behavior is duration' do
      effect = build(:status_effect, stacking_behavior: 'duration')
      expect(effect.stackable?).to be false
    end

    it 'returns false when stacking_behavior is ignore' do
      effect = build(:status_effect, stacking_behavior: 'ignore')
      expect(effect.stackable?).to be false
    end
  end

  describe '#refreshable?' do
    it 'returns true when stacking_behavior is refresh' do
      effect = build(:status_effect, stacking_behavior: 'refresh')
      expect(effect.refreshable?).to be true
    end

    it 'returns false when stacking_behavior is stack' do
      effect = build(:status_effect, stacking_behavior: 'stack')
      expect(effect.refreshable?).to be false
    end

    it 'returns false when stacking_behavior is duration' do
      effect = build(:status_effect, stacking_behavior: 'duration')
      expect(effect.refreshable?).to be false
    end

    it 'returns false when stacking_behavior is ignore' do
      effect = build(:status_effect, stacking_behavior: 'ignore')
      expect(effect.refreshable?).to be false
    end
  end

  # ========================================
  # Constants
  # ========================================

  describe 'constants' do
    it 'defines EFFECT_TYPES' do
      expected = %w[
        movement incoming_damage outgoing_damage healing stat_modifier
        damage_tick healing_tick action_restriction targeting_restriction
        damage_reduction protection shield fear grapple
      ]
      expect(StatusEffect::EFFECT_TYPES).to eq(expected)
    end

    it 'defines STACKING_BEHAVIORS' do
      expect(StatusEffect::STACKING_BEHAVIORS).to eq(%w[refresh stack duration ignore])
    end
  end

  # ========================================
  # Database Persistence
  # ========================================

  describe 'persistence' do
    it 'saves and retrieves status effect' do
      effect = create(:status_effect, name: 'Test Effect', effect_type: 'damage_tick')
      retrieved = StatusEffect.find(id: effect.id)
      expect(retrieved.name).to eq('Test Effect')
      expect(retrieved.effect_type).to eq('damage_tick')
    end

    it 'persists mechanics JSONB' do
      mechanics = { 'modifier' => 15, 'duration' => 3 }
      effect = create(:status_effect, mechanics: mechanics)
      retrieved = StatusEffect.find(id: effect.id)
      expect(retrieved.parsed_mechanics['modifier']).to eq(15)
      expect(retrieved.parsed_mechanics['duration']).to eq(3)
    end
  end
end
