# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../plugins/core/building/commands/build_block'

RSpec.describe Commands::Building::BuildBlock do
  include TestHelpers

  let(:universe) { create(:universe, name: 'Test Universe', theme: 'fantasy') }
  let(:world) { create(:world, universe: universe, name: 'Test World') }
  let(:area) { create(:area, world: world, name: 'Test Area') }
  let(:location) { create(:location, zone: area, name: 'Test City') }
  let(:intersection) do
    create(:room,
           location: location,
           name: '1st Street & 1st Avenue',
           room_type: 'intersection',
           city_role: 'intersection',
           grid_x: 0,
           grid_y: 0)
  end
  let(:street) do
    create(:room,
           location: location,
           name: '1st Street',
           room_type: 'street',
           city_role: 'street',
           grid_x: 0,
           grid_y: 0,
           street_name: '1st Street')
  end
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: intersection, online: true) }

  subject(:command) { described_class.new(character_instance) }

  before do
    Commands::Base::Registry.register(described_class)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('build block')
    end

    it 'has aliases' do
      expect(described_class.alias_names).to include('buildblock')
    end
  end

  describe '#execute' do
    context 'without permission' do
      let(:user) { create(:user, is_admin: false) }

      it 'returns error' do
        result = command.execute('build block apartment')

        expect(result[:success]).to be false
        expect(result[:error]).to include('permission')
      end
    end

    context 'not at intersection' do
      let(:character_instance) { create(:character_instance, character: character, current_room: street, online: true) }

      it 'returns error' do
        result = command.execute('build block apartment')

        expect(result[:success]).to be false
        expect(result[:error]).to include('intersection')
      end
    end

    context 'at intersection with permission' do
      it 'builds apartment tower' do
        result = command.execute('build block apartment')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Apartment')
        expect(result[:data][:building_type]).to eq('apartment_tower')
      end

      it 'builds brownstone' do
        result = command.execute('build block brownstone')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Brownstone')
      end

      it 'builds shop' do
        result = command.execute('build block shop')

        expect(result[:success]).to be true
        expect(result[:data][:building_type]).to eq('shop')
      end

      it 'shows menu without building type' do
        result = command.execute('build block')

        expect(result[:type]).to eq(:quickmenu)
        expect(result[:interaction_id]).not_to be_nil
      end

      context 'when building already exists' do
        before do
          create(:room,
                 location: location,
                 name: 'Existing Building',
                 room_type: 'building',
                 city_role: 'building',
                 building_type: 'apartment_tower',
                 grid_x: 0,
                 grid_y: 0)
        end

        it 'returns error' do
          result = command.execute('build block shop')

          expect(result[:success]).to be false
          expect(result[:error]).to include('already a building')
        end
      end
    end
  end

  describe '#handle_quickmenu_response' do
    context 'building type selection' do
      it 'shows layout menu after selecting building type' do
        result = command.send(:handle_quickmenu_response,
          'brownstone',
          { 'room_id' => intersection.id, 'command' => 'build_block', 'menu_type' => 'building' }
        )

        expect(result[:type]).to eq(:quickmenu)
        expect(result[:interaction_id]).not_to be_nil
      end
    end

    context 'layout selection' do
      it 'builds selected building type with layout' do
        result = command.send(:handle_quickmenu_response,
          'full',
          { 'room_id' => intersection.id, 'command' => 'build_block', 'menu_type' => 'layout', 'building_type' => 'brownstone' }
        )

        expect(result[:success]).to be true
        expect(result[:message]).to include('Brownstone')
      end
    end
  end
end
