# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FightEntryDelay do
  let(:room) { create(:room) }
  let(:fight) { Fight.create(room_id: room.id) }
  # Create with online: false to prevent FightEntryDelayService.create_delays_for_character
  # from auto-creating FightEntryDelay records when the character "comes online"
  let(:character_instance) { create(:character_instance, current_room: room, online: false) }

  describe '.calculate_delay_rounds' do
    it 'returns 0 for distance 0' do
      expect(described_class.calculate_delay_rounds(0)).to eq(0)
    end

    it 'returns 0 for distance less than 25' do
      expect(described_class.calculate_delay_rounds(24.9)).to eq(0)
    end

    it 'returns 1 for distance 25' do
      expect(described_class.calculate_delay_rounds(25)).to eq(1)
    end

    it 'returns 1 for distance between 25 and 49' do
      expect(described_class.calculate_delay_rounds(49)).to eq(1)
    end

    it 'returns 2 for distance 50' do
      expect(described_class.calculate_delay_rounds(50)).to eq(2)
    end

    it 'returns 4 for distance 100' do
      expect(described_class.calculate_delay_rounds(100)).to eq(4)
    end

    it 'floors partial rounds' do
      expect(described_class.calculate_delay_rounds(74)).to eq(2)
    end
  end

  describe '#can_enter?' do
    context 'when in fight room at start' do
      it 'returns true regardless of round number' do
        delay = described_class.create(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          distance_at_start: 0.0,
          delay_rounds: 0,
          entry_allowed_at_round: 1,
          in_fight_room: true
        )

        expect(delay.can_enter?).to be true
      end
    end

    context 'when not in fight room' do
      it 'returns false when not enough rounds have passed' do
        delay = described_class.create(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          distance_at_start: 75.0,
          delay_rounds: 3,
          entry_allowed_at_round: 4,
          in_fight_room: false
        )

        # Fight is at round 1, entry allowed at round 4
        expect(delay.can_enter?).to be false
      end

      it 'returns true when enough rounds have passed' do
        delay = described_class.create(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          distance_at_start: 50.0,
          delay_rounds: 2,
          entry_allowed_at_round: 3,
          in_fight_room: false
        )

        # Advance fight to round 3
        fight.update(round_number: 3)

        expect(delay.can_enter?).to be true
      end

      it 'returns true when past the entry round' do
        delay = described_class.create(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          distance_at_start: 25.0,
          delay_rounds: 1,
          entry_allowed_at_round: 2,
          in_fight_room: false
        )

        # Advance fight to round 5
        fight.update(round_number: 5)

        expect(delay.can_enter?).to be true
      end
    end
  end

  describe '#rounds_remaining' do
    it 'returns 0 when can enter' do
      delay = described_class.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        distance_at_start: 0.0,
        delay_rounds: 0,
        entry_allowed_at_round: 1,
        in_fight_room: true
      )

      expect(delay.rounds_remaining).to eq(0)
    end

    it 'returns correct count when blocked' do
      delay = described_class.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        distance_at_start: 100.0,
        delay_rounds: 4,
        entry_allowed_at_round: 5,
        in_fight_room: false
      )

      # Fight at round 1, entry at round 5 = 4 rounds remaining
      expect(delay.rounds_remaining).to eq(4)
    end

    it 'decrements as rounds pass' do
      delay = described_class.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        distance_at_start: 75.0,
        delay_rounds: 3,
        entry_allowed_at_round: 4,
        in_fight_room: false
      )

      expect(delay.rounds_remaining).to eq(3)

      fight.update(round_number: 2)
      delay.refresh  # Reload to clear cached fight association
      expect(delay.rounds_remaining).to eq(2)

      fight.update(round_number: 3)
      delay.refresh
      expect(delay.rounds_remaining).to eq(1)

      fight.update(round_number: 4)
      delay.refresh
      expect(delay.rounds_remaining).to eq(0)
    end
  end

  describe 'validations' do
    it 'requires fight_id' do
      delay = described_class.new(character_instance_id: character_instance.id)
      expect { delay.save }.to raise_error(Sequel::ValidationFailed)
    end

    it 'requires character_instance_id' do
      delay = described_class.new(fight_id: fight.id)
      expect { delay.save }.to raise_error(Sequel::ValidationFailed)
    end

    it 'enforces uniqueness of fight + character pair' do
      described_class.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        distance_at_start: 0.0,
        delay_rounds: 0,
        entry_allowed_at_round: 1,
        in_fight_room: true
      )

      duplicate = described_class.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        distance_at_start: 50.0,
        delay_rounds: 2,
        entry_allowed_at_round: 3,
        in_fight_room: false
      )

      expect { duplicate.save }.to raise_error(Sequel::ValidationFailed)
    end
  end
end
