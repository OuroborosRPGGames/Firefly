# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FightEvent do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:fight) { create(:fight, room: room) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }
  let(:participant) { create(:fight_participant, fight: fight, character_instance: character_instance) }

  describe 'associations' do
    it 'belongs to fight' do
      event = create(:fight_event, fight: fight)
      expect(event.fight).to eq(fight)
    end

    it 'belongs to actor_participant' do
      event = create(:fight_event, fight: fight, actor_participant: participant)
      expect(event.actor_participant).to eq(participant)
    end

    it 'belongs to target_participant' do
      event = create(:fight_event, fight: fight, target_participant: participant)
      expect(event.target_participant).to eq(participant)
    end
  end

  describe 'validations' do
    it 'requires fight_id' do
      event = FightEvent.new(round_number: 1, segment: 1, event_type: 'attack')
      expect(event.valid?).to be false
      expect(event.errors[:fight_id]).not_to be_empty
    end

    it 'requires round_number' do
      event = FightEvent.new(fight_id: fight.id, segment: 1, event_type: 'attack')
      expect(event.valid?).to be false
      expect(event.errors[:round_number]).not_to be_empty
    end

    it 'requires segment' do
      event = FightEvent.new(fight_id: fight.id, round_number: 1, event_type: 'attack')
      expect(event.valid?).to be false
      expect(event.errors[:segment]).not_to be_empty
    end

    it 'requires event_type' do
      event = FightEvent.new(fight_id: fight.id, round_number: 1, segment: 1)
      expect(event.valid?).to be false
      expect(event.errors[:event_type]).not_to be_empty
    end

    it 'validates event_type is in allowed list' do
      event = FightEvent.new(fight_id: fight.id, round_number: 1, segment: 1, event_type: 'invalid_type')
      expect(event.valid?).to be false
    end

    it 'validates weapon_type when present' do
      event = FightEvent.new(fight_id: fight.id, round_number: 1, segment: 1, event_type: 'attack', weapon_type: 'invalid')
      expect(event.valid?).to be false
    end

    it 'accepts valid weapon_type' do
      event = create(:fight_event, fight: fight, weapon_type: 'melee')
      expect(event.weapon_type).to eq('melee')
    end
  end

  describe 'constants' do
    it 'defines EVENT_TYPES' do
      expect(FightEvent::EVENT_TYPES).to include('attack', 'hit', 'miss', 'move', 'knockout')
    end

    it 'defines WEAPON_TYPES' do
      expect(FightEvent::WEAPON_TYPES).to eq(%w[melee ranged unarmed natural_melee natural_ranged])
    end
  end

  describe '#details_hash' do
    it 'returns empty hash when details is nil' do
      event = create(:fight_event, fight: fight, details: nil)
      expect(event.details_hash).to eq({})
    end

    it 'returns hash directly when details is already a Hash' do
      details = { 'damage' => 10, 'critical' => true }
      event = FightEvent.new(fight_id: fight.id, round_number: 1, segment: 1, event_type: 'hit')
      allow(event).to receive(:details).and_return(details)
      expect(event.details_hash).to eq(details)
    end

    it 'parses JSON string into hash with symbolized keys' do
      json_details = '{"damage": 10, "critical": true}'
      event = FightEvent.new(fight_id: fight.id, round_number: 1, segment: 1, event_type: 'hit')
      allow(event).to receive(:details).and_return(json_details)
      result = event.details_hash
      expect(result[:damage]).to eq(10)
      expect(result[:critical]).to be true
    end

    it 'returns empty hash for invalid JSON' do
      event = FightEvent.new(fight_id: fight.id, round_number: 1, segment: 1, event_type: 'hit')
      allow(event).to receive(:details).and_return('not valid json{')
      expect(event.details_hash).to eq({})
    end

    it 'returns empty hash for unexpected type' do
      event = FightEvent.new(fight_id: fight.id, round_number: 1, segment: 1, event_type: 'hit')
      allow(event).to receive(:details).and_return(12345)
      expect(event.details_hash).to eq({})
    end
  end

  describe '#actor_name' do
    it 'returns character name when actor_participant is present' do
      event = create(:fight_event, fight: fight, actor_participant: participant)
      expect(event.actor_name).to eq(participant.character_name)
    end

    it 'returns Unknown when actor_participant is nil' do
      event = create(:fight_event, fight: fight, actor_participant: nil)
      expect(event.actor_name).to eq('Unknown')
    end
  end

  describe '#target_name' do
    it 'returns character name when target_participant is present' do
      event = create(:fight_event, fight: fight, target_participant: participant)
      expect(event.target_name).to eq(participant.character_name)
    end

    it 'returns Unknown when target_participant is nil' do
      event = create(:fight_event, fight: fight, target_participant: nil)
      expect(event.target_name).to eq('Unknown')
    end
  end

  describe '#hit?' do
    it 'returns true for hit event' do
      event = create(:fight_event, :hit, fight: fight)
      expect(event.hit?).to be true
    end

    it 'returns false for other events' do
      event = create(:fight_event, :miss, fight: fight)
      expect(event.hit?).to be false
    end
  end

  describe '#miss?' do
    it 'returns true for miss event' do
      event = create(:fight_event, :miss, fight: fight)
      expect(event.miss?).to be true
    end

    it 'returns false for other events' do
      event = create(:fight_event, :hit, fight: fight)
      expect(event.miss?).to be false
    end
  end

  describe '#movement?' do
    it 'returns true for move event' do
      event = create(:fight_event, :move, fight: fight)
      expect(event.movement?).to be true
    end

    it 'returns false for other events' do
      event = create(:fight_event, :hit, fight: fight)
      expect(event.movement?).to be false
    end
  end

  describe '#knockout?' do
    it 'returns true for knockout event' do
      event = create(:fight_event, :knockout, fight: fight)
      expect(event.knockout?).to be true
    end

    it 'returns false for other events' do
      event = create(:fight_event, :hit, fight: fight)
      expect(event.knockout?).to be false
    end
  end

  describe 'event type coverage' do
    FightEvent::EVENT_TYPES.each do |event_type|
      it "accepts event_type '#{event_type}'" do
        event = create(:fight_event, fight: fight, event_type: event_type)
        expect(event.event_type).to eq(event_type)
      end
    end
  end
end
