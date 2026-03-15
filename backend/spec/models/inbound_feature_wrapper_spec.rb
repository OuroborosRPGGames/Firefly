# frozen_string_literal: true

require 'spec_helper'

RSpec.describe InboundFeatureWrapper do
  describe 'direction and orientation mapping' do
    it 'flips direction and orientation by default' do
      feature = create(:room_feature, direction: 'north', orientation: 'east')
      wrapped = described_class.new(feature)

      expect(wrapped.direction).to eq('south')
      expect(wrapped.orientation).to eq('west')
    end

    it 'uses inferred_direction override for both values' do
      feature = create(:room_feature, direction: 'north', orientation: 'east')
      wrapped = described_class.new(feature, inferred_direction: 'up')

      expect(wrapped.direction).to eq('up')
      expect(wrapped.orientation).to eq('up')
    end
  end

  describe 'delegation and metadata' do
    it 'returns inbound metadata and connected room details' do
      room = create(:room)
      feature = create(:room_feature, room: room)
      wrapped = described_class.new(feature)

      expect(wrapped.connected_room_id).to eq(room.id)
      expect(wrapped.connected_room).to eq(room)
      expect(wrapped.inbound?).to be true
      expect(wrapped.source_feature).to eq(feature)
    end

    it 'delegates unknown methods to the wrapped feature' do
      feature = create(:room_feature, name: 'North Door')
      wrapped = described_class.new(feature)

      expect(wrapped.name).to eq('North Door')
    end
  end
end
