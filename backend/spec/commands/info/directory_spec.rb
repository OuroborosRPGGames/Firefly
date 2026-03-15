# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Info::Directory, type: :command do
  let!(:area) { create(:area, name: 'Downtown', zone_type: 'city') }
  let!(:location) { create(:location, zone: area, name: 'Main Street', location_type: 'outdoor') }
  let!(:room) { create(:room, location: location, name: 'Street Corner', short_description: 'A busy corner') }
  let!(:reality) { create(:reality) }
  let!(:user) { create(:user) }
  let!(:character) { create(:character, user: user, forename: 'TestChar') }
  let!(:character_instance) do
    create(:character_instance,
      character: character,
      current_room: room,
      reality: reality
    )
  end

  subject(:command) { described_class.new(character_instance) }

  describe 'command metadata' do
    it 'has correct name' do
      expect(described_class.command_name).to eq('directory')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('businesses', 'shops', 'yellowpages')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:info)
    end
  end

  describe '#execute' do
    context 'with no shops in area' do
      it 'returns an error' do
        result = command.execute('')
        expect(result[:success]).to be false
        expect(result[:message]).to include('No businesses listed')
      end
    end

    context 'with shops in the area' do
      let!(:shop1) { Shop.create(room: room, name: "Bob's Hardware") }

      let!(:location2) { Location.create(name: 'Side Street', zone: area, location_type: 'outdoor') }
      let!(:room2) { Room.create(name: 'Alley', location: location2, short_description: 'A dark alley', room_type: 'standard') }
      let!(:shop2) { Shop.create(room: room2, name: "Jane's Clothing") }

      it 'lists all shops in the area' do
        result = command.execute('')
        expect(result[:success]).to be true
        expect(result[:message]).to include("Bob's Hardware")
        expect(result[:message]).to include("Jane's Clothing")
        expect(result[:message]).to include('2 business(es) listed')
      end

      it 'groups shops by location' do
        result = command.execute('')
        expect(result[:message]).to include('Main Street:')
        expect(result[:message]).to include('Side Street:')
      end

      it 'shows area name in header' do
        result = command.execute('')
        expect(result[:message]).to include('Business Directory - Downtown')
      end

      it 'includes structured data' do
        result = command.execute('')
        expect(result[:data][:action]).to eq('directory')
        expect(result[:data][:zone_id]).to eq(area.id)
        expect(result[:data][:count]).to eq(2)
        expect(result[:data][:businesses].length).to eq(2)
      end

      it 'includes shop details in structured data' do
        result = command.execute('')
        shop_data = result[:data][:businesses].find { |s| s[:name] == "Bob's Hardware" }
        expect(shop_data[:room_name]).to eq('Street Corner')
        expect(shop_data[:location_name]).to eq('Main Street')
      end
    end

    context 'with shops in a different area' do
      let!(:other_area) { create(:area, name: 'Uptown', zone_type: 'city') }
      let!(:other_location) { create(:location, zone: other_area, name: 'Park Ave', location_type: 'outdoor') }
      let!(:other_room) { create(:room, location: other_location, name: 'Park', short_description: 'A park') }
      let!(:other_shop) { create(:shop, room: other_room, name: "Uptown Shop") }

      it 'does not include shops from other areas' do
        result = command.execute('')
        expect(result[:success]).to be false
        expect(result[:message]).to include('No businesses listed')
      end
    end
  end
end
