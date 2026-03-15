# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::GiveNumber, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'One', user: user) }
  let!(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

  let(:target_user) { create(:user) }
  let(:target_character) { create(:character, forename: 'Bob', surname: 'Two', user: target_user) }
  let!(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'giving number successfully' do
      it 'gives number to target' do
        result = command.execute('give number to Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to include('give')
        expect(result[:message]).to include('your number')
        expect(result[:message]).to include('Bob')
      end

      it 'creates has_number record' do
        expect { command.execute('give number to Bob') }.to change { HasNumber.count }.by(1)
        expect(HasNumber.has_number?(target_character, character)).to be true
      end

      it 'works without "to" keyword' do
        result = command.execute('give number Bob')
        expect(result[:success]).to be true
      end

      it 'returns structured data' do
        result = command.execute('give number Bob')
        expect(result[:data][:action]).to eq('give_number')
        expect(result[:data][:target_name]).to include('Bob')
      end
    end

    context 'error cases' do
      it 'errors when no target specified' do
        result = command.execute('give number')
        expect(result[:success]).to be false
        expect(result[:error]).to include('who')
      end

      it 'errors when target not found' do
        result = command.execute('give number to Nobody')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see")
      end

      it 'errors when target not in same room' do
        # Move target to a different room
        other_room = Room.create(
          name: 'Other Room',
          short_description: 'Another room',
          location: location,
          room_type: 'standard'
        )
        target_instance.update(current_room_id: other_room.id)
        result = command.execute('give number to Bob')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see")
      end

      it 'errors when already gave number' do
        HasNumber.create(character_id: target_character.id, target_id: character.id)
        result = command.execute('give number to Bob')
        expect(result[:success]).to be false
        expect(result[:error]).to include('already has')
      end

      it 'errors when giving number to self' do
        result = command.execute('give number to Alice')
        # Self is excluded from target search by default
        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see anyone/i)
      end
    end
  end
end
