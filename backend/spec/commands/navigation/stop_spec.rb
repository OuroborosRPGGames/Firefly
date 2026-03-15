# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Stop, type: :command do
  let(:location) { create(:location) }

  # Room A with defined bounds for spatial adjacency
  let(:room_a) do
    create(:room,
           name: 'Room A', short_description: 'Start', location: location,
           room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 100, max_y: 200)
  end

  # Room B is spatially adjacent to room_a (shares north edge)
  let(:room_b) do
    create(:room,
           name: 'Room B', short_description: 'North', location: location,
           room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 200, max_y: 300)
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room_a)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    before { room_b } # Ensure north room exists

    context 'when moving' do
      before do
        MovementService.start_movement(character_instance, target: 'north')
      end

      it 'stops the movement' do
        result = command.execute('stop')

        expect(result[:success]).to be true
        expect(result[:message]).to include('stop')
      end

      it 'sets movement state to idle' do
        command.execute('stop')

        expect(character_instance.reload.movement_state).to eq('idle')
      end
    end

    context 'when following' do
      let(:leader_user) { create(:user) }
      let(:leader_character) { create(:character, user: leader_user) }
      let!(:leader_instance) do
        create(:character_instance, character: leader_character, current_room: room_a)
      end

      before do
        Relationship.create(
          character: character,
          target_character: leader_character,
          status: 'accepted',
          can_follow: true
        )
        MovementService.start_following(character_instance, leader_instance)
      end

      it 'stops following with explicit command' do
        result = command.execute('stop following')

        expect(result[:success]).to be true
        expect(character_instance.reload.following_id).to be_nil
      end

      it 'stops following with plain stop' do
        result = command.execute('stop')

        expect(result[:success]).to be true
        expect(character_instance.reload.following_id).to be_nil
      end
    end

    context 'when not moving or following' do
      it 'returns error' do
        result = command.execute('stop')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not moving')
      end
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('stop')
    end

    it 'has halt alias' do
      expect(described_class.alias_names).to include('halt')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:navigation)
    end
  end
end
