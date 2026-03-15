# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PersonalizedBroadcastConcern do
  # Create a test class that includes the concern
  let(:test_class) do
    Class.new do
      include PersonalizedBroadcastConcern
    end
  end

  let(:instance) { test_class.new }

  let(:room) { create(:room) }
  let(:character1) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:character2) { create(:character, forename: 'Bob', surname: 'Jones') }
  let(:ci1) { create(:character_instance, character: character1, current_room: room, online: true) }
  let(:ci2) { create(:character_instance, character: character2, current_room: room, online: true) }

  describe '#broadcast_personalized_to_room' do
    before do
      ci1
      ci2
    end

    it 'sends personalized messages to each online character in the room' do
      allow(MessagePersonalizationService).to receive(:personalize).and_call_original

      instance.broadcast_personalized_to_room(
        room.id,
        "#{character1.full_name} waves at #{character2.full_name}.",
        exclude: [ci1.id]
      )

      expect(MessagePersonalizationService).to have_received(:personalize).with(
        message: "#{character1.full_name} waves at #{character2.full_name}.",
        viewer: ci2,
        room_characters: array_including(ci2)
      )
    end

    it 'excludes specified character instances by ID' do
      allow(BroadcastService).to receive(:to_character)

      instance.broadcast_personalized_to_room(
        room.id,
        'Test message',
        exclude: [ci1.id]
      )

      expect(BroadcastService).not_to have_received(:to_character).with(ci1, anything)
      expect(BroadcastService).to have_received(:to_character).with(ci2, anything)
    end

    it 'excludes specified character instances by object' do
      allow(BroadcastService).to receive(:to_character)

      instance.broadcast_personalized_to_room(
        room.id,
        'Test message',
        exclude: [ci1]
      )

      expect(BroadcastService).not_to have_received(:to_character).with(ci1, anything)
      expect(BroadcastService).to have_received(:to_character).with(ci2, anything)
    end

    it 'includes extra_characters in personalization context without duplicates' do
      other_room = create(:room)
      departed_char = create(:character, forename: 'Carol', surname: 'White')
      departed_ci = create(:character_instance, character: departed_char, current_room: other_room, online: true)

      allow(MessagePersonalizationService).to receive(:personalize).and_call_original

      instance.broadcast_personalized_to_room(
        room.id,
        "#{departed_char.full_name} leaves.",
        extra_characters: [departed_ci]
      )

      # Each viewer should get personalization with the departed character included
      expect(MessagePersonalizationService).to have_received(:personalize).with(
        hash_including(room_characters: array_including(departed_ci))
      ).at_least(:once)
    end

    it 'does not duplicate characters already in the room when passed as extra_characters' do
      received_args = []
      allow(MessagePersonalizationService).to receive(:personalize) do |**kwargs|
        received_args << kwargs
        kwargs[:message]
      end

      instance.broadcast_personalized_to_room(
        room.id,
        'Test message',
        extra_characters: [ci1]
      )

      # ci1 should appear only once in room_characters for each viewer
      received_args.each do |args|
        ci1_count = args[:room_characters].count { |c| c.id == ci1.id }
        expect(ci1_count).to eq(1)
      end
    end

    it 'does nothing when room_id is nil' do
      allow(BroadcastService).to receive(:to_character)

      instance.broadcast_personalized_to_room(nil, 'Test message')

      expect(BroadcastService).not_to have_received(:to_character)
    end

    it 'handles empty room gracefully' do
      empty_room = create(:room)

      expect {
        instance.broadcast_personalized_to_room(empty_room.id, 'Test message')
      }.not_to raise_error
    end
  end

  describe '#personalize_for' do
    it 'delegates to MessagePersonalizationService' do
      allow(MessagePersonalizationService).to receive(:personalize).and_return('personalized text')

      result = instance.personalize_for(
        'original text',
        viewer: ci1,
        room_characters: [ci1, ci2]
      )

      expect(result).to eq('personalized text')
      expect(MessagePersonalizationService).to have_received(:personalize).with(
        message: 'original text',
        viewer: ci1,
        room_characters: [ci1, ci2]
      )
    end

    it 'defaults room_characters to empty array' do
      allow(MessagePersonalizationService).to receive(:personalize).and_return('text')

      instance.personalize_for('text', viewer: ci1)

      expect(MessagePersonalizationService).to have_received(:personalize).with(
        message: 'text',
        viewer: ci1,
        room_characters: []
      )
    end
  end
end
