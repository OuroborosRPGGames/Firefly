# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MovementBroadcaster do
  let(:character_instance) do
    double('CharacterInstance',
           id: 1,
           full_name: 'Alice Smith',
           current_room: room)
  end

  let(:other_instance) do
    double('CharacterInstance',
           id: 2,
           character: double('Character'),
           full_name: 'Bob Jones')
  end

  let(:room) do
    double('Room',
           id: 100,
           room_sightlines: [])
  end

  let(:viewers_dataset) do
    dataset = double('Dataset')
    allow(dataset).to receive(:where).and_return(dataset)
    allow(dataset).to receive(:eager).and_return(dataset)
    allow(dataset).to receive(:exclude).and_return(dataset)
    allow(dataset).to receive(:each).and_yield(other_instance)
    allow(dataset).to receive(:all).and_return([other_instance])
    dataset
  end

  before do
    allow(CharacterInstance).to receive(:where).and_return(viewers_dataset)
    allow(BroadcastService).to receive(:to_character)
    allow(room).to receive(:respond_to?).with(:room_sightlines).and_return(false)
    # Personalization returns message unchanged in unit tests
    allow(MessagePersonalizationService).to receive(:personalize) { |args| args[:message] }
  end

  describe '.broadcast_departure' do
    before do
      allow(MovementConfig).to receive(:conjugate).with('walk', :present).and_return('walks')
    end

    it 'broadcasts departure message to room' do
      described_class.broadcast_departure(character_instance, room, 'north')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        include('Alice Smith walks north')
      )
    end

    it 'excludes the departing character from broadcast' do
      described_class.broadcast_departure(character_instance, room, 'north')

      expect(viewers_dataset).to have_received(:exclude).with(id: character_instance.id)
    end

    it 'uses custom adverb' do
      allow(MovementConfig).to receive(:conjugate).with('run', :present).and_return('runs')

      described_class.broadcast_departure(character_instance, room, 'south', adverb: 'run')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        include('runs south')
      )
    end
  end

  describe '.broadcast_arrival' do
    before do
      allow(MovementConfig).to receive(:conjugate).with('walk', :present).and_return('walks')
      allow(CanvasHelper).to receive(:arrival_direction).with('north').and_return('south')
    end

    it 'broadcasts arrival message from opposite direction' do
      described_class.broadcast_arrival(character_instance, room, 'north')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        include('walks in from the south')
      )
    end

    it 'excludes arriving character from broadcast' do
      described_class.broadcast_arrival(character_instance, room, 'north')

      expect(viewers_dataset).to have_received(:exclude).with(id: character_instance.id)
    end

    it 'uses custom adverb' do
      allow(MovementConfig).to receive(:conjugate).with('limp', :present).and_return('limps')
      allow(CanvasHelper).to receive(:arrival_direction).with('east').and_return('west')

      described_class.broadcast_arrival(character_instance, room, 'east', adverb: 'limp')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        include('limps in')
      )
    end
  end

  describe '.broadcast_movement_start' do
    before do
      allow(MovementConfig).to receive(:conjugate).with('walk', :continuous).and_return('walking')
    end

    it 'broadcasts movement start message' do
      described_class.broadcast_movement_start(character_instance, 'the north exit')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        include('starts walking toward the north exit')
      )
    end

    it 'uses custom adverb' do
      allow(MovementConfig).to receive(:conjugate).with('run', :continuous).and_return('running')

      described_class.broadcast_movement_start(character_instance, 'the door', adverb: 'run')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        include('running toward')
      )
    end
  end

  describe '.broadcast_movement_stop' do
    it 'broadcasts basic stop message' do
      described_class.broadcast_movement_stop(character_instance)

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        'Alice Smith stops moving.'
      )
    end

    it 'includes reason when provided' do
      described_class.broadcast_movement_stop(character_instance, reason: 'blocked by door')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        'Alice Smith stops moving (blocked by door).'
      )
    end
  end

  describe '.broadcast_follow_start' do
    let(:leader) do
      double('CharacterInstance',
             id: 3,
             full_name: 'Charlie Leader')
    end

    it 'broadcasts follow start message' do
      described_class.broadcast_follow_start(character_instance, leader)

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        'Alice Smith starts following Charlie Leader.'
      )
    end

    it 'does not exclude any characters' do
      described_class.broadcast_follow_start(character_instance, leader)

      # Should NOT have called exclude
      expect(viewers_dataset).not_to have_received(:exclude)
    end
  end

  describe '.broadcast_follow_stop' do
    let(:leader) do
      double('CharacterInstance',
             id: 3,
             full_name: 'Charlie Leader')
    end

    it 'broadcasts follow stop message' do
      described_class.broadcast_follow_stop(character_instance, leader)

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        'Alice Smith stops following Charlie Leader.'
      )
    end

    it 'includes reason when provided' do
      described_class.broadcast_follow_stop(character_instance, leader, reason: 'leader entered locked room')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        'Alice Smith stops following Charlie Leader (leader entered locked room).'
      )
    end
  end

  describe 'sightline broadcasting' do
    let(:sightline) do
      double('RoomSightline',
             direction: 'north',
             to_room: far_room,
             distance_description: 'far away',
             bidirectional?: false)
    end

    let(:far_room) do
      double('Room', id: 200, room_sightlines: [])
    end

    let(:far_viewers_dataset) do
      dataset = double('Dataset')
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:eager).and_return(dataset)
      allow(dataset).to receive(:exclude).and_return(dataset)
      allow(dataset).to receive(:each).and_yield(other_instance)
      allow(dataset).to receive(:all).and_return([other_instance])
      dataset
    end

    before do
      allow(room).to receive(:respond_to?).with(:room_sightlines).and_return(true)
      allow(room).to receive(:room_sightlines).and_return([sightline])
      allow(far_room).to receive(:respond_to?).with(:room_sightlines).and_return(false)
      allow(MovementConfig).to receive(:conjugate).with('walk', :present).and_return('walks')
    end

    it 'broadcasts to sightline rooms when direction matches' do
      allow(CharacterInstance).to receive(:where).with(current_room_id: far_room.id, online: true).and_return(far_viewers_dataset)

      described_class.broadcast_departure(character_instance, room, 'north')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        include('far away')
      )
    end

    it 'does not broadcast to sightline when direction differs' do
      allow(CharacterInstance).to receive(:where).with(current_room_id: far_room.id, online: true).and_return(far_viewers_dataset)

      described_class.broadcast_departure(character_instance, room, 'south')

      # Should only get the main room broadcast, not sightline
      expect(BroadcastService).to have_received(:to_character).once
    end

    context 'with bidirectional sightline' do
      before do
        allow(sightline).to receive(:bidirectional?).and_return(true)
        allow(CharacterInstance).to receive(:where).with(current_room_id: far_room.id, online: true).and_return(far_viewers_dataset)
      end

      it 'broadcasts regardless of direction' do
        described_class.broadcast_departure(character_instance, room, 'east')

        # Should get both main room and sightline broadcasts
        expect(BroadcastService).to have_received(:to_character).at_least(:twice)
      end
    end
  end

  describe 'private methods' do
    describe '.broadcast_to_room' do
      context 'when room is nil' do
        it 'returns early' do
          expect {
            described_class.send(:broadcast_to_room, nil, 'test message')
          }.not_to raise_error
        end
      end
    end

  end
end
