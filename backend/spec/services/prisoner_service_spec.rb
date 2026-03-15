# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PrisonerService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:other_character) { create(:character, user: create(:user)) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:actor) { create(:character_instance, character: character, reality: reality, current_room: room) }
  let(:target) { create(:character_instance, character: other_character, reality: reality, current_room: room) }

  describe '.make_helpless!' do
    it 'sets character as helpless with reason' do
      result = described_class.make_helpless!(target, reason: 'unconscious')

      expect(result[:success]).to be true
      target.reload
      expect(target.is_helpless).to be true
      expect(target.helpless_reason).to eq('unconscious')
    end

    it 'clears following when becoming helpless' do
      target.update(following_id: actor.id)

      described_class.make_helpless!(target, reason: 'bound_hands')

      target.reload
      expect(target.following_id).to be_nil
    end

    it 'handles errors gracefully' do
      allow(target).to receive(:update).and_raise(StandardError, 'DB error')

      result = described_class.make_helpless!(target, reason: 'unconscious')

      expect(result[:success]).to be false
      expect(result[:error]).to include('DB error')
    end
  end

  describe '.clear_helpless!' do
    before do
      target.update(is_helpless: true, helpless_reason: 'unconscious')
    end

    context 'when character is still unconscious' do
      before do
        target.update(status: 'unconscious')
      end

      it 'returns error' do
        result = described_class.clear_helpless!(target)

        expect(result[:success]).to be false
        expect(result[:error]).to include('still unconscious')
      end
    end

    context 'when hands are still bound' do
      before do
        target.update(status: 'alive')
        allow(target).to receive(:hands_bound?).and_return(true)
      end

      it 'keeps helpless with bound_hands reason' do
        result = described_class.clear_helpless!(target)

        expect(result[:success]).to be false
        expect(result[:error]).to include('still bound')
      end
    end

    context 'when no longer needs to be helpless' do
      before do
        target.update(status: 'alive')
        allow(target).to receive(:unconscious?).and_return(false)
        allow(target).to receive(:hands_bound?).and_return(false)
      end

      it 'clears helpless state' do
        result = described_class.clear_helpless!(target)

        expect(result[:success]).to be true
        target.reload
        expect(target.is_helpless).to be false
        expect(target.helpless_reason).to be_nil
      end
    end
  end

  describe '.can_restrain?' do
    it 'returns true if target is helpless' do
      target.update(is_helpless: true)

      expect(described_class.can_restrain?(target)).to be true
    end

    it 'returns false if target is not helpless' do
      target.update(is_helpless: false)

      expect(described_class.can_restrain?(target)).to be false
    end
  end

  describe '.can_manipulate?' do
    context 'when target is helpless and in same room' do
      before do
        target.update(is_helpless: true)
      end

      it 'returns true' do
        expect(described_class.can_manipulate?(actor, target)).to be true
      end
    end

    context 'when target is not helpless' do
      before do
        target.update(is_helpless: false)
      end

      it 'returns false' do
        expect(described_class.can_manipulate?(actor, target)).to be false
      end
    end

    context 'when actor is in different room' do
      before do
        target.update(is_helpless: true)
        other_room = create(:room)
        actor.update(current_room_id: other_room.id)
      end

      it 'returns false' do
        expect(described_class.can_manipulate?(actor, target)).to be false
      end
    end

    context 'when trying to manipulate self' do
      it 'returns false' do
        actor.update(is_helpless: true)
        expect(described_class.can_manipulate?(actor, actor)).to be false
      end
    end
  end

  describe '.process_knockout!' do
    it 'sets character to unconscious and helpless' do
      result = described_class.process_knockout!(target)

      expect(result[:success]).to be true
      target.reload
      expect(target.status).to eq('unconscious')
      expect(target.is_helpless).to be true
      expect(target.helpless_reason).to eq('unconscious')
      expect(target.stance).to eq('lying')
    end

    it 'sets wake timers' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      described_class.process_knockout!(target)

      target.reload
      expect(target.knocked_out_at).to be_within(1).of(freeze_time)
      expect(target.can_wake_at).to be_within(1).of(freeze_time + PrisonerService::WAKE_DELAY_SECONDS)
      expect(target.auto_wake_at).to be_within(1).of(freeze_time + PrisonerService::AUTO_WAKE_SECONDS)
    end

    it 'clears following' do
      target.update(following_id: actor.id)

      described_class.process_knockout!(target)

      target.reload
      expect(target.following_id).to be_nil
    end
  end

  describe '.process_surrender!' do
    it 'sets character as helpless but alive' do
      result = described_class.process_surrender!(target)

      expect(result[:success]).to be true
      target.reload
      expect(target.status).to eq('alive')
      expect(target.is_helpless).to be true
      expect(target.helpless_reason).to eq('surrendered')
      expect(target.stance).to eq('sitting')
    end

    it 'returns error when no character instance' do
      result = described_class.process_surrender!(nil)

      expect(result[:success]).to be false
      expect(result[:error]).to include('No character instance')
    end
  end

  describe '.reset_wake_timers!' do
    context 'when character is unconscious' do
      before do
        target.update(status: 'unconscious')
      end

      it 'resets wake timers' do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        result = described_class.reset_wake_timers!(target)

        expect(result[:success]).to be true
        target.reload
        expect(target.can_wake_at).to be_within(1).of(freeze_time + PrisonerService::WAKE_DELAY_SECONDS)
        expect(target.auto_wake_at).to be_within(1).of(freeze_time + PrisonerService::AUTO_WAKE_SECONDS)
      end
    end

    context 'when character is not unconscious' do
      before do
        target.update(status: 'alive')
      end

      it 'returns error' do
        result = described_class.reset_wake_timers!(target)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Not unconscious')
      end
    end
  end

  describe '.wake!' do
    before do
      target.update(
        status: 'unconscious',
        is_helpless: true,
        helpless_reason: 'unconscious',
        knocked_out_at: Time.now - 120,
        can_wake_at: Time.now - 60,
        auto_wake_at: Time.now + 500
      )
    end

    context 'when target is not unconscious' do
      before do
        target.update(status: 'alive')
      end

      it 'returns error' do
        result = described_class.wake!(target)

        expect(result[:success]).to be false
        expect(result[:error]).to include('not unconscious')
      end
    end

    context 'when target can be woken' do
      before do
        allow(target).to receive(:unconscious?).and_return(true)
        allow(target).to receive(:can_wake?).and_return(true)
        allow(target).to receive(:hands_bound?).and_return(false)
        allow(described_class).to receive(:in_active_combat?).and_return(false)
      end

      it 'wakes up the character' do
        result = described_class.wake!(target, waker: actor)

        expect(result[:success]).to be true
        expect(result[:waker]).to eq(actor)
      end
    end
  end

  describe '.can_be_woken?' do
    it 'returns true when unconscious and can wake' do
      allow(target).to receive(:unconscious?).and_return(true)
      allow(target).to receive(:can_wake?).and_return(true)

      expect(described_class.can_be_woken?(target)).to be true
    end

    it 'returns false when not unconscious' do
      allow(target).to receive(:unconscious?).and_return(false)

      expect(described_class.can_be_woken?(target)).to be false
    end

    it 'returns false when cannot wake yet' do
      allow(target).to receive(:unconscious?).and_return(true)
      allow(target).to receive(:can_wake?).and_return(false)

      expect(described_class.can_be_woken?(target)).to be false
    end
  end

  describe '.in_active_combat?' do
    it 'returns false when no knockout participants' do
      expect(described_class.in_active_combat?(target)).to be false
    end
  end

  describe '.apply_restraint!' do
    before do
      target.update(is_helpless: true)
    end

    context 'when cannot manipulate target' do
      before do
        target.update(is_helpless: false)
      end

      it 'returns error' do
        result = described_class.apply_restraint!(target, 'hands', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('only restrain helpless')
      end
    end
  end

  describe '.remove_restraint!' do
    context 'when target hands are not bound' do
      it 'returns error' do
        target.update(hands_bound: false)
        result = described_class.remove_restraint!(target, 'hands', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('hands are not bound')
      end
    end

    context 'when trying to untie self' do
      it 'returns error' do
        actor.update(hands_bound: true)
        result = described_class.remove_restraint!(actor, 'hands', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include("can't untie yourself")
      end
    end

    context 'when target hands are bound' do
      before do
        target.update(hands_bound: true, is_helpless: true)
      end

      it 'removes hand restraint' do
        result = described_class.remove_restraint!(target, 'hands', actor: actor)

        expect(result[:success]).to be true
        target.reload
        expect(target.hands_bound).to be false
      end
    end
  end

  describe '.search_inventory' do
    context 'when target is helpless' do
      before do
        target.update(is_helpless: true)
      end

      it 'returns inventory data' do
        result = described_class.search_inventory(actor, target)

        expect(result[:success]).to be true
        expect(result).to have_key(:items)
        expect(result).to have_key(:worn)
        expect(result).to have_key(:money)
      end
    end

    context 'when target is not helpless' do
      before do
        target.update(is_helpless: false)
      end

      it 'returns error when cannot manipulate' do
        result = described_class.search_inventory(actor, target)

        expect(result[:success]).to be false
        expect(result[:error]).to include('helpless')
      end
    end

    context 'when actor is in different room' do
      before do
        target.update(is_helpless: true)
        other_room = create(:room)
        actor.update(current_room_id: other_room.id)
      end

      it 'returns error' do
        result = described_class.search_inventory(actor, target)

        expect(result[:success]).to be false
        expect(result[:error]).to include('same room')
      end
    end
  end

  describe '.apply_restraint!' do
    before do
      target.update(is_helpless: true)
    end

    context 'when cannot manipulate target' do
      before do
        target.update(is_helpless: false)
      end

      it 'returns error' do
        result = described_class.apply_restraint!(target, 'hands', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('only restrain helpless')
      end
    end

    context 'with feet restraint' do
      it 'binds feet' do
        result = described_class.apply_restraint!(target, 'feet', actor: actor)

        expect(result[:success]).to be true
        expect(result[:restraint_type]).to eq('feet')
        target.reload
        expect(target.feet_bound).to be true
      end

      it 'returns error if already bound' do
        target.update(feet_bound: true)
        result = described_class.apply_restraint!(target, 'feet', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('already bound')
      end
    end

    context 'with gag restraint' do
      it 'applies gag' do
        result = described_class.apply_restraint!(target, 'gag', actor: actor)

        expect(result[:success]).to be true
        target.reload
        expect(target.is_gagged).to be true
      end

      it 'returns error if already gagged' do
        target.update(is_gagged: true)
        result = described_class.apply_restraint!(target, 'gag', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('already gagged')
      end
    end

    context 'with blindfold restraint' do
      it 'applies blindfold' do
        result = described_class.apply_restraint!(target, 'blindfold', actor: actor)

        expect(result[:success]).to be true
        target.reload
        expect(target.is_blindfolded).to be true
      end

      it 'returns error if already blindfolded' do
        target.update(is_blindfolded: true)
        result = described_class.apply_restraint!(target, 'blindfold', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('already blindfolded')
      end
    end

    context 'with unknown restraint type' do
      it 'returns error' do
        result = described_class.apply_restraint!(target, 'unknown', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown restraint type')
      end
    end
  end

  describe '.remove_restraint!' do
    context 'when target feet are bound' do
      before do
        target.update(feet_bound: true, is_helpless: true)
      end

      it 'removes feet restraint' do
        result = described_class.remove_restraint!(target, 'feet', actor: actor)

        expect(result[:success]).to be true
        expect(result[:removed]).to include('feet')
        target.reload
        expect(target.feet_bound).to be false
      end
    end

    context 'when target is gagged' do
      before do
        target.update(is_gagged: true, is_helpless: true)
      end

      it 'removes gag' do
        result = described_class.remove_restraint!(target, 'gag', actor: actor)

        expect(result[:success]).to be true
        expect(result[:removed]).to include('gag')
        target.reload
        expect(target.is_gagged).to be false
      end
    end

    context 'when target is blindfolded' do
      before do
        target.update(is_blindfolded: true, is_helpless: true)
      end

      it 'removes blindfold' do
        result = described_class.remove_restraint!(target, 'blindfold', actor: actor)

        expect(result[:success]).to be true
        expect(result[:removed]).to include('blindfold')
        target.reload
        expect(target.is_blindfolded).to be false
      end
    end

    context 'with "all" restraint type' do
      before do
        target.update(
          hands_bound: true,
          feet_bound: true,
          is_gagged: true,
          is_blindfolded: true,
          is_helpless: true
        )
      end

      it 'removes all restraints' do
        result = described_class.remove_restraint!(target, 'all', actor: actor)

        expect(result[:success]).to be true
        expect(result[:removed]).to include('hands', 'feet', 'gag', 'blindfold')
        target.reload
        expect(target.hands_bound).to be false
        expect(target.feet_bound).to be false
        expect(target.is_gagged).to be false
        expect(target.is_blindfolded).to be false
      end

      it 'returns error when no restraints to remove' do
        target.update(hands_bound: false, feet_bound: false, is_gagged: false, is_blindfolded: false)
        result = described_class.remove_restraint!(target, 'all', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('no restraints to remove')
      end
    end

    context 'with unknown restraint type' do
      it 'returns error' do
        result = described_class.remove_restraint!(target, 'unknown', actor: actor)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown restraint type')
      end
    end
  end

  describe '.start_drag!' do
    before do
      target.update(is_helpless: true)
    end

    it 'starts dragging helpless character' do
      result = described_class.start_drag!(actor, target)

      expect(result[:success]).to be true
      target.reload
      expect(target.being_dragged_by_id).to eq(actor.id)
    end

    it 'returns error when target is not helpless' do
      target.update(is_helpless: false)

      result = described_class.start_drag!(actor, target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('only drag helpless')
    end

    it 'returns error when already being moved' do
      other_actor = create(:character_instance, current_room: room, reality: reality)
      target.update(being_dragged_by_id: other_actor.id)

      result = described_class.start_drag!(actor, target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('already being moved')
    end

    it 'returns error when actor is already moving someone' do
      other_target = create(:character_instance, current_room: room, reality: reality, is_helpless: true, being_dragged_by_id: actor.id)

      result = described_class.start_drag!(actor, target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('already moving someone')
    end
  end

  describe '.stop_drag!' do
    it 'releases dragged prisoner' do
      target.update(being_dragged_by_id: actor.id)

      result = described_class.stop_drag!(actor)

      expect(result[:success]).to be true
      expect(result[:released].id).to eq(target.id)
      target.reload
      expect(target.being_dragged_by_id).to be_nil
    end

    it 'returns error when not dragging anyone' do
      result = described_class.stop_drag!(actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not dragging anyone')
    end
  end

  describe '.pick_up!' do
    before do
      target.update(is_helpless: true)
    end

    it 'picks up helpless character' do
      result = described_class.pick_up!(actor, target)

      expect(result[:success]).to be true
      target.reload
      expect(target.being_carried_by_id).to eq(actor.id)
    end

    it 'returns error when target is not helpless' do
      target.update(is_helpless: false)

      result = described_class.pick_up!(actor, target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('only carry helpless')
    end

    it 'clears previous drag state when picking up' do
      target.update(being_dragged_by_id: actor.id)

      result = described_class.pick_up!(actor, target)

      expect(result[:success]).to be true
      target.reload
      expect(target.being_dragged_by_id).to be_nil
      expect(target.being_carried_by_id).to eq(actor.id)
    end
  end

  describe '.put_down!' do
    it 'puts down carried prisoner' do
      target.update(being_carried_by_id: actor.id)

      result = described_class.put_down!(actor)

      expect(result[:success]).to be true
      expect(result[:released].id).to eq(target.id)
      target.reload
      expect(target.being_carried_by_id).to be_nil
    end

    it 'returns error when not carrying anyone' do
      result = described_class.put_down!(actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not carrying anyone')
    end
  end

  describe '.movement_speed_modifier' do
    it 'returns normal speed when not moving anyone' do
      expect(described_class.movement_speed_modifier(actor)).to eq(1.0)
    end

    it 'returns slower speed when dragging someone' do
      target.update(being_dragged_by_id: actor.id)

      expect(described_class.movement_speed_modifier(actor)).to eq(PrisonerService::DRAG_SPEED_MODIFIER)
    end

    it 'returns slower speed when carrying someone' do
      target.update(being_carried_by_id: actor.id)

      expect(described_class.movement_speed_modifier(actor)).to eq(PrisonerService::DRAG_SPEED_MODIFIER)
    end
  end

  describe '.move_prisoners!' do
    let(:new_room) { create(:room) }

    before do
      target.update(being_dragged_by_id: actor.id, is_helpless: true)
    end

    it 'moves prisoners to new room' do
      result = described_class.move_prisoners!(actor, new_room)

      expect(result).to include(target)
      target.reload
      expect(target.current_room_id).to eq(new_room.id)
    end

    it 'returns empty array when no prisoners' do
      target.update(being_dragged_by_id: nil)

      result = described_class.move_prisoners!(actor, new_room)

      expect(result).to be_empty
    end
  end

  describe '.can_speak?' do
    it 'returns true when not gagged' do
      target.update(is_gagged: false)

      expect(described_class.can_speak?(target)).to be true
    end

    it 'returns false when gagged' do
      target.update(is_gagged: true)

      expect(described_class.can_speak?(target)).to be false
    end
  end

  describe '.can_see?' do
    it 'returns true when not blindfolded' do
      target.update(is_blindfolded: false)

      expect(described_class.can_see?(target)).to be true
    end

    it 'returns false when blindfolded' do
      target.update(is_blindfolded: true)

      expect(described_class.can_see?(target)).to be false
    end
  end

  describe '.can_move_independently?' do
    it 'delegates to character instance' do
      allow(target).to receive(:can_move_independently?).and_return(true)

      expect(described_class.can_move_independently?(target)).to be true
    end
  end

  describe '.blindfolded_room_description' do
    it 'describes empty room' do
      result = described_class.blindfolded_room_description(target, room)

      expect(result).to include("can't see anything")
      expect(result).to include('quiet and empty')
    end

    it 'describes room with one person' do
      create(:character_instance, current_room: room, reality: reality, online: true)

      result = described_class.blindfolded_room_description(target, room)

      expect(result).to include('hear someone nearby')
    end

    it 'describes room with multiple people' do
      3.times { create(:character_instance, current_room: room, reality: reality, online: true) }

      result = described_class.blindfolded_room_description(target, room)

      expect(result).to include('hear')
      expect(result).to include('people nearby')
    end
  end

  describe '.toggle_helpless!' do
    it 'enables helpless state' do
      result = described_class.toggle_helpless!(target, enable: true)

      expect(result[:success]).to be true
      expect(result[:enabled]).to be true
      target.reload
      expect(target.is_helpless).to be true
      expect(target.helpless_reason).to eq('voluntary')
    end

    it 'disables helpless state' do
      target.update(is_helpless: true, helpless_reason: 'voluntary')

      result = described_class.toggle_helpless!(target, enable: false)

      expect(result[:success]).to be true
      expect(result[:enabled]).to be false
      target.reload
      expect(target.is_helpless).to be false
    end

    it 'toggles current state when enable is nil' do
      target.update(is_helpless: false)

      result = described_class.toggle_helpless!(target)

      expect(result[:enabled]).to be true
    end

    it 'returns error when unconscious' do
      target.update(status: 'unconscious')

      result = described_class.toggle_helpless!(target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('while unconscious')
    end

    it 'returns error when hands are bound' do
      target.update(hands_bound: true)

      result = described_class.toggle_helpless!(target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('hands are bound')
    end
  end

  describe '.process_auto_wakes!' do
    before do
      target.update(
        status: 'unconscious',
        is_helpless: true,
        helpless_reason: 'unconscious',
        knocked_out_at: Time.now - 700,
        can_wake_at: Time.now - 640,
        auto_wake_at: Time.now - 100
      )
      allow(BroadcastService).to receive(:to_character)
      allow(BroadcastService).to receive(:to_room)
    end

    it 'wakes up characters past auto-wake time' do
      result = described_class.process_auto_wakes!

      expect(result[:woken]).to eq(1)
      target.reload
      expect(target.status).to eq('alive')
    end

    it 'skips characters in active combat' do
      allow(described_class).to receive(:in_active_combat?).and_return(true)

      result = described_class.process_auto_wakes!

      expect(result[:skipped_combat]).to eq(1)
      expect(result[:woken]).to eq(0)
    end

    it 'broadcasts wake notification' do
      expect(BroadcastService).to receive(:to_character).at_least(:once)

      described_class.process_auto_wakes!
    end
  end

  describe 'constants' do
    it 'has WAKE_DELAY_SECONDS defined' do
      expect(PrisonerService::WAKE_DELAY_SECONDS).to eq(60)
    end

    it 'has AUTO_WAKE_SECONDS defined' do
      expect(PrisonerService::AUTO_WAKE_SECONDS).to eq(600)
    end

    it 'has DRAG_SPEED_MODIFIER defined' do
      expect(PrisonerService::DRAG_SPEED_MODIFIER).to eq(1.5)
    end
  end

  # ============================================
  # Edge Case Tests for Increased Coverage
  # ============================================

  describe '.in_active_combat? (edge cases)' do
    it 'returns true when participant is knocked out in ongoing fight' do
      fight = double('fight', ongoing?: true)
      participant = double('participant', fight: fight)
      allow(FightParticipant).to receive_message_chain(:where, :eager, :all).and_return([participant])

      expect(described_class.in_active_combat?(target)).to be true
    end

    it 'returns false when participant is knocked out but fight ended' do
      fight = double('fight', ongoing?: false)
      participant = double('participant', fight: fight)
      allow(FightParticipant).to receive_message_chain(:where, :eager, :all).and_return([participant])

      expect(described_class.in_active_combat?(target)).to be false
    end

    it 'returns false when no knocked out participants found' do
      allow(FightParticipant).to receive_message_chain(:where, :eager, :all).and_return([])

      expect(described_class.in_active_combat?(target)).to be false
    end

    it 'returns false when fight is nil' do
      participant = double('participant', fight: nil)
      allow(FightParticipant).to receive_message_chain(:where, :eager, :all).and_return([participant])

      expect(described_class.in_active_combat?(target)).to be false
    end
  end

  describe '.wake! (edge cases)' do
    before do
      target.update(
        status: 'unconscious',
        is_helpless: true,
        helpless_reason: 'unconscious',
        knocked_out_at: Time.now - 120,
        can_wake_at: Time.now - 60,
        auto_wake_at: Time.now + 500
      )
    end

    it 'returns error when in active combat' do
      allow(described_class).to receive(:in_active_combat?).with(target).and_return(true)

      result = described_class.wake!(target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('combat is still ongoing')
    end

    it 'returns error when cannot wake yet' do
      target.update(can_wake_at: Time.now + 60)
      allow(target).to receive(:can_wake?).and_return(false)
      allow(target).to receive(:seconds_until_wakeable).and_return(30)
      allow(described_class).to receive(:in_active_combat?).and_return(false)

      result = described_class.wake!(target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('cannot be woken yet')
    end

    it 'keeps helpless with bound_hands reason when hands are bound after waking' do
      target.update(hands_bound: true)
      allow(described_class).to receive(:in_active_combat?).and_return(false)

      result = described_class.wake!(target)

      expect(result[:success]).to be true
      target.reload
      expect(target.status).to eq('alive')
      expect(target.is_helpless).to be true
      expect(target.helpless_reason).to eq('bound_hands')
    end

    it 'handles StandardError gracefully' do
      allow(described_class).to receive(:in_active_combat?).and_return(false)
      allow(target).to receive(:update).and_raise(StandardError, 'DB connection lost')

      result = described_class.wake!(target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('DB connection lost')
    end
  end

  describe '.process_auto_wakes! (edge cases)' do
    before do
      allow(BroadcastService).to receive(:to_character)
      allow(BroadcastService).to receive(:to_room)
    end

    it 'handles multiple characters needing wake' do
      target.update(
        status: 'unconscious',
        is_helpless: true,
        helpless_reason: 'unconscious',
        knocked_out_at: Time.now - 700,
        can_wake_at: Time.now - 640,
        auto_wake_at: Time.now - 100
      )

      other_char = create(:character_instance, reality: reality, current_room: room,
                          status: 'unconscious', is_helpless: true, helpless_reason: 'unconscious',
                          knocked_out_at: Time.now - 700, can_wake_at: Time.now - 640, auto_wake_at: Time.now - 100)

      result = described_class.process_auto_wakes!

      expect(result[:woken]).to eq(2)
    end

    it 'records errors when wake fails' do
      target.update(
        status: 'unconscious',
        is_helpless: true,
        helpless_reason: 'unconscious',
        knocked_out_at: Time.now - 700,
        can_wake_at: Time.now - 640,
        auto_wake_at: Time.now - 100
      )
      allow(described_class).to receive(:wake!).and_return({ success: false, error: 'Test error' })

      result = described_class.process_auto_wakes!

      expect(result[:errors]).not_to be_empty
      expect(result[:errors].first[:error]).to eq('Test error')
    end
  end

  describe '.take_item!' do
    let(:item) { create(:item, character_instance: target, worn: false) }

    before do
      target.update(is_helpless: true)
    end

    it 'transfers item from target to actor' do
      result = described_class.take_item!(actor, target, item)

      expect(result[:success]).to be true
      expect(result[:item]).to eq(item)
      item.reload
      expect(item.character_instance_id).to eq(actor.id)
    end

    it 'removes worn item before transferring' do
      item.update(worn: true)

      result = described_class.take_item!(actor, target, item)

      expect(result[:success]).to be true
      item.reload
      expect(item.worn).to be false
      expect(item.character_instance_id).to eq(actor.id)
    end

    it 'returns error when cannot manipulate target' do
      target.update(is_helpless: false)

      result = described_class.take_item!(actor, target, item)

      expect(result[:success]).to be false
      expect(result[:error]).to include('helpless')
    end

    it 'returns error when target does not have item' do
      other_item = create(:item, character_instance: actor)

      result = described_class.take_item!(actor, target, other_item)

      expect(result[:success]).to be false
      expect(result[:error]).to include("doesn't have that item")
    end

    it 'returns error when actor is in different room' do
      other_room = create(:room)
      actor.update(current_room_id: other_room.id)

      result = described_class.take_item!(actor, target, item)

      expect(result[:success]).to be false
      expect(result[:error]).to include('same room')
    end

    it 'handles errors gracefully' do
      allow(item).to receive(:move_to_character).and_raise(StandardError, 'Transfer failed')

      result = described_class.take_item!(actor, target, item)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Transfer failed')
    end
  end

  describe '.dress_item!' do
    let(:clothing) { create(:item, character_instance: actor, worn: false) }

    before do
      target.update(is_helpless: true)
      allow(clothing).to receive(:clothing?).and_return(true)
      allow(clothing).to receive(:jewelry?).and_return(false)
      allow(clothing).to receive(:piercing?).and_return(false)
    end

    it 'transfers clothing and wears it on target' do
      allow(clothing).to receive(:move_to_character)
      allow(clothing).to receive(:wear!).and_return(true)

      result = described_class.dress_item!(actor, target, clothing)

      expect(result[:success]).to be true
      expect(result[:item]).to eq(clothing)
    end

    it 'returns error when cannot manipulate target' do
      target.update(is_helpless: false)

      result = described_class.dress_item!(actor, target, clothing)

      expect(result[:success]).to be false
      expect(result[:error]).to include('helpless')
    end

    it 'returns error when actor does not have item' do
      target_item = create(:item, character_instance: target)

      result = described_class.dress_item!(actor, target, target_item)

      expect(result[:success]).to be false
      expect(result[:error]).to include("don't have that item")
    end

    it 'returns error when item is not wearable' do
      allow(clothing).to receive(:clothing?).and_return(false)
      allow(clothing).to receive(:jewelry?).and_return(false)

      result = described_class.dress_item!(actor, target, clothing)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not wearable')
    end

    it 'returns error when item is a piercing' do
      allow(clothing).to receive(:clothing?).and_return(true)
      allow(clothing).to receive(:piercing?).and_return(true)

      result = described_class.dress_item!(actor, target, clothing)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Piercings cannot be put on')
    end

    it 'allows jewelry to be dressed' do
      allow(clothing).to receive(:clothing?).and_return(false)
      allow(clothing).to receive(:jewelry?).and_return(true)
      allow(clothing).to receive(:move_to_character)
      allow(clothing).to receive(:wear!).and_return(true)

      result = described_class.dress_item!(actor, target, clothing)

      expect(result[:success]).to be true
    end

    it 'returns error when wear! fails' do
      allow(clothing).to receive(:move_to_character)
      allow(clothing).to receive(:wear!).and_return('Body slot is already occupied.')

      result = described_class.dress_item!(actor, target, clothing)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Body slot is already occupied')
    end

    it 'handles errors gracefully' do
      allow(clothing).to receive(:move_to_character).and_raise(StandardError, 'DB error')

      result = described_class.dress_item!(actor, target, clothing)

      expect(result[:success]).to be false
      expect(result[:error]).to include('DB error')
    end
  end

  describe '.undress_item!' do
    before do
      target.update(is_helpless: true)
    end

    it 'removes specific worn item' do
      worn_item = double('worn_item', character_instance_id: target.id, worn?: true)
      allow(worn_item).to receive(:remove!)

      result = described_class.undress_item!(actor, target, worn_item)

      expect(result[:success]).to be true
      expect(result[:removed]).to include(worn_item)
    end

    it 'removes all worn items when no item specified' do
      worn_item = double('worn_item1')
      worn_item2 = double('worn_item2')
      allow(target).to receive(:worn_items).and_return([worn_item, worn_item2])
      allow(worn_item).to receive(:remove!)
      allow(worn_item2).to receive(:remove!)

      result = described_class.undress_item!(actor, target, nil)

      expect(result[:success]).to be true
      expect(result[:removed]).to include(worn_item, worn_item2)
    end

    it 'returns error when cannot manipulate target' do
      target.update(is_helpless: false)
      worn_item = double('worn_item')

      result = described_class.undress_item!(actor, target, worn_item)

      expect(result[:success]).to be false
      expect(result[:error]).to include('helpless')
    end

    it 'returns error when target is not wearing item' do
      not_worn = double('not_worn', character_instance_id: target.id, worn?: false)

      result = described_class.undress_item!(actor, target, not_worn)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not wearing that')
    end

    it 'returns error when item belongs to different character' do
      actor_item = double('actor_item', character_instance_id: actor.id, worn?: true)

      result = described_class.undress_item!(actor, target, actor_item)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not wearing that')
    end

    it 'handles errors gracefully' do
      worn_item = double('worn_item', character_instance_id: target.id, worn?: true)
      allow(worn_item).to receive(:remove!).and_raise(StandardError, 'Remove failed')

      result = described_class.undress_item!(actor, target, worn_item)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Remove failed')
    end
  end

  describe '.search_inventory (with items)' do
    before do
      target.update(is_helpless: true)
    end

    it 'returns inventory items with details' do
      item1 = double('item1', id: 1, name: 'Sword', quantity: 1)
      item2 = double('item2', id: 2, name: 'Shield', quantity: 1)
      allow(target).to receive(:inventory_items).and_return([item1, item2])
      allow(target).to receive(:worn_items).and_return([])
      allow(target).to receive(:wallets).and_return([])

      result = described_class.search_inventory(actor, target)

      expect(result[:success]).to be true
      expect(result[:items].length).to eq(2)
      expect(result[:items].map { |i| i[:name] }).to include('Sword', 'Shield')
    end

    it 'returns worn items separately' do
      worn_item = double('worn_item', id: 1, name: 'Armor')
      allow(target).to receive(:inventory_items).and_return([])
      allow(target).to receive(:worn_items).and_return([worn_item])
      allow(target).to receive(:wallets).and_return([])

      result = described_class.search_inventory(actor, target)

      expect(result[:success]).to be true
      expect(result[:worn].map { |i| i[:name] }).to include('Armor')
    end

    it 'returns wallet balances' do
      currency = double('currency', code: 'USD')
      wallet = double('wallet', currency: currency, amount: 100)
      allow(target).to receive(:inventory_items).and_return([])
      allow(target).to receive(:worn_items).and_return([])
      allow(target).to receive(:wallets).and_return([wallet])

      result = described_class.search_inventory(actor, target)

      expect(result[:success]).to be true
      expect(result[:money]['USD']).to eq(100)
    end
  end

  describe '.apply_restraint! (edge cases)' do
    it 'binds hands and makes target helpless if not already' do
      # Create mock target that can be manipulated
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           helpless?: true,
                           hands_bound?: false,
                           current_room_id: room.id,
                           character: mock_char)
      allow(mock_target).to receive(:update)

      result = described_class.apply_restraint!(mock_target, 'hands', actor: actor)

      expect(result[:success]).to be true
    end

    it 'handles mixed case restraint types' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           helpless?: true,
                           hands_bound?: false,
                           current_room_id: room.id,
                           character: mock_char)
      allow(mock_target).to receive(:update)

      result = described_class.apply_restraint!(mock_target, 'HANDS', actor: actor)

      expect(result[:success]).to be true
    end

    it 'handles StandardError gracefully' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           helpless?: true,
                           hands_bound?: false,
                           current_room_id: room.id,
                           character: mock_char)
      allow(mock_target).to receive(:update).and_raise(StandardError, 'DB locked')

      result = described_class.apply_restraint!(mock_target, 'hands', actor: actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('DB locked')
    end
  end

  describe '.remove_restraint! (edge cases)' do
    it 'returns error when actor is in different room' do
      mock_actor = double('actor', id: actor.id, current_room_id: 999)
      mock_target = double('target', id: target.id + 100, current_room_id: room.id, hands_bound?: true)

      result = described_class.remove_restraint!(mock_target, 'hands', actor: mock_actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('must be in the same room')
    end

    it 'clears helpless state after unbinding hands on conscious target' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           current_room_id: room.id,
                           hands_bound?: true,
                           character: mock_char,
                           unconscious?: false)
      allow(mock_target).to receive(:update)
      allow(described_class).to receive(:clear_helpless!).with(mock_target).and_return({ success: true })

      result = described_class.remove_restraint!(mock_target, 'hands', actor: actor)

      expect(result[:success]).to be true
      expect(result[:removed]).to include('hands')
    end

    it 'keeps helpless if still unconscious after unbinding hands' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           current_room_id: room.id,
                           hands_bound?: true,
                           character: mock_char,
                           unconscious?: true)
      allow(mock_target).to receive(:update)

      result = described_class.remove_restraint!(mock_target, 'hands', actor: actor)

      expect(result[:success]).to be true
      expect(result[:removed]).to include('hands')
      # clear_helpless! is not called because unconscious? returns true
    end

    it 'handles StandardError gracefully' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           current_room_id: room.id,
                           hands_bound?: true,
                           character: mock_char)
      allow(mock_target).to receive(:update).and_raise(StandardError, 'Connection error')

      result = described_class.remove_restraint!(mock_target, 'hands', actor: actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Connection error')
    end

    it 'returns error for feet not bound' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           current_room_id: room.id,
                           feet_bound?: false,
                           character: mock_char)

      result = described_class.remove_restraint!(mock_target, 'feet', actor: actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('feet are not bound')
    end

    it 'returns error for gag not applied' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           current_room_id: room.id,
                           gagged?: false,
                           character: mock_char)

      result = described_class.remove_restraint!(mock_target, 'gag', actor: actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not gagged')
    end

    it 'returns error for blindfold not applied' do
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           current_room_id: room.id,
                           blindfolded?: false,
                           character: mock_char)

      result = described_class.remove_restraint!(mock_target, 'blindfold', actor: actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not blindfolded')
    end
  end

  describe '.start_drag! (edge cases)' do
    it 'handles StandardError gracefully' do
      mock_target = double('target',
                           id: target.id + 100,
                           helpless?: true,
                           being_moved?: false,
                           current_room_id: room.id)
      mock_actor = double('actor',
                          id: actor.id,
                          dragging_someone?: false,
                          carrying_someone?: false,
                          current_room_id: room.id)
      allow(mock_target).to receive(:update).and_raise(StandardError, 'DB write failed')

      result = described_class.start_drag!(mock_actor, mock_target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('DB write failed')
    end
  end

  describe '.stop_drag! (edge cases)' do
    it 'handles StandardError gracefully' do
      mock_prisoner = double('prisoner', id: target.id + 100)
      allow(CharacterInstance).to receive(:first).with(being_dragged_by_id: actor.id).and_return(mock_prisoner)
      allow(mock_prisoner).to receive(:update).and_raise(StandardError, 'Update failed')

      result = described_class.stop_drag!(actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Update failed')
    end
  end

  describe '.pick_up! (edge cases)' do
    it 'returns error when being moved by someone else' do
      captor = double('captor', id: 999)
      mock_char = double('character', display_name_for: 'Test Target')
      mock_target = double('target',
                           id: target.id + 100,
                           helpless?: true,
                           being_moved?: true,
                           captor: captor,
                           being_dragged_by_id: nil,
                           current_room_id: room.id,
                           character: mock_char)

      result = described_class.pick_up!(actor, mock_target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('already being moved')
    end

    it 'allows picking up own dragged target' do
      mock_target = double('target',
                           id: target.id + 100,
                           helpless?: true,
                           being_moved?: true,
                           captor: double(id: actor.id),
                           being_dragged_by_id: actor.id,
                           current_room_id: room.id)
      allow(mock_target).to receive(:update)

      result = described_class.pick_up!(actor, mock_target)

      expect(result[:success]).to be true
    end

    it 'handles StandardError gracefully' do
      mock_target = double('target',
                           id: target.id + 100,
                           helpless?: true,
                           being_moved?: false,
                           being_dragged_by_id: nil,
                           current_room_id: room.id)
      mock_actor = double('actor',
                          id: actor.id,
                          dragging_someone?: false,
                          carrying_someone?: false,
                          current_room_id: room.id)
      allow(mock_target).to receive(:update).and_raise(StandardError, 'Pick up failed')

      result = described_class.pick_up!(mock_actor, mock_target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Pick up failed')
    end
  end

  describe '.put_down! (edge cases)' do
    it 'handles StandardError gracefully' do
      mock_prisoner = double('prisoner', id: target.id + 100)
      allow(CharacterInstance).to receive(:first).with(being_carried_by_id: actor.id).and_return(mock_prisoner)
      allow(mock_prisoner).to receive(:update).and_raise(StandardError, 'Put down failed')

      result = described_class.put_down!(actor)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Put down failed')
    end
  end

  describe '.reset_wake_timers! (edge cases)' do
    it 'handles StandardError gracefully' do
      mock_target = double('target', unconscious?: true)
      allow(mock_target).to receive(:update).and_raise(StandardError, 'Timer reset failed')

      result = described_class.reset_wake_timers!(mock_target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Timer reset failed')
    end
  end

  describe '.process_knockout! (edge cases)' do
    it 'clears observing state' do
      mock_target = double('target')
      expect(mock_target).to receive(:update).with(hash_including(
                                                     observing_id: nil,
                                                     observing_place_id: nil,
                                                     observing_room: false
                                                   ))

      described_class.process_knockout!(mock_target)
    end

    it 'handles StandardError gracefully' do
      mock_target = double('target')
      allow(mock_target).to receive(:update).and_raise(StandardError, 'Knockout failed')

      result = described_class.process_knockout!(mock_target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Knockout failed')
    end
  end

  describe '.process_surrender! (edge cases)' do
    it 'handles StandardError gracefully' do
      mock_target = double('target')
      allow(mock_target).to receive(:update).and_raise(StandardError, 'Surrender failed')

      result = described_class.process_surrender!(mock_target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Surrender failed')
    end
  end

  describe '.clear_helpless! (edge cases)' do
    it 'handles StandardError gracefully' do
      mock_target = double('target',
                           unconscious?: false,
                           hands_bound?: false)
      allow(mock_target).to receive(:update).and_raise(StandardError, 'Clear failed')

      result = described_class.clear_helpless!(mock_target)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Clear failed')
    end
  end
end
