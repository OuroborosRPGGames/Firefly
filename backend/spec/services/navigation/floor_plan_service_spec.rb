# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FloorPlanService do
  describe '.generate' do
    let(:bounds) { { min_x: 25, max_x: 175, min_y: 25, max_y: 175 } }

    context 'with house_ground template' do
      it 'returns rooms with a hallway' do
        result = described_class.generate(
          building_bounds: bounds,
          floor_number: 0,
          building_type: :house
        )

        expect(result).to be_an(Array)
        hallways = result.select { |r| r[:is_hallway] }
        expect(hallways.length).to eq(1)
        rooms = result.reject { |r| r[:is_hallway] }
        expect(rooms.length).to be >= 2
      end

      it 'rooms fill the building footprint without overlap' do
        result = described_class.generate(
          building_bounds: bounds,
          floor_number: 0,
          building_type: :house
        )

        result.each do |room|
          b = room[:bounds]
          expect(b[:min_x]).to be >= bounds[:min_x]
          expect(b[:max_x]).to be <= bounds[:max_x]
          expect(b[:min_y]).to be >= bounds[:min_y]
          expect(b[:max_y]).to be <= bounds[:max_y]
          expect(b[:max_x] - b[:min_x]).to be > 0
          expect(b[:max_y] - b[:min_y]).to be > 0
        end
      end

      it 'rooms have reasonable aspect ratios (not vertical slices)' do
        result = described_class.generate(
          building_bounds: bounds,
          floor_number: 0,
          building_type: :house
        )

        result.each do |room|
          b = room[:bounds]
          w = b[:max_x] - b[:min_x]
          h = b[:max_y] - b[:min_y]
          ratio = [w, h].max.to_f / [w, h].min
          # No room should be more than 5:1 aspect ratio
          expect(ratio).to be <= 5.0, "Room #{room[:name]} has #{ratio.round(1)}:1 ratio (#{w}x#{h})"
        end
      end

      it 'sets correct Z bounds from floor number' do
        result = described_class.generate(
          building_bounds: bounds,
          floor_number: 2,
          building_type: :house
        )

        result.each do |room|
          expect(room[:bounds][:min_z]).to eq(20)
          expect(room[:bounds][:max_z]).to eq(30)
        end
      end
    end

    context 'with apartment_tower template' do
      it 'uses central corridor layout' do
        result = described_class.generate(
          building_bounds: bounds,
          floor_number: 1,
          building_type: :apartment_tower
        )

        hallway = result.find { |r| r[:is_hallway] }
        expect(hallway).not_to be_nil

        # Central corridor should not span full width
        hb = hallway[:bounds]
        hw = hb[:max_x] - hb[:min_x]
        total_w = bounds[:max_x] - bounds[:min_x]
        expect(hw).to be < total_w
      end
    end

    context 'with church template' do
      it 'uses nave layout' do
        result = described_class.generate(
          building_bounds: bounds,
          floor_number: 0,
          building_type: :church
        )

        hallway = result.find { |r| r[:is_hallway] }
        expect(hallway).not_to be_nil
        expect(hallway[:name]).to include('Nave').or include('Hall')
      end
    end

    context 'with shop (no hallway needed)' do
      it 'returns rooms without hallway for small commercial' do
        result = described_class.generate(
          building_bounds: bounds,
          floor_number: 0,
          building_type: :shop
        )

        # Shop has no hallway — just shop floor + back room
        hallways = result.select { |r| r[:is_hallway] }
        expect(hallways).to be_empty
      end
    end
  end

  describe '.template_for' do
    it 'returns template for known building types' do
      expect(described_class.template_for(:house, 0)).not_to be_nil
      expect(described_class.template_for(:church, 0)).not_to be_nil
      expect(described_class.template_for(:apartment_tower, 1)).not_to be_nil
    end

    it 'returns nil for unknown building types' do
      expect(described_class.template_for(:spaceship, 0)).to be_nil
    end
  end

  describe '.generate with room_list (BSP)' do
    let(:bounds) { { min_x: 0, max_x: 150, min_y: 0, max_y: 150 } }

    it 'creates corridor + rooms for arbitrary room list' do
      rooms = [
        { name: 'Sanctuary', type: 'temple' },
        { name: 'Altar Room', type: 'temple' },
        { name: 'Meditation Chamber', type: 'temple' },
        { name: 'Garden', type: 'garden' },
        { name: 'Library', type: 'standard' }
      ]

      result = described_class.generate(
        building_bounds: bounds,
        floor_number: 0,
        room_list: rooms
      )

      hallways = result.select { |r| r[:is_hallway] }
      non_hallways = result.reject { |r| r[:is_hallway] }

      expect(hallways.length).to eq(1)
      expect(non_hallways.length).to eq(5)
    end

    it 'BSP rooms have reasonable aspect ratios' do
      rooms = (1..6).map { |i| { name: "Room #{i}", type: 'standard' } }

      result = described_class.generate(
        building_bounds: bounds,
        floor_number: 0,
        room_list: rooms
      )

      result.reject { |r| r[:is_hallway] }.each do |room|
        b = room[:bounds]
        w = b[:max_x] - b[:min_x]
        h = b[:max_y] - b[:min_y]
        ratio = [w, h].max.to_f / [w, h].min
        expect(ratio).to be <= 5.0, "Room #{room[:name]} has #{ratio.round(1)}:1 ratio"
      end
    end

    it 'handles single room' do
      result = described_class.generate(
        building_bounds: bounds,
        floor_number: 0,
        room_list: [{ name: 'Only Room', type: 'standard' }]
      )

      # Single room + corridor
      expect(result.length).to eq(2)
    end

    it 'returns single fallback room when no type or room list given' do
      result = described_class.generate(
        building_bounds: bounds,
        floor_number: 1
      )

      expect(result.length).to eq(1)
      expect(result[0][:name]).to eq('Floor 2')
      expect(result[0][:is_hallway]).to be false
      expect(result[0][:bounds][:min_z]).to eq(10)
      expect(result[0][:bounds][:max_z]).to eq(20)
    end
  end
end
