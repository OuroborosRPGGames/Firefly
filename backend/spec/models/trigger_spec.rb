# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Trigger do
  let(:user) { create(:user) }
  let(:npc_archetype) { create(:npc_archetype) }
  let(:npc_character) { create(:character, :npc, npc_archetype_id: npc_archetype.id) }
  let(:other_npc_archetype) { create(:npc_archetype) }
  let(:other_npc_character) { create(:character, :npc, npc_archetype_id: other_npc_archetype.id) }

  describe 'schema contract' do
    it 'includes required columns for trigger identity and matching' do
      expect(Trigger.columns).to include(:name, :trigger_type, :condition_type, :action_type)
    end
  end

  describe 'constants' do
    it 'defines TRIGGER_TYPES' do
      expect(Trigger::TRIGGER_TYPES).to include('mission', 'npc', 'world_memory', 'clue_share')
    end

    it 'defines CONDITION_TYPES' do
      expect(Trigger::CONDITION_TYPES).to include('exact', 'contains', 'llm_match', 'regex')
    end

    it 'defines ACTION_TYPES' do
      expect(Trigger::ACTION_TYPES).to include('code_block', 'staff_alert', 'both')
    end

    it 'defines MISSION_EVENTS' do
      expect(Trigger::MISSION_EVENTS).to include('succeed', 'fail', 'branch', 'round_complete')
    end
  end

  describe 'validations' do
    it 'requires name, trigger_type, condition_type, and action_type' do
      trigger = Trigger.new(created_by: user)

      expect(trigger.valid?).to be false
      expect(trigger.errors[:name]).not_to be_empty
      expect(trigger.errors[:trigger_type]).not_to be_empty
      expect(trigger.errors[:condition_type]).not_to be_empty
      expect(trigger.errors[:action_type]).not_to be_empty
    end

    it 'accepts valid mission_event_type values' do
      Trigger::MISSION_EVENTS.each do |event_type|
        trigger = build(:trigger, mission_event_type: event_type, created_by: user)
        expect(trigger.valid?).to be(true), "Expected #{event_type} to be valid"
      end
    end

    it 'rejects invalid mission_event_type' do
      trigger = build(:trigger, mission_event_type: 'invalid', created_by: user)

      expect(trigger.valid?).to be false
      expect(trigger.errors[:mission_event_type]).not_to be_empty
    end
  end

  describe 'type predicates' do
    context 'with mission trigger' do
      let(:trigger) { Trigger.new(trigger_type: 'mission') }

      it '#mission_trigger? returns true' do
        expect(trigger.mission_trigger?).to be true
      end

      it '#npc_trigger? returns false' do
        expect(trigger.npc_trigger?).to be false
      end
    end

    context 'with npc trigger' do
      let(:trigger) { Trigger.new(trigger_type: 'npc') }

      it '#npc_trigger? returns true' do
        expect(trigger.npc_trigger?).to be true
      end
    end

    context 'with world_memory trigger' do
      let(:trigger) { Trigger.new(trigger_type: 'world_memory') }

      it '#world_memory_trigger? returns true' do
        expect(trigger.world_memory_trigger?).to be true
      end
    end

    context 'with clue_share trigger' do
      let(:trigger) { Trigger.new(trigger_type: 'clue_share') }

      it '#clue_share_trigger? returns true' do
        expect(trigger.clue_share_trigger?).to be true
      end
    end
  end

  describe 'condition predicates' do
    it '#requires_llm_match? returns true for llm_match' do
      trigger = Trigger.new(condition_type: 'llm_match')
      expect(trigger.requires_llm_match?).to be true
    end

    it '#requires_llm_match? returns false for exact' do
      trigger = Trigger.new(condition_type: 'exact')
      expect(trigger.requires_llm_match?).to be false
    end
  end

  describe 'action predicates' do
    describe '#should_execute_code?' do
      it 'returns true for code_block' do
        trigger = Trigger.new(action_type: 'code_block')
        expect(trigger.should_execute_code?).to be true
      end

      it 'returns true for both' do
        trigger = Trigger.new(action_type: 'both')
        expect(trigger.should_execute_code?).to be true
      end

      it 'returns false for staff_alert' do
        trigger = Trigger.new(action_type: 'staff_alert')
        expect(trigger.should_execute_code?).to be false
      end
    end

    describe '#should_alert_staff?' do
      it 'returns true for staff_alert' do
        trigger = Trigger.new(action_type: 'staff_alert')
        expect(trigger.should_alert_staff?).to be true
      end

      it 'returns true for both' do
        trigger = Trigger.new(action_type: 'both')
        expect(trigger.should_alert_staff?).to be true
      end

      it 'returns false for code_block' do
        trigger = Trigger.new(action_type: 'code_block')
        expect(trigger.should_alert_staff?).to be false
      end
    end
  end

  describe '#activation_count' do
    it 'returns the number of activations for the trigger' do
      trigger = create(:trigger, created_by: user)
      TriggerActivation.create(trigger_id: trigger.id, source_type: 'character')
      TriggerActivation.create(trigger_id: trigger.id, source_type: 'system')

      expect(trigger.activation_count).to eq(2)
    end
  end

  describe '#recent_activations' do
    it 'returns activations ordered by activated_at desc and limited by count' do
      trigger = create(:trigger, created_by: user)
      oldest = TriggerActivation.create(
        trigger_id: trigger.id,
        source_type: 'system',
        activated_at: Time.now - 120
      )
      middle = TriggerActivation.create(
        trigger_id: trigger.id,
        source_type: 'character',
        activated_at: Time.now - 60
      )
      newest = TriggerActivation.create(
        trigger_id: trigger.id,
        source_type: 'npc',
        activated_at: Time.now
      )

      result = trigger.recent_activations(limit: 2)

      expect(result).to eq([newest, middle])
      expect(result).not_to include(oldest)
    end
  end

  describe '#applies_to_npc?' do
    it 'returns false for non-npc triggers' do
      trigger = Trigger.new(trigger_type: 'mission')
      expect(trigger.applies_to_npc?(npc_character)).to be false
    end

    it 'returns true when trigger targets a specific NPC' do
      trigger = Trigger.new(trigger_type: 'npc', npc_character_id: npc_character.id)
      expect(trigger.applies_to_npc?(npc_character)).to be true
    end

    it 'returns false for a different NPC when specific NPC is configured' do
      trigger = Trigger.new(trigger_type: 'npc', npc_character_id: npc_character.id)
      expect(trigger.applies_to_npc?(other_npc_character)).to be false
    end

    it 'returns true for all NPCs when no specific NPC or archetype filters are configured' do
      trigger = Trigger.new(trigger_type: 'npc', npc_character_id: nil, npc_archetype_ids: [])
      expect(trigger.applies_to_npc?(npc_character)).to be true
    end

    it 'returns true when NPC archetype is included in filters' do
      trigger = Trigger.new(
        trigger_type: 'npc',
        npc_character_id: nil,
        npc_archetype_ids: [npc_archetype.id]
      )

      expect(trigger.applies_to_npc?(npc_character)).to be true
    end

    it 'returns false when NPC archetype is not included in filters' do
      trigger = Trigger.new(
        trigger_type: 'npc',
        npc_character_id: nil,
        npc_archetype_ids: [npc_archetype.id]
      )

      expect(trigger.applies_to_npc?(other_npc_character)).to be false
    end
  end
end
