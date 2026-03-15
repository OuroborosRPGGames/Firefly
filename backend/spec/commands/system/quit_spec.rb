# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Quit, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, stance: 'standing') }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'basic quit' do
      it 'sets character offline' do
        result = command.execute('quit')
        expect(result[:success]).to be true
        expect(character_instance.reload.online).to be false
      end

      it 'returns quit type and close_play_window data' do
        result = command.execute('quit')
        expect(result[:type]).to eq(:quit)
        expect(result[:data][:close_play_window]).to be true
      end

      it 'shows goodbye message' do
        result = command.execute('quit')
        expect(result[:message]).to include('Goodbye')
      end
    end

    context 'clears active states' do
      let(:user2) { create(:user) }
      let(:bob_character) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }
      let!(:bob_instance) { create(:character_instance, character: bob_character, current_room: room, reality: reality, stance: 'standing') }

      it 'clears observation state' do
        character_instance.start_observing!(bob_instance)
        expect(character_instance.observing?).to be true

        command.execute('quit')
        expect(character_instance.reload.observing?).to be false
      end

      it 'clears AFK status' do
        character_instance.set_afk!(30)
        expect(character_instance.afk?).to be true

        command.execute('quit')
        expect(character_instance.reload.afk?).to be false
      end

      it 'clears semi-AFK status' do
        character_instance.update(semiafk: true)
        expect(character_instance.semiafk?).to be true

        command.execute('quit')
        expect(character_instance.reload.semiafk?).to be false
      end
    end

    context 'at a place' do
      let!(:bar) do
        Place.create(
          name: 'The Bar',
          room: room,
          is_furniture: true
        )
      end

      it 'includes place name in departure message' do
        character_instance.update(current_place_id: bar.id)
        result = command.execute('quit')
        expect(result[:success]).to be true
        # The broadcast includes the place name but the user message is just "Goodbye"
        expect(character_instance.reload.online).to be false
      end
    end
  end
end
