# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../scripts/setup/helpers'

RSpec.describe SetupHelpers do
  include SetupHelpers

  # Factory automatically creates full world hierarchy
  let!(:room) { create(:room) }
  let!(:location) { room.location }
  let!(:area) { location.area }
  let!(:world) { area.world }
  let!(:universe) { world.universe }

  describe '#ensure_record' do
    it 'creates a new record when none exists' do
      unique_name = "Test Universe #{SecureRandom.hex(4)}"

      id = ensure_record(
        :universes,
        { name: unique_name },
        { description: 'Test description', theme: 'test' }
      )

      expect(id).to be_a(Integer)
      record = DB[:universes].first(id: id)
      expect(record[:name]).to eq(unique_name)
      expect(record[:description]).to eq('Test description')
    end

    it 'returns existing record ID when lookup matches' do
      existing_id = universe.id

      id = ensure_record(
        :universes,
        { name: universe.name },
        { description: 'Updated description' }
      )

      expect(id).to eq(existing_id)
    end

    it 'is idempotent - multiple calls return same ID' do
      unique_name = "Idempotent Test #{SecureRandom.hex(4)}"

      id1 = ensure_record(:universes, { name: unique_name }, { description: 'First' })
      id2 = ensure_record(:universes, { name: unique_name }, { description: 'Second' })

      expect(id1).to eq(id2)
    end
  end

  describe '#opposite_direction' do
    it 'returns south for north' do
      expect(opposite_direction('north')).to eq('south')
    end

    it 'returns north for south' do
      expect(opposite_direction('south')).to eq('north')
    end

    it 'returns west for east' do
      expect(opposite_direction('east')).to eq('west')
    end

    it 'returns east for west' do
      expect(opposite_direction('west')).to eq('east')
    end

    it 'returns down for up' do
      expect(opposite_direction('up')).to eq('down')
    end

    it 'returns up for down' do
      expect(opposite_direction('down')).to eq('up')
    end

    it 'returns southeast for northwest' do
      expect(opposite_direction('northwest')).to eq('southeast')
    end

    it 'returns southwest for northeast' do
      expect(opposite_direction('northeast')).to eq('southwest')
    end

    it 'returns northeast for southwest' do
      expect(opposite_direction('southwest')).to eq('northeast')
    end

    it 'returns northwest for southeast' do
      expect(opposite_direction('southeast')).to eq('northwest')
    end

    it 'returns out for in' do
      expect(opposite_direction('in')).to eq('out')
    end

    it 'returns in for out' do
      expect(opposite_direction('out')).to eq('in')
    end

    it 'returns the input for unknown direction (fallback for named exits)' do
      # Named exits like "garden" or "sideways" return themselves as opposite
      # This allows bidirectional exits with the same name in both directions
      expect(opposite_direction('sideways')).to eq('sideways')
    end
  end

  # NOTE: create_exit and create_bidirectional_exit methods have been removed.
  # Navigation now uses spatial adjacency calculated from room polygon geometry
  # via RoomAdjacencyService and RoomPassabilityService. The room_exits table
  # has been dropped in migration 298_drop_room_exits_table.rb.

  describe '#log' do
    it 'outputs message to stdout' do
      expect { log('Test message') }.to output(/Test message/).to_stdout
    end
  end
end
