# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../plugins/core/building/commands/build_city'

RSpec.describe Commands::Building::BuildCity do
  include TestHelpers

  let(:universe) { create(:universe, name: 'Test Universe', theme: 'fantasy') }
  let(:world) { create(:world, universe: universe, name: 'Test World') }
  let(:area) { create(:area, world: world, name: 'Test Area') }
  let(:location) { create(:location, zone: area, name: 'Test Location') }
  let(:room) { create(:room, location: location, name: 'Starting Room') }
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, online: true) }

  subject(:command) { described_class.new(character_instance) }

  before do
    # Ensure command is registered
    Commands::Base::Registry.register(described_class)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('build city')
    end

    it 'has aliases' do
      expect(described_class.alias_names).to include('buildcity')
      expect(described_class.alias_names).to include('create city')
    end

    it 'has category :building' do
      expect(described_class.category).to eq(:building)
    end
  end

  describe '#execute' do
    context 'without admin permission' do
      let(:user) { create(:user, is_admin: false) }

      it 'returns error' do
        result = command.execute('build city Test City')

        expect(result[:success]).to be false
        expect(result[:error]).to include('permission')
      end
    end

    context 'with admin permission' do
      it 'builds a city with provided name' do
        result = command.execute('build city Test City')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test City')
        expect(result[:message]).to include('streets')
        expect(result[:message]).to include('avenues')
      end

      it 'creates streets and avenues' do
        result = command.execute('build city Grid City')

        expect(result[:success]).to be true

        # Check that rooms were created
        # One room per street, one room per avenue (spanning full city width/height)
        street_count = Room.where(location_id: location.id, city_role: 'street').count
        avenue_count = Room.where(location_id: location.id, city_role: 'avenue').count

        expect(street_count).to eq(10) # 10 streets (one room each)
        expect(avenue_count).to eq(10) # 10 avenues (one room each)
      end

      it 'creates intersections' do
        result = command.execute('build city Intersection City')

        expect(result[:success]).to be true

        intersection_count = Room.where(location_id: location.id, city_role: 'intersection').count
        expect(intersection_count).to eq(100) # 10x10 grid
      end

      it 'updates location with city parameters' do
        result = command.execute('build city My City')

        expect(result[:success]).to be true

        location.reload
        expect(location.city_name).to eq('My City')
        expect(location.city_built_at).not_to be_nil
      end

      context 'when city already exists' do
        before do
          location.city_built_at = Time.now
          location.city_name = 'Existing City'
          location.save
        end

        it 'returns error' do
          result = command.execute('build city New City')

          expect(result[:success]).to be false
          expect(result[:error]).to include('already been built')
        end
      end
    end

    context 'without city name' do
      it 'shows form when no name provided' do
        result = command.execute('build city')

        # Should return a form
        expect(result[:type]).to eq(:form)
        expect(result[:interaction_id]).not_to be_nil
      end
    end
  end

  describe '#handle_form_response' do
    let(:form_data) do
      {
        'city_name' => 'Form City',
        'horizontal_streets' => '5',
        'vertical_streets' => '5',
        'max_building_height' => '150'
      }
    end

    let(:form_context) do
      {
        'location_id' => location.id,
        'command' => 'build_city'
      }
    end

    it 'builds city from form data' do
      result = command.send(:handle_form_response, form_data, form_context)

      expect(result[:success]).to be true
      expect(result[:message]).to include('Form City')

      location.reload
      expect(location.horizontal_streets).to eq(5)
      expect(location.vertical_streets).to eq(5)
    end
  end
end
