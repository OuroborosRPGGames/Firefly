# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ObserverEffectService do
  let(:room) { create(:room) }
  let(:activity) { create(:activity) }
  let(:instance) { create(:activity_instance, activity: activity, room: room) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }
  let(:participant) do
    # character_instance must be created first to be available
    character_instance
    create(:activity_participant,
           instance_id: instance.id,
           char_id: character.id)
  end

  let(:supporter_char) { create(:character) }
  let(:supporter_instance) { create(:character_instance, character: supporter_char, current_room: room) }
  let(:opposer_char) { create(:character) }
  let(:opposer_instance) { create(:character_instance, character: opposer_char, current_room: room) }

  describe '.effects_for' do
    context 'with no observers' do
      it 'returns empty hash' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result).to eq({})
      end
    end

    context 'with reroll_ones support action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'reroll_ones',
               action_target_id: participant.id)
      end

      it 'returns reroll_ones: true' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result[:reroll_ones]).to eq(true)
      end
    end

    context 'with block_damage support action in standard rounds' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'block_damage',
               action_target_id: participant.id)
      end

      it 'does not return block_damage effect' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result[:block_damage]).to be_nil
      end
    end

    context 'with block_explosions opposition action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'block_explosions',
               action_target_id: participant.id)
      end

      it 'returns block_explosions: true' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result[:block_explosions]).to eq(true)
      end
    end

    context 'with damage_on_ones opposition action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'damage_on_ones',
               action_target_id: participant.id)
      end

      it 'returns damage_on_ones: true' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result[:damage_on_ones]).to eq(true)
      end
    end

    context 'with block_willpower opposition action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'block_willpower',
               action_target_id: participant.id)
      end

      it 'returns block_willpower: true' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result[:block_willpower]).to eq(true)
      end
    end

    context 'with inactive observer' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: false,
               action_type: 'reroll_ones',
               action_target_id: participant.id)
      end

      it 'ignores inactive observers' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result).to eq({})
      end
    end

    context 'with action targeting different participant' do
      let(:other_participant) do
        other_char = create(:character)
        create(:character_instance, character: other_char, current_room: room)
        create(:activity_participant,
               instance_id: instance.id,
               char_id: other_char.id)
      end

      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'reroll_ones',
               action_target_id: other_participant.id)
      end

      it 'does not include effects targeting other participants' do
        result = described_class.effects_for(participant, round_type: :standard)
        expect(result).to eq({})
      end
    end
  end

  describe '.effects_for_persuade' do
    context 'with no observers' do
      it 'returns empty arrays' do
        result = described_class.effects_for_persuade(instance)
        expect(result[:distractions]).to eq([])
        expect(result[:attention_draws]).to eq([])
      end
    end

    context 'with distraction action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'distraction',
               action_message: 'Look over there!')
      end

      it 'includes distraction message' do
        result = described_class.effects_for_persuade(instance)
        expect(result[:distractions]).to include('Look over there!')
      end
    end

    context 'with draw_attention action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'draw_attention',
               action_message: 'Hey! Check this person out!')
      end

      it 'includes attention_draw message' do
        result = described_class.effects_for_persuade(instance)
        expect(result[:attention_draws]).to include('Hey! Check this person out!')
      end
    end

    context 'with both distraction and draw_attention' do
      let!(:supporter) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'distraction',
               action_message: 'Distraction message')
      end

      let!(:opposer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'draw_attention',
               action_message: 'Attention message')
      end

      it 'includes both types' do
        result = described_class.effects_for_persuade(instance)
        expect(result[:distractions]).to include('Distraction message')
        expect(result[:attention_draws]).to include('Attention message')
      end
    end
  end

  describe '.effects_for_combat' do
    context 'with no observers' do
      it 'returns empty hash' do
        result = described_class.effects_for_combat(instance)
        expect(result).to eq({})
      end
    end

    context 'with halve_damage action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'halve_damage',
               action_target_id: participant.id)
      end

      it 'includes halve_damage_from effect' do
        result = described_class.effects_for_combat(instance)
        expect(result[participant.id]).to include(:halve_damage_from)
      end
    end

    context 'with block_damage action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'block_damage',
               action_target_id: participant.id)
      end

      it 'includes block_damage effect' do
        result = described_class.effects_for_combat(instance)
        expect(result[participant.id][:block_damage]).to eq(true)
      end
    end

    context 'with aggro_boost action' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'aggro_boost',
               action_target_id: participant.id)
      end

      it 'includes aggro_boost effect' do
        result = described_class.effects_for_combat(instance)
        expect(result[participant.id]).to include(:aggro_boost)
        expect(result[participant.id][:aggro_boost]).to eq(true)
      end
    end
  end

  describe '.clear_actions!' do
    let!(:observer) do
      create(:activity_remote_observer,
             activity_instance: instance,
             character_instance: supporter_instance,
             role: 'support',
             active: true,
             action_type: 'reroll_ones',
             action_target_id: participant.id,
             action_message: 'Go team!')
    end

    it 'clears all observer actions' do
      expect(observer.action_type).to eq('reroll_ones')

      described_class.clear_actions!(instance)

      observer.refresh
      expect(observer.action_type).to be_nil
      expect(observer.action_target_id).to be_nil
      expect(observer.action_message).to be_nil
    end
  end

  describe '.emit_observer_messages' do
    context 'with no messages' do
      it 'returns empty array' do
        result = described_class.emit_observer_messages(instance)
        expect(result).to eq([])
      end
    end

    context 'with supporter message' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'reroll_ones',
               action_message: 'Good luck!')
      end

      it 'returns formatted support message' do
        result = described_class.emit_observer_messages(instance)
        expect(result).to include('[Remote Support] Good luck!')
      end
    end

    context 'with opposer message' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'block_explosions',
               action_message: 'You will fail!')
      end

      it 'returns formatted opposition message' do
        result = described_class.emit_observer_messages(instance)
        expect(result).to include('[Remote Opposition] You will fail!')
      end
    end

    context 'with observer without message' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'reroll_ones',
               action_message: nil)
      end

      it 'does not include observers without messages' do
        result = described_class.emit_observer_messages(instance)
        expect(result).to eq([])
      end
    end
  end

  describe '.persuade_dc_modifier' do
    context 'with no observers' do
      it 'returns 0' do
        result = described_class.persuade_dc_modifier(instance)
        expect(result).to eq(0)
      end
    end

    context 'with one distraction' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'distraction')
      end

      it 'returns -2' do
        result = described_class.persuade_dc_modifier(instance)
        expect(result).to eq(-2)
      end
    end

    context 'with one draw_attention' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'draw_attention')
      end

      it 'returns +2' do
        result = described_class.persuade_dc_modifier(instance)
        expect(result).to eq(2)
      end
    end

    context 'with mixed effects' do
      let!(:supporter1) do
        si1 = create(:character_instance, character: create(:character), current_room: room)
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: si1,
               role: 'support',
               active: true,
               action_type: 'distraction')
      end

      let!(:supporter2) do
        si2 = create(:character_instance, character: create(:character), current_room: room)
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: si2,
               role: 'support',
               active: true,
               action_type: 'distraction')
      end

      let!(:opposer1) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: opposer_instance,
               role: 'oppose',
               active: true,
               action_type: 'draw_attention')
      end

      it 'calculates net modifier' do
        # 2 distractions (-4) + 1 draw_attention (+2) = -2
        result = described_class.persuade_dc_modifier(instance)
        expect(result).to eq(-2)
      end
    end
  end
end
