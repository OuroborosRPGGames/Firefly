# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Follow, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Follower', surname: 'One', user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room)
  end

  let(:leader_user) { create(:user) }
  let(:leader_character) { create(:character, forename: 'Leader', surname: 'Two', user: leader_user) }
  let!(:leader_instance) do
    create(:character_instance, character: leader_character, current_room: room, online: true)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid target and permission' do
      before do
        Relationship.create(
          character: character,
          target_character: leader_character,
          status: 'accepted',
          can_follow: true
        )
      end

      it 'starts following the target' do
        result = command.execute('follow Leader')

        expect(result[:success]).to be true
        expect(result[:message]).to include('following')
        expect(result[:following]).to eq('Leader Two')
      end

      it 'sets following_id on character instance' do
        command.execute('follow Leader')

        expect(character_instance.reload.following_id).to eq(leader_instance.id)
      end
    end

    context 'without permission' do
      it 'returns permission error' do
        result = command.execute('follow Leader')

        expect(result[:success]).to be false
        expect(result[:error]).to include('permission')
      end
    end

    context 'with no target specified' do
      it 'returns error asking who to follow' do
        result = command.execute('follow')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Who')
      end
    end

    context 'with unknown target' do
      it 'returns not found error' do
        result = command.execute('follow Unknown')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see|no one matching|no one to search/i)
      end
    end

    context 'with target in different room' do
      before do
        other_room = create(:room, name: 'Other Room', short_description: 'Another room', location: location)
        leader_instance.update(current_room: other_room)
      end

      it 'returns not found error' do
        result = command.execute('follow Leader')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see|no one matching|no one to search/i)
      end
    end
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'follow', :navigation, []
end
