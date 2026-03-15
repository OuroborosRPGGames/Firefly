# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Crafting::Make, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, owner_id: character.id) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no arguments' do
      it 'shows help with available types' do
        result = command.execute('make')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Available types')
        expect(result[:message]).to include('event')
        expect(result[:message]).to include('society')
        expect(result[:message]).to include('memo')
      end
    end

    context 'make event' do
      it 'redirects to web interface' do
        result = command.execute('make event')

        expect(result[:success]).to be true
        expect(result[:message]).to include('web interface')
        expect(result[:data][:action]).to eq('make_event')
      end
    end

    context 'make calendar (alias for event)' do
      it 'redirects to web interface' do
        result = command.execute('make calendar')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('make_event')
      end
    end

    context 'make society' do
      it 'redirects to web interface' do
        result = command.execute('make society')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Societies')
        expect(result[:data][:action]).to eq('make_society')
      end
    end

    context 'make club (alias for society)' do
      it 'redirects to web interface' do
        result = command.execute('make club')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('make_society')
      end
    end

    context 'make memo' do
      it 'requires content' do
        result = command.execute('make memo')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what do you want to write/i)
      end

      it 'saves memo content' do
        result = command.execute('make memo Remember to buy milk')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Memo saved')
        expect(result[:message]).to include('Remember to buy milk')
      end
    end

    context 'make note (alias for memo)' do
      it 'saves note content' do
        result = command.execute('make note Important note here')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('make_memo')
      end
    end

    context 'make scene' do
      it 'creates scene with default name' do
        result = command.execute('make scene')

        expect(result[:success]).to be true
        expect(result[:message]).to include('begin a new scene')
        expect(result[:data][:action]).to eq('make_scene')
      end

      it 'creates scene with custom name' do
        result = command.execute('make scene The Grand Ball')

        expect(result[:success]).to be true
        expect(result[:message]).to include('The Grand Ball')
      end
    end

    context 'make story (alias for scene)' do
      it 'creates scene' do
        result = command.execute('make story Epic Adventure')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('make_scene')
      end
    end

    context 'make entrance' do
      it 'marks room as entrance when owner' do
        result = command.execute('make entrance')

        expect(result[:success]).to be true
        expect(result[:message]).to include('entrance')
      end

      context 'in unowned room' do
        let(:other_character) { create(:character, forename: 'Bob') }
        let(:room) { create(:room, location: location, owner_id: other_character.id) }

        it 'returns error' do
          result = command.execute('make entrance')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/rooms you own/i)
        end
      end
    end

    context 'make library' do
      it 'designates room as library when owner' do
        result = command.execute('make library')

        expect(result[:success]).to be true
        expect(result[:message]).to include('arcane library')
      end

      context 'in unowned room' do
        let(:other_character) { create(:character, forename: 'Bob') }
        let(:room) { create(:room, location: location, owner_id: other_character.id) }

        it 'returns error' do
          result = command.execute('make library')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/rooms you own/i)
        end
      end
    end

    context 'make space' do
      it 'redirects to building interface' do
        result = command.execute('make space')

        expect(result[:success]).to be true
        expect(result[:message]).to include('building interface')
      end
    end

    context 'make floor' do
      it 'redirects to building interface' do
        result = command.execute('make floor')

        expect(result[:success]).to be true
        expect(result[:message]).to include('building interface')
      end
    end

    context 'with unknown subcommand' do
      it 'returns error with valid types' do
        result = command.execute('make unicorn')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Unknown type 'unicorn'")
        expect(result[:error]).to include('Valid types')
      end
    end
  end
end
