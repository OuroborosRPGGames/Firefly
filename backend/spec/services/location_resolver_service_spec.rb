# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LocationResolverService do
  let(:world) { create(:world, name: 'Test World') }
  let(:area) do
    create(:area,
           world: world,
           name: 'Test Area',
           zone_type: 'city',
           danger_level: 1,
           min_longitude: -10,
           max_longitude: 10,
           min_latitude: -10,
           max_latitude: 10)
  end

  describe 'constants' do
    it 'defines DEFAULT_WORLD_NAME' do
      expect(described_class::DEFAULT_WORLD_NAME).to eq('Default World')
    end

    it 'defines DEFAULT_ZONE_NAME' do
      expect(described_class::DEFAULT_ZONE_NAME).to eq('Generated Zone')
    end
  end

  describe '.resolve' do
    let(:longitude) { 0.0 }
    let(:latitude) { 0.0 }
    let(:name) { 'Test Building' }

    context 'with valid coordinates' do
      before do
        # Ensure area exists
        area
      end

      it 'returns success' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          world: world
        )
        expect(result[:success]).to be true
      end

      it 'returns a location' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          world: world
        )
        expect(result[:location]).to be_a(Location)
      end

      it 'sets created flag for new locations' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          world: world
        )
        expect(result[:created]).to be true
      end

      it 'returns the area' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          world: world
        )
        expect(result[:zone]).to be_a(Area)
      end
    end

    context 'with existing location by name' do
      let!(:existing_location) do
        create(:location, zone: area, name: name, longitude: longitude, latitude: latitude)
      end

      it 'returns existing location' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          world: world
        )
        expect(result[:location]).to eq(existing_location)
        expect(result[:created]).to be false
      end
    end

    context 'with invalid coordinates' do
      it 'rejects longitude outside range' do
        result = described_class.resolve(
          longitude: -181,
          latitude: latitude,
          name: name
        )
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid coordinates')
      end

      it 'rejects latitude outside range' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: 91,
          name: name
        )
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid coordinates')
      end

      it 'rejects non-numeric longitude' do
        result = described_class.resolve(
          longitude: 'invalid',
          latitude: latitude,
          name: name
        )
        expect(result[:success]).to be false
      end

      it 'rejects non-numeric latitude' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: nil,
          name: name
        )
        expect(result[:success]).to be false
      end
    end

    context 'with specific world' do
      let(:custom_world) { create(:world, name: 'Custom World') }

      before do
        create(:area,
               world: custom_world,
               min_longitude: -10,
               max_longitude: 10,
               min_latitude: -10,
               max_latitude: 10)
      end

      it 'uses provided world' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          world: custom_world
        )
        expect(result[:zone].world).to eq(custom_world)
      end
    end

    context 'with location_type' do
      before { area }

      it 'uses provided location type' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          location_type: 'outdoor',
          world: world
        )
        expect(result[:location].location_type).to eq('outdoor')
      end

      it 'defaults to building' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name,
          world: world
        )
        expect(result[:location].location_type).to eq('building')
      end
    end

    context 'when no area exists for coordinates' do
      let(:far_longitude) { 100.0 }
      let(:far_latitude) { 50.0 }

      it 'creates new area' do
        expect {
          described_class.resolve(
            longitude: far_longitude,
            latitude: far_latitude,
            name: name,
            world: world
          )
        }.to change(Area, :count).by(1)
      end

      it 'creates area with options' do
        result = described_class.resolve(
          longitude: far_longitude,
          latitude: far_latitude,
          name: name,
          world: world,
          options: { zone_name: 'Custom Area', zone_type: 'wilderness', danger_level: 5 }
        )
        expect(result[:zone].name).to eq('Custom Area')
        expect(result[:zone].zone_type).to eq('wilderness')
        expect(result[:zone].danger_level).to eq(5)
      end
    end

    context 'when error occurs' do
      before do
        allow(World).to receive(:first).and_raise(StandardError, 'Database error')
      end

      it 'returns error hash' do
        result = described_class.resolve(
          longitude: longitude,
          latitude: latitude,
          name: name
        )
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Database error')
      end
    end
  end

  describe '.find_by_coordinates' do
    let(:longitude) { 5.0 }
    let(:latitude) { 5.0 }

    before { area }

    context 'with existing location' do
      let!(:location) do
        create(:location, zone: area, name: 'Found Location', longitude: longitude, latitude: latitude)
      end

      it 'finds location within tolerance' do
        result = described_class.find_by_coordinates(
          longitude: longitude + 0.0005,
          latitude: latitude - 0.0005
        )
        expect(result).to eq(location)
      end

      it 'returns nil for location outside tolerance' do
        result = described_class.find_by_coordinates(
          longitude: longitude + 0.5,
          latitude: latitude
        )
        expect(result).to be_nil
      end
    end

    context 'with custom tolerance' do
      let!(:location) do
        create(:location, zone: area, name: 'Found Location', longitude: longitude, latitude: latitude)
      end

      it 'respects custom tolerance' do
        result = described_class.find_by_coordinates(
          longitude: longitude + 0.01,
          latitude: latitude,
          tolerance: 0.1
        )
        expect(result).to eq(location)
      end
    end

    context 'without existing location' do
      it 'returns nil' do
        result = described_class.find_by_coordinates(
          longitude: longitude,
          latitude: latitude
        )
        expect(result).to be_nil
      end
    end

    context 'outside any area' do
      it 'returns nil' do
        result = described_class.find_by_coordinates(
          longitude: 150.0,
          latitude: 60.0
        )
        expect(result).to be_nil
      end
    end
  end

  describe 'private methods' do
    describe '#valid_coordinates?' do
      it 'validates longitude range' do
        expect(described_class.send(:valid_coordinates?, -180, 0)).to be true
        expect(described_class.send(:valid_coordinates?, 180, 0)).to be true
        expect(described_class.send(:valid_coordinates?, -181, 0)).to be false
        expect(described_class.send(:valid_coordinates?, 181, 0)).to be false
      end

      it 'validates latitude range' do
        expect(described_class.send(:valid_coordinates?, 0, -90)).to be true
        expect(described_class.send(:valid_coordinates?, 0, 90)).to be true
        expect(described_class.send(:valid_coordinates?, 0, -91)).to be false
        expect(described_class.send(:valid_coordinates?, 0, 91)).to be false
      end

      it 'requires numeric values' do
        expect(described_class.send(:valid_coordinates?, 'invalid', 0)).to be false
        expect(described_class.send(:valid_coordinates?, 0, nil)).to be false
      end

      it 'accepts integers and floats' do
        expect(described_class.send(:valid_coordinates?, 50, 30)).to be true
        expect(described_class.send(:valid_coordinates?, 50.5, 30.5)).to be true
      end
    end
  end
end
