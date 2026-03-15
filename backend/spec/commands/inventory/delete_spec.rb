# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Delete, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, owner: character) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with empty input' do
      it 'shows usage' do
        result = command.execute('delete')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with invalid type' do
      it 'returns error' do
        result = command.execute('delete unknown')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown delete type')
      end
    end

    describe 'delete bulletin' do
      context 'with bulletins' do
        let!(:bulletin) do
          ::Bulletin.create(
            character_id: character.id,
            from_text: character.full_name,
            body: 'Test'
          )
        end

        it 'deletes bulletins' do
          result = command.execute('delete bulletin')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Deleted')
          expect(::Bulletin.by_character(character).count).to eq(0)
        end
      end

      context 'without bulletins' do
        it 'returns error' do
          result = command.execute('delete bulletin')

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't have any bulletins")
        end
      end
    end

    describe 'delete place' do
      context 'in owned room with places' do
        let!(:place) do
          Place.create(
            room: room,
            name: 'Corner Table',
            description: 'A cozy corner table',
            capacity: 4
          )
        end

        it 'lists places when no name provided' do
          result = command.execute('delete place')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Corner Table')
        end

        it 'deletes specific place' do
          result = command.execute('delete place corner table')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Deleted place')
          expect(Place[place.id]).to be_nil
        end
      end

      context 'in unowned room' do
        let(:other_character) { create(:character, forename: 'Bob') }
        let(:other_room) { create(:room, location: location, owner: other_character) }

        before do
          character_instance.update(current_room: other_room)
        end

        it 'returns error' do
          result = command.execute('delete place')

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't own")
        end
      end
    end

    context 'with aliases' do
      it 'works with del alias' do
        command_class, _words = Commands::Base::Registry.find_command('del')
        expect(command_class).to eq(Commands::Inventory::Delete)
      end
    end
  end
end
