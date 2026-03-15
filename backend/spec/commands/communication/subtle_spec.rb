# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Subtle do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room }
  let(:place) { create_test_place(room: room, name: 'the bar') }
  let(:character) { create_test_character(forename: 'Bob') }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }

  let(:other_character) { create_test_character(forename: 'Alice') }
  let(:other_instance) { create_test_character_instance(character: other_character, room: room, reality: reality) }

  let(:third_character) { create_test_character(forename: 'Charlie') }
  let(:third_instance) { create_test_character_instance(character: third_character, room: room, reality: reality) }

  subject { described_class.new(character_instance) }

  describe '#execute' do
    context 'without text' do
      it 'returns an error' do
        result = subject.execute('subtle')
        expect(result[:success]).to be false
        expect(result[:error]).to include('What did you want to do subtly')
      end
    end

    context 'with valid text' do
      it 'processes the subtle emote' do
        # Set up other instance for broadcast
        other_instance

        result = subject.execute('subtle slides a note across')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob')
        expect(result[:message]).to include('slides a note across')
      end
    end

    context 'when character is at a place' do
      before do
        character_instance.update(current_place_id: place.id)
        other_instance.update(current_place_id: place.id) # Same place
        third_instance # Different place (nil)
      end

      it 'allows characters at the same place to see the full message' do
        result = subject.execute('subtle slides a note')
        expect(result[:success]).to be true
      end
    end

    context 'when character is not at a place' do
      before do
        other_instance.update(current_place_id: place.id) # At a place
        third_instance # Not at a place
      end

      it 'allows other ungrouped characters to see the full message' do
        result = subject.execute('subtle waves quietly')
        expect(result[:success]).to be true
      end
    end

    context 'rp logging recipients' do
      before do
        character_instance.update(current_place_id: place.id)
        other_instance.update(current_place_id: place.id) # Same place: should be logged
        third_instance.update(current_place_id: nil)      # Different grouping: should not be logged
      end

      it 'logs only for sender and full recipients' do
        before_sender = RpLog.where(character_instance_id: character_instance.id).count
        before_other = RpLog.where(character_instance_id: other_instance.id).count
        before_third = RpLog.where(character_instance_id: third_instance.id).count

        result = subject.execute('subtle palms a coin to Alice')
        expect(result[:success]).to be true

        expect(RpLog.where(character_instance_id: character_instance.id).count).to eq(before_sender + 1)
        expect(RpLog.where(character_instance_id: other_instance.id).count).to eq(before_other + 1)
        expect(RpLog.where(character_instance_id: third_instance.id).count).to eq(before_third)
      end
    end

    context 'when gagged' do
      before do
        character_instance.update(is_gagged: true)
      end

      it 'prevents subtle emoting' do
        result = subject.execute('subtle waves')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/gag/i)
      end
    end
  end

  describe '#can_execute?' do
    it 'returns true when character is in a room' do
      expect(subject.can_execute?).to be true
    end

    it 'returns false when character has no room' do
      allow(subject).to receive(:location).and_return(nil)
      expect(subject.can_execute?).to be false
    end
  end

  it_behaves_like "command metadata", 'subtle', :roleplaying, []
end
