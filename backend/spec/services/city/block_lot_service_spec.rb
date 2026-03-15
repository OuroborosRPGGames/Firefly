# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/city/block_lot_service'

RSpec.describe BlockLotService do
  # Standard 150x150 block starting at (25,25) — after a 25ft street
  let(:block_bounds) do
    { min_x: 25, max_x: 175, min_y: 25, max_y: 175, width: 150, height: 150 }
  end

  # Derived midpoints for a 150x150 block with 10ft alleys:
  #   mid_x = 25 + (150 - 10) / 2 = 95
  #   mid_y = 25 + (150 - 10) / 2 = 95
  let(:mid_x) { 95 }
  let(:mid_y) { 95 }

  describe 'ALLEY_WIDTH' do
    it 'is 10 feet' do
      expect(described_class::ALLEY_WIDTH).to eq(10)
    end
  end

  describe 'BLOCK_TYPES' do
    it 'contains all 8 block types' do
      expect(described_class::BLOCK_TYPES).to contain_exactly(
        :full, :half_ns, :half_ew, :quarters,
        :tee_north, :tee_south, :tee_east, :tee_west
      )
    end
  end

  # ========================================
  # .lot_bounds
  # ========================================
  describe '.lot_bounds' do
    context ':full block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :full) }

      it 'returns 1 lot' do
        expect(subject.size).to eq(1)
      end

      it 'has a single lot covering the entire block' do
        lot = subject[:full]
        expect(lot[:min_x]).to eq(25)
        expect(lot[:max_x]).to eq(175)
        expect(lot[:min_y]).to eq(25)
        expect(lot[:max_y]).to eq(175)
        expect(lot[:width]).to eq(150)
        expect(lot[:height]).to eq(150)
      end
    end

    context ':half_ns block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :half_ns) }

      it 'returns 2 lots (north and south)' do
        expect(subject.size).to eq(2)
        expect(subject.keys).to contain_exactly(:north, :south)
      end

      it 'has correct north lot dimensions (150x70)' do
        lot = subject[:north]
        expect(lot[:width]).to eq(150)
        expect(lot[:height]).to eq(70)
        expect(lot[:min_x]).to eq(25)
        expect(lot[:max_x]).to eq(175)
        expect(lot[:min_y]).to eq(mid_y + 10) # 105
        expect(lot[:max_y]).to eq(175)
      end

      it 'has correct south lot dimensions (150x70)' do
        lot = subject[:south]
        expect(lot[:width]).to eq(150)
        expect(lot[:height]).to eq(70)
        expect(lot[:min_x]).to eq(25)
        expect(lot[:max_x]).to eq(175)
        expect(lot[:min_y]).to eq(25)
        expect(lot[:max_y]).to eq(mid_y) # 95
      end

      it 'leaves a 10ft alley gap between lots' do
        gap = subject[:north][:min_y] - subject[:south][:max_y]
        expect(gap).to eq(10)
      end
    end

    context ':half_ew block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :half_ew) }

      it 'returns 2 lots (east and west)' do
        expect(subject.size).to eq(2)
        expect(subject.keys).to contain_exactly(:east, :west)
      end

      it 'has correct east lot dimensions (70x150)' do
        lot = subject[:east]
        expect(lot[:width]).to eq(70)
        expect(lot[:height]).to eq(150)
      end

      it 'has correct west lot dimensions (70x150)' do
        lot = subject[:west]
        expect(lot[:width]).to eq(70)
        expect(lot[:height]).to eq(150)
      end

      it 'leaves a 10ft alley gap between lots' do
        gap = subject[:east][:min_x] - subject[:west][:max_x]
        expect(gap).to eq(10)
      end
    end

    context ':quarters block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :quarters) }

      it 'returns 4 lots' do
        expect(subject.size).to eq(4)
        expect(subject.keys).to contain_exactly(:nw, :ne, :sw, :se)
      end

      it 'has all lots at 70x70' do
        subject.each do |_name, lot|
          expect(lot[:width]).to eq(70)
          expect(lot[:height]).to eq(70)
        end
      end

      it 'positions NW lot correctly' do
        lot = subject[:nw]
        expect(lot[:min_x]).to eq(25)
        expect(lot[:max_x]).to eq(95)
        expect(lot[:min_y]).to eq(105)
        expect(lot[:max_y]).to eq(175)
      end

      it 'positions NE lot correctly' do
        lot = subject[:ne]
        expect(lot[:min_x]).to eq(105)
        expect(lot[:max_x]).to eq(175)
        expect(lot[:min_y]).to eq(105)
        expect(lot[:max_y]).to eq(175)
      end

      it 'positions SW lot correctly' do
        lot = subject[:sw]
        expect(lot[:min_x]).to eq(25)
        expect(lot[:max_x]).to eq(95)
        expect(lot[:min_y]).to eq(25)
        expect(lot[:max_y]).to eq(95)
      end

      it 'positions SE lot correctly' do
        lot = subject[:se]
        expect(lot[:min_x]).to eq(105)
        expect(lot[:max_x]).to eq(175)
        expect(lot[:min_y]).to eq(25)
        expect(lot[:max_y]).to eq(95)
      end

      it 'leaves 10ft alley gaps between lots' do
        # Horizontal gap (N-S alley)
        expect(subject[:ne][:min_x] - subject[:nw][:max_x]).to eq(10)
        expect(subject[:se][:min_x] - subject[:sw][:max_x]).to eq(10)

        # Vertical gap (E-W alley)
        expect(subject[:nw][:min_y] - subject[:sw][:max_y]).to eq(10)
        expect(subject[:ne][:min_y] - subject[:se][:max_y]).to eq(10)
      end
    end

    context ':tee_north block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :tee_north) }

      it 'returns 3 lots (north, sw, se)' do
        expect(subject.size).to eq(3)
        expect(subject.keys).to contain_exactly(:north, :sw, :se)
      end

      it 'has north lot at 150x70' do
        lot = subject[:north]
        expect(lot[:width]).to eq(150)
        expect(lot[:height]).to eq(70)
      end

      it 'has sw and se lots at 70x70' do
        expect(subject[:sw][:width]).to eq(70)
        expect(subject[:sw][:height]).to eq(70)
        expect(subject[:se][:width]).to eq(70)
        expect(subject[:se][:height]).to eq(70)
      end
    end

    context ':tee_south block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :tee_south) }

      it 'returns 3 lots (nw, ne, south)' do
        expect(subject.size).to eq(3)
        expect(subject.keys).to contain_exactly(:nw, :ne, :south)
      end

      it 'has south lot at 150x70' do
        lot = subject[:south]
        expect(lot[:width]).to eq(150)
        expect(lot[:height]).to eq(70)
      end

      it 'has nw and ne lots at 70x70' do
        expect(subject[:nw][:width]).to eq(70)
        expect(subject[:nw][:height]).to eq(70)
        expect(subject[:ne][:width]).to eq(70)
        expect(subject[:ne][:height]).to eq(70)
      end
    end

    context ':tee_east block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :tee_east) }

      it 'returns 3 lots (nw, sw, east)' do
        expect(subject.size).to eq(3)
        expect(subject.keys).to contain_exactly(:nw, :sw, :east)
      end

      it 'has east lot at 70x150' do
        lot = subject[:east]
        expect(lot[:width]).to eq(70)
        expect(lot[:height]).to eq(150)
      end

      it 'has nw and sw lots at 70x70' do
        expect(subject[:nw][:width]).to eq(70)
        expect(subject[:nw][:height]).to eq(70)
        expect(subject[:sw][:width]).to eq(70)
        expect(subject[:sw][:height]).to eq(70)
      end
    end

    context ':tee_west block' do
      subject { described_class.lot_bounds(block_bounds: block_bounds, block_type: :tee_west) }

      it 'returns 3 lots (west, ne, se)' do
        expect(subject.size).to eq(3)
        expect(subject.keys).to contain_exactly(:west, :ne, :se)
      end

      it 'has west lot at 70x150' do
        lot = subject[:west]
        expect(lot[:width]).to eq(70)
        expect(lot[:height]).to eq(150)
      end

      it 'has ne and se lots at 70x70' do
        expect(subject[:ne][:width]).to eq(70)
        expect(subject[:ne][:height]).to eq(70)
        expect(subject[:se][:width]).to eq(70)
        expect(subject[:se][:height]).to eq(70)
      end
    end

    context 'with custom max_height' do
      it 'applies max_height to all lots' do
        lots = described_class.lot_bounds(block_bounds: block_bounds, block_type: :quarters, max_height: 300)
        lots.each_value do |lot|
          expect(lot[:max_z]).to eq(300)
        end
      end
    end

    context 'with unknown block type' do
      it 'falls back to :full' do
        lots = described_class.lot_bounds(block_bounds: block_bounds, block_type: :nonexistent)
        expect(lots.size).to eq(1)
        expect(lots).to have_key(:full)
      end
    end
  end

  # ========================================
  # .alley_bounds
  # ========================================
  describe '.alley_bounds' do
    context ':full block' do
      it 'returns no alleys' do
        alleys = described_class.alley_bounds(block_bounds: block_bounds, block_type: :full)
        expect(alleys).to be_empty
      end
    end

    context ':half_ns block' do
      subject { described_class.alley_bounds(block_bounds: block_bounds, block_type: :half_ns) }

      it 'returns 1 E-W alley' do
        expect(subject.size).to eq(1)
        expect(subject.first[:orientation]).to eq(:ew)
      end

      it 'alley is 10ft wide and spans full block width' do
        alley = subject.first
        expect(alley[:max_y] - alley[:min_y]).to eq(10)
        expect(alley[:max_x] - alley[:min_x]).to eq(150)
      end
    end

    context ':half_ew block' do
      subject { described_class.alley_bounds(block_bounds: block_bounds, block_type: :half_ew) }

      it 'returns 1 N-S alley' do
        expect(subject.size).to eq(1)
        expect(subject.first[:orientation]).to eq(:ns)
      end

      it 'alley is 10ft wide and spans full block height' do
        alley = subject.first
        expect(alley[:max_x] - alley[:min_x]).to eq(10)
        expect(alley[:max_y] - alley[:min_y]).to eq(150)
      end
    end

    context ':quarters block' do
      subject { described_class.alley_bounds(block_bounds: block_bounds, block_type: :quarters) }

      it 'returns 2 alleys (cross pattern)' do
        expect(subject.size).to eq(2)
        orientations = subject.map { |a| a[:orientation] }
        expect(orientations).to contain_exactly(:ew, :ns)
      end

      it 'both alleys are 10ft wide' do
        ew_alley = subject.find { |a| a[:orientation] == :ew }
        ns_alley = subject.find { |a| a[:orientation] == :ns }

        expect(ew_alley[:max_y] - ew_alley[:min_y]).to eq(10)
        expect(ns_alley[:max_x] - ns_alley[:min_x]).to eq(10)
      end
    end

    context ':tee_north block' do
      subject { described_class.alley_bounds(block_bounds: block_bounds, block_type: :tee_north) }

      it 'returns 2 alleys' do
        expect(subject.size).to eq(2)
      end

      it 'has full-width E-W alley' do
        ew = subject.find { |a| a[:orientation] == :ew }
        expect(ew[:max_x] - ew[:min_x]).to eq(150)
      end

      it 'has partial N-S alley on south half only' do
        ns = subject.find { |a| a[:orientation] == :ns }
        expect(ns[:min_y]).to eq(25)   # Block min_y
        expect(ns[:max_y]).to eq(mid_y) # Stops at E-W alley
      end
    end

    context ':tee_south block' do
      subject { described_class.alley_bounds(block_bounds: block_bounds, block_type: :tee_south) }

      it 'has partial N-S alley on north half only' do
        ns = subject.find { |a| a[:orientation] == :ns }
        expect(ns[:min_y]).to eq(mid_y + 10) # Starts after E-W alley
        expect(ns[:max_y]).to eq(175)         # Block max_y
      end
    end

    context ':tee_east block' do
      subject { described_class.alley_bounds(block_bounds: block_bounds, block_type: :tee_east) }

      it 'has full-height N-S alley' do
        ns = subject.find { |a| a[:orientation] == :ns }
        expect(ns[:max_y] - ns[:min_y]).to eq(150)
      end

      it 'has partial E-W alley on west half only' do
        ew = subject.find { |a| a[:orientation] == :ew }
        expect(ew[:min_x]).to eq(25)     # Block min_x
        expect(ew[:max_x]).to eq(mid_x)  # Stops at N-S alley
      end
    end

    context ':tee_west block' do
      subject { described_class.alley_bounds(block_bounds: block_bounds, block_type: :tee_west) }

      it 'has full-height N-S alley' do
        ns = subject.find { |a| a[:orientation] == :ns }
        expect(ns[:max_y] - ns[:min_y]).to eq(150)
      end

      it 'has partial E-W alley on east half only' do
        ew = subject.find { |a| a[:orientation] == :ew }
        expect(ew[:min_x]).to eq(mid_x + 10) # Starts after N-S alley
        expect(ew[:max_x]).to eq(175)          # Block max_x
      end
    end

    context 'with unknown block type' do
      it 'returns empty array' do
        alleys = described_class.alley_bounds(block_bounds: block_bounds, block_type: :nonexistent)
        expect(alleys).to eq([])
      end
    end
  end

  # ========================================
  # .lot_size_for_building
  # ========================================
  describe '.lot_size_for_building' do
    context 'small buildings' do
      %w[shop house brownstone apartment_tower cafe bar restaurant church
         temple clinic cottage townhouse fire_station police_station
         library gym cinema gas_station subway_entrance terrace condo_tower].each do |type|
        it "classifies #{type} as :small" do
          expect(described_class.lot_size_for_building(type)).to eq(:small)
        end
      end
    end

    context 'large buildings' do
      %w[warehouse parking_garage school hospital mall hotel office_tower
         park playground garden].each do |type|
        it "classifies #{type} as :large" do
          expect(described_class.lot_size_for_building(type)).to eq(:large)
        end
      end
    end

    context 'full-block buildings' do
      %w[palace castle cathedral sports_field plaza courtyard government large_park].each do |type|
        it "classifies #{type} as :full_block" do
          expect(described_class.lot_size_for_building(type)).to eq(:full_block)
        end
      end
    end

    context 'unknown building type' do
      it 'defaults to :small' do
        expect(described_class.lot_size_for_building(:unknown_building)).to eq(:small)
      end
    end

    it 'accepts string arguments' do
      expect(described_class.lot_size_for_building('warehouse')).to eq(:large)
    end
  end

  # ========================================
  # .plan_blocks
  # ========================================
  describe '.plan_blocks' do
    context 'full-block buildings' do
      it 'assigns one :full block per full-block building' do
        result = described_class.plan_blocks(
          buildings: [:palace, :cathedral],
          available_blocks: 5,
          city_size: :town
        )

        full_assignments = result.select { |a| a[:buildings].include?(:palace) || a[:buildings].include?(:cathedral) }
        expect(full_assignments.size).to eq(2)
        full_assignments.each do |a|
          expect(a[:block_type]).to eq(:full)
        end
      end
    end

    context 'large building pairing' do
      it 'pairs two large buildings into a half block' do
        result = described_class.plan_blocks(
          buildings: [:warehouse, :school],
          available_blocks: 5,
          city_size: :town
        )

        paired = result.find { |a| a[:buildings].include?(:warehouse) && a[:buildings].include?(:school) }
        expect(paired).not_to be_nil
        expect([:half_ns, :half_ew]).to include(paired[:block_type])
      end
    end

    context 'odd large building with smalls' do
      it 'puts odd large building in a tee block with smalls' do
        result = described_class.plan_blocks(
          buildings: [:warehouse, :shop, :cafe],
          available_blocks: 5,
          city_size: :town
        )

        tee = result.find { |a| a[:buildings].include?(:warehouse) }
        expect(tee).not_to be_nil
        expect([:tee_north, :tee_south, :tee_east, :tee_west]).to include(tee[:block_type])
        expect(tee[:buildings].size).to be >= 2
      end
    end

    context 'small buildings' do
      it 'packs up to 4 smalls per quarters block' do
        result = described_class.plan_blocks(
          buildings: [:shop, :cafe, :bar, :house],
          available_blocks: 5,
          city_size: :town
        )

        quarters = result.find { |a| a[:block_type] == :quarters }
        expect(quarters).not_to be_nil
        expect(quarters[:buildings].size).to be <= 4
      end
    end

    context 'empty block fill' do
      it 'fills remaining blocks with green space or vacant' do
        result = described_class.plan_blocks(
          buildings: [:shop],
          available_blocks: 5,
          city_size: :town
        )

        # 1 block for the shop (in quarters), 4 remaining blocks should be filled
        expect(result.size).to eq(5)
        fill_blocks = result.reject { |a| a[:buildings].include?(:shop) }
        fill_blocks.each do |block|
          expect(block[:block_type]).to eq(:full)
          building = block[:buildings].first
          expect([:vacant, :garden, :park, :plaza, :playground]).to include(building)
        end
      end
    end

    context 'block limit' do
      it 'does not exceed available_blocks' do
        result = described_class.plan_blocks(
          buildings: Array.new(20, :shop),
          available_blocks: 3,
          city_size: :medium
        )

        expect(result.size).to be <= 3
      end
    end

    context 'green space ratio varies by city_size' do
      it 'uses the correct ratio for the given city_size' do
        # With 100 empty blocks and a known ratio, we can check distribution
        old_seed = srand(42) # deterministic for test
        begin
          result = described_class.plan_blocks(
            buildings: [],
            available_blocks: 100,
            city_size: :village
          )

          green_count = result.count { |a| !a[:buildings].include?(:vacant) }
          # Village ratio is 0.7, so roughly 70% should be green
          # Allow some variance since it's random
          expect(green_count).to be_between(50, 90)
        ensure
          srand(old_seed)
        end
      end
    end

    it 'converts string building types to symbols' do
      result = described_class.plan_blocks(
        buildings: ['palace', 'shop'],
        available_blocks: 5,
        city_size: :town
      )

      palace_block = result.find { |a| a[:buildings].include?(:palace) }
      expect(palace_block).not_to be_nil
    end
  end

  # ========================================
  # .create_alleys (DB-dependent)
  # ========================================
  describe '.create_alleys' do
    include TestHelpers

    let(:hierarchy) { create_test_world_hierarchy }
    let(:location) { hierarchy[:location] }

    context 'with :quarters block type' do
      it 'creates 2 alley rooms' do
        rooms = described_class.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: :quarters,
          grid_x: 0,
          grid_y: 0
        )

        expect(rooms.size).to eq(2)
      end

      it 'creates rooms with correct attributes' do
        rooms = described_class.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: :quarters,
          grid_x: 2,
          grid_y: 3
        )

        rooms.each do |room|
          expect(room.room_type).to eq('alley')
          expect(room.city_role).to eq('alley')
          expect(room.grid_x).to eq(2)
          expect(room.grid_y).to eq(3)
          expect(room.location_id).to eq(location.id)
        end
      end

      it 'names alleys with grid position and index' do
        rooms = described_class.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: :quarters,
          grid_x: 1,
          grid_y: 2
        )

        names = rooms.map(&:name)
        expect(names).to include('Alley 1,2 #1')
        expect(names).to include('Alley 1,2 #2')
      end

      it 'sets correct bounds on alley rooms' do
        rooms = described_class.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: :quarters,
          grid_x: 0,
          grid_y: 0
        )

        # The E-W alley should be 10ft tall (wide in the Y direction)
        ew_alley = rooms.find { |r| r.name.include?('#1') }
        expect(ew_alley.max_y - ew_alley.min_y).to eq(10)

        # The N-S alley should be 10ft wide (in the X direction)
        ns_alley = rooms.find { |r| r.name.include?('#2') }
        expect(ns_alley.max_x - ns_alley.min_x).to eq(10)
      end
    end

    context 'with :full block type' do
      it 'creates no alley rooms' do
        rooms = described_class.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: :full,
          grid_x: 0,
          grid_y: 0
        )

        expect(rooms).to be_empty
      end
    end

    context 'with :half_ns block type' do
      it 'creates 1 alley room' do
        rooms = described_class.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: :half_ns,
          grid_x: 0,
          grid_y: 0
        )

        expect(rooms.size).to eq(1)
        expect(rooms.first.name).to eq('Alley 0,0')
      end
    end

    context 'with :tee_north block type' do
      it 'creates 2 alley rooms' do
        rooms = described_class.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: :tee_north,
          grid_x: 0,
          grid_y: 0
        )

        expect(rooms.size).to eq(2)
      end
    end
  end
end
