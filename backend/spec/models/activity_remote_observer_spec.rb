# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityRemoteObserver do
  let(:activity) { create(:activity) }
  let(:room) { create(:room) }
  let(:instance) { create(:activity_instance, activity: activity, room: room) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }
  let(:consenter) { create(:character_instance, current_room: room) }

  describe 'validations' do
    it 'requires activity_instance_id' do
      observer = ActivityRemoteObserver.new(
        character_instance_id: character_instance.id,
        role: 'support'
      )
      expect(observer.valid?).to be false
      expect(observer.errors[:activity_instance_id]).not_to be_empty
    end

    it 'requires character_instance_id' do
      observer = ActivityRemoteObserver.new(
        activity_instance_id: instance.id,
        role: 'support'
      )
      expect(observer.valid?).to be false
      expect(observer.errors[:character_instance_id]).not_to be_empty
    end

    it 'requires role' do
      observer = ActivityRemoteObserver.new(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id
      )
      expect(observer.valid?).to be false
      expect(observer.errors[:role]).not_to be_empty
    end

    it 'validates role is support or oppose' do
      observer = ActivityRemoteObserver.new(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        role: 'invalid'
      )
      expect(observer.valid?).to be false
    end

    it 'is valid with required fields' do
      observer = ActivityRemoteObserver.new(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support'
      )
      expect(observer.valid?).to be true
    end
  end

  describe '#supporter?' do
    it 'returns true for support role' do
      observer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support'
      )
      expect(observer.supporter?).to be true
      expect(observer.opposer?).to be false
    end
  end

  describe '#opposer?' do
    it 'returns true for oppose role' do
      observer = ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'oppose'
      )
      expect(observer.opposer?).to be true
      expect(observer.supporter?).to be false
    end
  end

  describe '#submit_action!' do
    let(:observer) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support'
      )
    end
    let(:target) { create(:activity_participant, instance: instance) }

    it 'sets action fields' do
      observer.submit_action!(
        type: 'reroll_ones',
        target_id: target.id,
        message: 'Hacking their firewall'
      )

      observer.refresh
      expect(observer.action_type).to eq('reroll_ones')
      expect(observer.action_target_id).to eq(target.id)
      expect(observer.action_message).to eq('Hacking their firewall')
      expect(observer.action_submitted_at).not_to be_nil
    end
  end

  describe '#clear_action!' do
    let(:observer) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support',
        action_type: 'reroll_ones',
        action_target_id: 1,
        action_message: 'test'
      )
    end

    it 'clears all action fields' do
      observer.clear_action!
      observer.refresh

      expect(observer.action_type).to be_nil
      expect(observer.action_target_id).to be_nil
      expect(observer.action_message).to be_nil
      expect(observer.action_submitted_at).to be_nil
    end
  end

  describe '#has_action?' do
    let(:observer) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support'
      )
    end

    it 'returns false when no action submitted' do
      expect(observer.has_action?).to be false
    end

    it 'returns true when action submitted' do
      observer.update(action_type: 'reroll_ones')
      expect(observer.has_action?).to be true
    end
  end

  describe '#available_actions' do
    let(:supporter) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support'
      )
    end

    let(:other_character_instance) { create(:character_instance, current_room: room) }
    let(:opposer) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: other_character_instance.id,
        consented_by_id: consenter.id,
        role: 'oppose'
      )
    end

    it 'returns support actions for supporter in standard round' do
      actions = supporter.available_actions(:standard)
      expect(actions).to include('stat_swap', 'reroll_ones')
      expect(actions).not_to include('block_damage')
    end

    it 'returns oppose actions for opposer in standard round' do
      actions = opposer.available_actions(:standard)
      expect(actions).to include('block_explosions', 'damage_on_ones', 'block_willpower')
    end

    it 'returns combat-specific actions for combat rounds' do
      support_actions = supporter.available_actions(:combat)
      oppose_actions = opposer.available_actions(:combat)

      expect(support_actions).to include('block_damage', 'halve_damage', 'expose_targets')
      expect(oppose_actions).to include('redirect_npc', 'aggro_boost')
    end

    it 'returns persuade-specific actions for persuade rounds' do
      support_actions = supporter.available_actions(:persuade)
      oppose_actions = opposer.available_actions(:persuade)

      expect(support_actions).to include('distraction')
      expect(oppose_actions).to include('draw_attention')
    end

    it 'defaults to standard round type' do
      actions = supporter.available_actions
      expect(actions).to include('stat_swap', 'reroll_ones')
      expect(actions).not_to include('block_damage')
    end
  end

  describe 'dataset scopes' do
    let!(:active_supporter) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support',
        active: true
      )
    end

    let(:other_ci) { create(:character_instance, current_room: room) }
    let!(:inactive_opposer) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: other_ci.id,
        consented_by_id: consenter.id,
        role: 'oppose',
        active: false
      )
    end

    let(:third_ci) { create(:character_instance, current_room: room) }
    let!(:active_opposer) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: third_ci.id,
        consented_by_id: consenter.id,
        role: 'oppose',
        active: true
      )
    end

    describe '.active' do
      it 'returns only active observers' do
        results = ActivityRemoteObserver.active.all
        expect(results).to include(active_supporter)
        expect(results).to include(active_opposer)
        expect(results).not_to include(inactive_opposer)
      end
    end

    describe '.supporters' do
      it 'returns only active supporters' do
        results = ActivityRemoteObserver.supporters.all
        expect(results).to include(active_supporter)
        expect(results).not_to include(inactive_opposer)
        expect(results).not_to include(active_opposer)
      end

      it 'excludes inactive supporters' do
        active_supporter.update(active: false)
        results = ActivityRemoteObserver.supporters.all
        expect(results).not_to include(active_supporter)
      end
    end

    describe '.opposers' do
      it 'returns only active opposers' do
        results = ActivityRemoteObserver.opposers.all
        expect(results).to include(active_opposer)
        expect(results).not_to include(inactive_opposer)
        expect(results).not_to include(active_supporter)
      end

      it 'excludes inactive opposers' do
        results = ActivityRemoteObserver.opposers.all
        expect(results).not_to include(inactive_opposer)
      end
    end

    describe '.for_instance' do
      let(:other_instance) { create(:activity_instance, activity: activity, room: room) }
      let(:fourth_ci) { create(:character_instance, current_room: room) }
      let!(:other_instance_observer) do
        ActivityRemoteObserver.create(
          activity_instance_id: other_instance.id,
          character_instance_id: fourth_ci.id,
          consented_by_id: consenter.id,
          role: 'support',
          active: true
        )
      end

      it 'returns only observers for the specified instance' do
        results = ActivityRemoteObserver.for_instance(instance.id).all
        expect(results).to include(active_supporter)
        expect(results).to include(inactive_opposer)
        expect(results).to include(active_opposer)
        expect(results).not_to include(other_instance_observer)
      end

      it 'returns observers for a different instance' do
        results = ActivityRemoteObserver.for_instance(other_instance.id).all
        expect(results).to include(other_instance_observer)
        expect(results).not_to include(active_supporter)
      end
    end
  end

  describe 'associations' do
    let(:observer) do
      ActivityRemoteObserver.create(
        activity_instance_id: instance.id,
        character_instance_id: character_instance.id,
        consented_by_id: consenter.id,
        role: 'support'
      )
    end

    it 'belongs to activity_instance' do
      expect(observer.activity_instance).to eq(instance)
    end

    it 'belongs to character_instance' do
      expect(observer.character_instance).to eq(character_instance)
    end

    it 'belongs to consented_by' do
      expect(observer.consented_by).to eq(consenter)
    end
  end
end
