# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatPathfindingService do
  let(:room) { create(:room) }
  let(:fight) { create(:fight, room: room, arena_width: 10, arena_height: 10) }
  let(:participant) { create(:fight_participant, fight: fight, hex_x: 0, hex_y: 0) }
  let(:service) { described_class.new(fight, participant) }

  describe 'constants' do
    it 'defines MAX_PATH_LENGTH' do
      expect(described_class::MAX_PATH_LENGTH).to eq(200)
    end

    it 'defines HAZARD_AVOIDANCE_COSTS' do
      expect(described_class::HAZARD_AVOIDANCE_COSTS).to include(:ignore, :low, :moderate, :high)
    end
  end

  describe '.find_path' do
    it 'finds path between two points' do
      path = described_class.find_path(
        fight: fight,
        start_x: 0, start_y: 0,
        goal_x: 2, goal_y: 0,
        participant: participant
      )

      expect(path).to be_an(Array)
    end

    it 'returns empty array when already at goal' do
      path = described_class.find_path(
        fight: fight,
        start_x: 5, start_y: 4,
        goal_x: 5, goal_y: 4,
        participant: participant
      )

      expect(path).to eq([])
    end
  end

  describe '.next_steps' do
    it 'returns steps within movement budget' do
      steps = described_class.next_steps(
        fight: fight,
        participant: participant,
        target_x: 5,
        target_y: 0,
        movement_budget: 2
      )

      expect(steps).to be_an(Array)
      expect(steps.length).to be <= 2
    end

    it 'returns empty when no path exists' do
      steps = described_class.next_steps(
        fight: fight,
        participant: participant,
        target_x: participant.hex_x,
        target_y: participant.hex_y,
        movement_budget: 3
      )

      expect(steps).to eq([])
    end
  end

  describe '.path_cost' do
    it 'returns 0 for empty path' do
      cost = described_class.path_cost(
        fight: fight,
        path: [],
        participant: participant
      )

      expect(cost).to eq(0.0)
    end

    it 'calculates cost for path' do
      path = [[1, 0], [2, 0]]
      cost = described_class.path_cost(
        fight: fight,
        path: path,
        participant: participant
      )

      expect(cost).to be_a(Float)
    end
  end

  describe 'instance methods' do
    describe '#find_path' do
      it 'uses A* algorithm' do
        path = service.find_path(0, 0, 3, 0)

        # Path should not include start, but include destination
        expect(path).not_to include([0, 0])
      end

      it 'returns empty array when start equals goal' do
        path = service.find_path(5, 4, 5, 4)
        expect(path).to eq([])
      end
    end

    describe '#steps_within_budget' do
      it 'returns steps up to budget' do
        path = [[1, 0], [2, 0], [3, 0], [4, 0]]
        steps = service.steps_within_budget(path, 2, 0, 0)

        expect(steps.length).to be <= 2
      end

      it 'returns empty for empty path' do
        steps = service.steps_within_budget([], 5, 0, 0)
        expect(steps).to eq([])
      end
    end

    describe '#calculate_path_cost' do
      it 'returns 0 for empty path' do
        cost = service.calculate_path_cost([])
        expect(cost).to eq(0.0)
      end

      it 'sums costs for path segments' do
        path = [[1, 0], [2, 0]]
        cost = service.calculate_path_cost(path)

        expect(cost).to be >= 0.0
      end
    end
  end

  describe 'PriorityQueue' do
    let(:queue) { described_class::PriorityQueue.new }

    it 'initializes empty' do
      expect(queue.any?).to be false
    end

    it 'pushes and pops items by priority' do
      queue.push('high', 10)
      queue.push('low', 1)
      queue.push('medium', 5)

      expect(queue.pop).to eq('low')
      expect(queue.pop).to eq('medium')
      expect(queue.pop).to eq('high')
    end

    it 'returns nil when empty' do
      expect(queue.pop).to be_nil
    end

    it 'reports any? correctly' do
      expect(queue.any?).to be false
      queue.push('item', 1)
      expect(queue.any?).to be true
    end
  end

  describe 'arena bounds checking' do
    it 'respects arena width' do
      # Path should stay within arena bounds
      path = service.find_path(0, 0, 15, 0) # 15 is outside arena_width of 10
      # Path should either be empty or stay in bounds
      path.each do |x, _y|
        expect(x).to be < fight.arena_width
      end
    end
  end

  describe '#movement_cost_between (pixel edge passability)' do
    let(:from_hex) do
      double('RoomHex',
             hex_x: 0, hex_y: 0,
             passable_edges: nil,
             blocks_movement?: false,
             provides_cover?: false,
             cover_object: nil,
             dangerous?: false,
             calculated_movement_cost: 1.0,
             can_transition_to?: true,
             elevation_level: 0,
             is_ramp: false, is_stairs: false)
    end

    context 'hex with passable_edges data (pixel mask present)' do
      let(:hex_with_edges) do
        double('RoomHex',
               hex_x: 1, hex_y: 0,
               hex_type: 'wall',
               blocks_movement?: false,
               provides_cover?: false,
               cover_object: nil,
               dangerous?: false,
               calculated_movement_cost: 1.0,
               can_transition_to?: true,
               elevation_level: 0,
               is_ramp: false, is_stairs: false)
      end

      before do
        # passable_edges are only authoritative when a wall mask exists
        allow(service).to receive(:wall_mask_service).and_return(double('WallMaskService'))
      end

      context 'when passable_from? returns true for that direction' do
        before do
          allow(hex_with_edges).to receive(:passable_edges).and_return(8)  # S-bit set
          allow(hex_with_edges).to receive(:passable_from?).and_return(true)
        end

        it 'returns finite movement cost (pixel data governs, not hex_type)' do
          cost = service.send(:movement_cost_between, from_hex, hex_with_edges)
          expect(cost).to be_finite
        end
      end

      context 'when passable_from? returns false (edge blocked by pixel)' do
        before do
          allow(hex_with_edges).to receive(:passable_edges).and_return(0)
          allow(hex_with_edges).to receive(:passable_from?).and_return(false)
        end

        it 'returns infinity' do
          cost = service.send(:movement_cost_between, from_hex, hex_with_edges)
          expect(cost).to eq(Float::INFINITY)
        end
      end
    end

    context 'wall hex WITHOUT pixel data (no mask)' do
      let(:plain_wall_hex) do
        double('RoomHex',
               hex_x: 1, hex_y: 0,
               hex_type: 'wall',
               passable_edges: nil,
               blocks_movement?: true,
               provides_cover?: false,
               cover_object: nil,
               dangerous?: false)
      end

      it 'falls back to blocks_movement? and returns infinity' do
        cost = service.send(:movement_cost_between, from_hex, plain_wall_hex)
        expect(cost).to eq(Float::INFINITY)
      end
    end

    context 'wall hex WITH passable_edges but no wall mask service' do
      let(:stale_edge_hex) do
        double('RoomHex',
               hex_x: 1, hex_y: 0,
               hex_type: 'wall',
               passable_edges: 63,
               blocks_movement?: true,
               provides_cover?: false,
               cover_object: nil,
               dangerous?: false)
      end

      before do
        allow(service).to receive(:wall_mask_service).and_return(nil)
      end

      it 'ignores edge bits and falls back to hex-level blocking' do
        cost = service.send(:movement_cost_between, from_hex, stale_edge_hex)
        expect(cost).to eq(Float::INFINITY)
      end
    end

    context 'normal hex WITHOUT pixel data' do
      let(:normal_hex) do
        double('RoomHex',
               hex_x: 1, hex_y: 0,
               hex_type: 'normal',
               passable_edges: nil,
               blocks_movement?: false,
               provides_cover?: false,
               cover_object: nil,
               dangerous?: false,
               calculated_movement_cost: 1.0,
               can_transition_to?: true,
               elevation_level: 0,
               is_ramp: false, is_stairs: false)
      end

      it 'falls back to hex-level and returns finite cost' do
        cost = service.send(:movement_cost_between, from_hex, normal_hex)
        expect(cost).to be_finite
      end
    end
  end

  describe '#direction_between' do
    it 'returns N for hex directly north' do
      from = double(hex_x: 0, hex_y: 0)
      to   = double(hex_x: 0, hex_y: 4)
      expect(service.send(:direction_between, from, to)).to eq('N')
    end

    it 'returns S for hex directly south' do
      from = double(hex_x: 0, hex_y: 4)
      to   = double(hex_x: 0, hex_y: 0)
      expect(service.send(:direction_between, from, to)).to eq('S')
    end

    it 'returns NE for NE neighbor' do
      from = double(hex_x: 0, hex_y: 0)
      to   = double(hex_x: 1, hex_y: 2)
      expect(service.send(:direction_between, from, to)).to eq('NE')
    end

    it 'returns nil for non-neighbor hex' do
      from = double(hex_x: 0, hex_y: 0)
      to   = double(hex_x: 5, hex_y: 5)
      expect(service.send(:direction_between, from, to)).to be_nil
    end
  end
end
