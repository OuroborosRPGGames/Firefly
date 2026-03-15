# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Remote Observer Integration', type: :integration do
  describe 'schema contract' do
    it 'has activity_remote_observers table' do
      expect(DB.table_exists?(:activity_remote_observers)).to be true
    end
  end

  let(:activity) { create(:activity) }
  let(:mission_room) { create(:room) }
  let(:remote_room) { create(:room) }

  let(:field_player) { create(:character_instance, current_room: mission_room) }
  let(:remote_supporter) { create(:character_instance, current_room: remote_room) }

  let(:instance) do
    create(:activity_instance,
           activity: activity,
           room: mission_room,
           running: true)
  end

  let!(:participant) do
    create(:activity_participant,
           instance: instance,
           character: field_player.character,
           continue: true)
  end

  describe 'full workflow' do
    it 'allows remote player to support and affect rolls' do
      # 1. Remote player requests to support
      # 2. Field player accepts
      observer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )

      expect(observer).to be_valid
      expect(observer.supporter?).to be true

      # 3. Remote player submits reroll_ones action
      observer.submit_action!(
        type: 'reroll_ones',
        target_id: participant.id,
        message: 'Overriding their security protocols'
      )

      observer.refresh
      expect(observer.action_type).to eq('reroll_ones')
      expect(observer.action_target_id).to eq(participant.id)
      expect(observer.action_message).to eq('Overriding their security protocols')
      expect(observer.action_submitted_at).not_to be_nil

      # 4. Verify effects are returned
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      expect(effects[:reroll_ones]).to be true

      # 5. Verify observer messages are generated
      messages = ObserverEffectService.emit_observer_messages(instance)
      expect(messages).not_to be_empty
      expect(messages.first).to include('Overriding their security protocols')
      expect(messages.first).to include('[Remote Support]')

      # 6. Clear actions
      ObserverEffectService.clear_actions!(instance)
      observer.refresh
      expect(observer.action_type).to be_nil
      expect(observer.action_target_id).to be_nil
      expect(observer.action_message).to be_nil
    end

    it 'allows remote player to oppose and affect rolls' do
      observer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: nil, # Opposition doesn't require consent
        role: 'oppose'
      )

      expect(observer).to be_valid
      expect(observer.opposer?).to be true

      # Submit damage_on_ones action
      observer.submit_action!(
        type: 'damage_on_ones',
        target_id: participant.id,
        message: 'Sabotaging their equipment'
      )

      # Verify effects
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      expect(effects[:damage_on_ones]).to be true

      # Verify messages include opposition prefix
      messages = ObserverEffectService.emit_observer_messages(instance)
      expect(messages.first).to include('[Remote Opposition]')
    end

    it 'tracks multiple observers with different actions' do
      supporter = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )

      another_observer = create(:character_instance, current_room: remote_room)
      opposer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: another_observer.id,
        role: 'oppose'
      )

      supporter.submit_action!(
        type: 'reroll_ones',
        target_id: participant.id,
        message: 'Helping out'
      )

      opposer.submit_action!(
        type: 'block_explosions',
        target_id: participant.id,
        message: 'Blocking their luck'
      )

      # Both effects should be present
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      expect(effects[:reroll_ones]).to be true
      expect(effects[:block_explosions]).to be true

      # Both messages should appear
      messages = ObserverEffectService.emit_observer_messages(instance)
      expect(messages.length).to eq(2)
    end

    it 'returns available actions based on role and round type' do
      supporter = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )

      # Standard round actions for supporter
      standard_actions = supporter.available_actions(:standard)
      expect(standard_actions).to include('reroll_ones')
      expect(standard_actions).to include('stat_swap')
      expect(standard_actions).not_to include('block_damage')

      # Combat round actions for supporter
      combat_actions = supporter.available_actions(:combat)
      expect(combat_actions).to include('block_damage')
      expect(combat_actions).to include('halve_damage')
      expect(combat_actions).to include('expose_targets')

      # Persuade round actions for supporter
      persuade_actions = supporter.available_actions(:persuade)
      expect(persuade_actions).to include('distraction')
    end

    it 'clears all observer actions for an instance' do
      observer1 = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )

      another_observer = create(:character_instance, current_room: remote_room)
      observer2 = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: another_observer.id,
        role: 'oppose'
      )

      observer1.submit_action!(type: 'reroll_ones', target_id: participant.id)
      observer2.submit_action!(type: 'damage_on_ones', target_id: participant.id)

      # Both should have actions
      observer1.refresh
      observer2.refresh
      expect(observer1.has_action?).to be true
      expect(observer2.has_action?).to be true

      # Clear all
      instance.clear_observer_actions!

      # Both should be cleared
      observer1.refresh
      observer2.refresh
      expect(observer1.has_action?).to be false
      expect(observer2.has_action?).to be false
    end
  end

  describe 'persuade round effects' do
    it 'calculates DC modifier from distractions and attention draws' do
      # Create a supporter with distraction
      supporter = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )
      supporter.submit_action!(
        type: 'distraction',
        message: 'Creating a diversion'
      )

      # DC should be lowered by 2
      modifier = ObserverEffectService.persuade_dc_modifier(instance)
      expect(modifier).to eq(-2)

      # Add an opposer with draw_attention
      another_observer = create(:character_instance, current_room: remote_room)
      opposer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: another_observer.id,
        role: 'oppose'
      )
      opposer.submit_action!(
        type: 'draw_attention',
        message: 'Alerting the guards'
      )

      # Effects should cancel out (-2 + 2 = 0)
      modifier = ObserverEffectService.persuade_dc_modifier(instance)
      expect(modifier).to eq(0)
    end

    it 'collects persuade-specific effects' do
      supporter = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )
      supporter.submit_action!(
        type: 'distraction',
        message: 'Creating a diversion'
      )

      effects = ObserverEffectService.effects_for_persuade(instance)
      expect(effects[:distractions]).to include('Creating a diversion')
      expect(effects[:attention_draws]).to be_empty
    end
  end

  describe 'combat round effects' do
    it 'tracks combat-specific effects like halve_damage' do
      supporter = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )

      # Halve damage from a specific source (secondary target)
      supporter.submit_action!(
        type: 'halve_damage',
        target_id: participant.id,
        secondary_target_id: 999 # Imaginary enemy ID
      )

      effects = ObserverEffectService.effects_for_combat(instance)
      expect(effects[participant.id]).not_to be_nil
      expect(effects[participant.id][:halve_damage_from]).to include(999)
    end

    it 'applies damage multipliers' do
      another_observer = create(:character_instance, current_room: remote_room)
      opposer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: another_observer.id,
        role: 'oppose'
      )

      opposer.submit_action!(
        type: 'pc_damage_boost',
        target_id: participant.id
      )

      effects = ObserverEffectService.effects_for_combat(instance)
      expect(effects[participant.id][:damage_taken_mult]).to eq(1.5)
    end
  end

  describe 'observer lifecycle' do
    it 'deactivates observer when set to inactive' do
      observer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support',
        active: true
      )

      observer.submit_action!(
        type: 'reroll_ones',
        target_id: participant.id
      )

      # Effects should be present when active
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      expect(effects[:reroll_ones]).to be true

      # Deactivate observer
      observer.update(active: false)

      # Effects should no longer be present
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      expect(effects[:reroll_ones]).to be_nil
    end

    it 'lists observers via instance methods' do
      supporter = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )

      another_observer = create(:character_instance, current_room: remote_room)
      opposer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: another_observer.id,
        role: 'oppose'
      )

      expect(instance.supporters).to include(supporter)
      expect(instance.opposers).to include(opposer)
      expect(instance.remote_observers.length).to eq(2)
    end

    it 'finds observer for a specific character' do
      observer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: remote_supporter.id,
        consented_by_id: field_player.id,
        role: 'support'
      )

      found = instance.remote_observer_for(remote_supporter)
      expect(found).to eq(observer)

      # Non-observer should return nil
      other_ci = create(:character_instance)
      expect(instance.remote_observer_for(other_ci)).to be_nil
    end
  end
end
