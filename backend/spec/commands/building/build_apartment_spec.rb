# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../plugins/core/building/commands/build_apartment'

RSpec.describe Commands::Building::BuildApartment do
  include TestHelpers

  let(:universe) { create(:universe, name: 'Test Universe', theme: 'fantasy') }
  let(:world) { create(:world, universe: universe, name: 'Test World') }
  let(:area) { create(:area, world: world, name: 'Test Area') }
  let(:location) do
    create(:location,
           zone: area,
           name: 'Test City',
           city_built_at: Time.now,
           horizontal_streets: 3,
           vertical_streets: 3)
  end
  let(:intersection) do
    create(:room,
           location: location,
           name: '1st Street & 1st Avenue',
           room_type: 'intersection',
           city_role: 'intersection',
           grid_x: 0,
           grid_y: 0)
  end
  let(:apartment) do
    create(:room,
           location: location,
           name: 'Test Apartments - Unit 2A',
           room_type: 'apartment',
           city_role: 'building',
           building_type: 'apartment_tower',
           floor_number: 1,
           grid_x: 0,
           grid_y: 0)
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
      expect(described_class.command_name).to eq('build apartment')
    end

    it 'has aliases' do
      expect(described_class.alias_names).to include('buildapartment')
      expect(described_class.alias_names).to include('get apartment')
    end
  end

  describe '#execute' do
    context 'without permission' do
      let(:user) { create(:user, is_admin: false) }

      it 'returns error' do
        result = command.execute('build apartment')

        expect(result[:success]).to be false
        expect(result[:error]).to include('permission')
      end
    end

    context 'not in a city' do
      let(:non_city_location) { create(:location, zone: area, name: 'Non-City') }
      let(:non_city_room) { create(:room, location: non_city_location, name: 'Regular Room') }
      let(:character_instance) { create(:character_instance, character: character, current_room: non_city_room, online: true) }

      it 'returns error' do
        result = command.execute('build apartment')

        expect(result[:success]).to be false
        expect(result[:error]).to include('city')
      end
    end

    context 'in a city with permission' do
      before do
        # Create an apartment to find
        apartment
      end

      it 'finds existing apartment' do
        result = command.execute('build apartment')

        # Should show quickmenu with apartment details
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:interaction_id]).not_to be_nil
      end

      it 'accepts size parameter' do
        result = command.execute('build apartment small')

        expect(result[:type]).to eq(:quickmenu)
      end
    end
  end

  describe '#handle_quickmenu_response' do
    context 'claiming apartment' do
      it 'claims the apartment' do
        result = command.send(:handle_quickmenu_response,
          'claim',
          { 'apartment_id' => apartment.id, 'command' => 'build_apartment' }
        )

        expect(result[:success]).to be true
        expect(result[:message]).to include('claimed')
        expect(result[:data][:action]).to eq('claim_apartment')
      end

      it 'moves character to apartment' do
        command.send(:handle_quickmenu_response,
          'claim',
          { 'apartment_id' => apartment.id, 'command' => 'build_apartment' }
        )

        character_instance.reload
        expect(character_instance.current_room_id).to eq(apartment.id)
      end

      it 'rejects claiming an apartment owned by someone else' do
        apartment.update(owner_id: create(:character).id)

        result = command.send(:handle_quickmenu_response,
          'claim',
          { 'apartment_id' => apartment.id, 'command' => 'build_apartment' }
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('already been claimed')
      end
    end

    context 'visiting apartment' do
      it 'visits without claiming' do
        result = command.send(:handle_quickmenu_response,
          'visit',
          { 'apartment_id' => apartment.id, 'command' => 'build_apartment' }
        )

        expect(result[:success]).to be true
        expect(result[:message]).to include('visiting')
        expect(result[:data][:action]).to eq('visit_apartment')
      end
    end

    context 'canceling' do
      it 'cancels without error' do
        result = command.send(:handle_quickmenu_response,
          'cancel',
          { 'apartment_id' => apartment.id, 'command' => 'build_apartment' }
        )

        expect(result[:success]).to be true
        expect(result[:message]).to include('not to take')
      end
    end
  end
end
