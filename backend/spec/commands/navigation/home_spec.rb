# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Home, type: :command do
  let(:location) { create(:location) }

  let(:current_room) do
    create(:room,
           name: 'Town Square',
           short_description: 'A busy town square.',
           location: location,
           room_type: 'street')
  end

  let(:home_room) do
    create(:room,
           name: 'Cozy Apartment',
           short_description: 'A small but cozy apartment.',
           location: location,
           room_type: 'apartment')
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'Player', user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: current_room)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when home is set' do
      before do
        character.update(home_room_id: home_room.id)
      end

      it 'teleports to home' do
        result = command.execute('home')

        expect(result[:success]).to be true
        expect(result[:message]).to include('You head home to')
        expect(result[:message]).to include('Cozy Apartment')
      end

      it 'moves the character to the home room' do
        command.execute('home')

        character_instance.refresh
        expect(character_instance.current_room_id).to eq(home_room.id)
      end

      it 'returns teleport type with structured data' do
        result = command.execute('home')

        expect(result[:type]).to eq(:teleport)
        expect(result[:data][:action]).to eq('teleport')
        expect(result[:data][:from_room]).to eq('Town Square')
        expect(result[:data][:to_room]).to eq('Cozy Apartment')
      end
    end

    context 'when home is not set' do
      it 'returns an error' do
        result = command.execute('home')

        expect(result[:success]).to be false
        expect(result[:error]).to include("don't have a home set")
      end

      it 'does not move the character' do
        original_room_id = character_instance.current_room_id
        command.execute('home')

        character_instance.refresh
        expect(character_instance.current_room_id).to eq(original_room_id)
      end
    end

    context 'when already at home' do
      before do
        character.update(home_room_id: current_room.id)
      end

      it 'returns an error' do
        result = command.execute('home')

        expect(result[:success]).to be false
        expect(result[:error]).to include("already at home")
      end
    end

    context 'with gohome alias' do
      before do
        character.update(home_room_id: home_room.id)
      end

      it 'works the same as home command' do
        result = command.execute('gohome')

        expect(result[:success]).to be true
        expect(result[:message]).to include('You head home to')
      end
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('home')
    end

    it 'has gohome alias' do
      expect(described_class.alias_names).to include('gohome')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:navigation)
    end

    it 'requires not being in combat' do
      requirements = described_class.requirements
      not_in_combat_req = requirements.find { |r| r[:type] == :not_in_combat }
      expect(not_in_combat_req).not_to be_nil
    end
  end
end
