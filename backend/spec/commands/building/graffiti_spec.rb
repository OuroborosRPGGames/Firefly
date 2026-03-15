# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::GraffitiCmd, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, x: 5.0, y: 3.0) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no text' do
      it 'returns error' do
        result = command.execute('graffiti')
        expect(result[:success]).to be false
        expect(result[:message]).to include('What do you want to write')
      end
    end

    context 'with text too long' do
      it 'returns error' do
        long_text = 'a' * 221
        result = command.execute("graffiti #{long_text}")
        expect(result[:success]).to be false
        expect(result[:message]).to include('220 characters or less')
      end
    end

    context 'with valid text' do
      it 'returns success' do
        result = command.execute('graffiti Kilroy was here')
        expect(result[:success]).to be true
      end

      it 'creates graffiti record' do
        expect { command.execute('graffiti Kilroy was here') }
          .to change { Graffiti.count }.by(1)
      end

      it 'records character position' do
        command.execute('graffiti Kilroy was here')
        graffiti = Graffiti.last
        expect(graffiti.x).to eq(5.0)
        expect(graffiti.y).to eq(3.0)
      end

      it 'associates with room' do
        command.execute('graffiti Kilroy was here')
        graffiti = Graffiti.last
        expect(graffiti.room_id).to eq(room.id)
      end

      it 'stores the text' do
        command.execute('graffiti Kilroy was here')
        graffiti = Graffiti.last
        expect(graffiti.text).to eq('Kilroy was here')
      end
    end
  end
end
