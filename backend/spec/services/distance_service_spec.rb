# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DistanceService do
  describe '.calculate_distance' do
    context 'with no movement' do
      it 'returns 0' do
        expect(described_class.calculate_distance(0, 0, 0, 0, 0, 0)).to eq(0)
      end
    end

    context 'with horizontal movement only' do
      it 'calculates X distance correctly' do
        # Moving 10 units in X direction
        result = described_class.calculate_distance(0, 0, 0, 10, 0, 0)

        expect(result).to eq(10)
      end

      it 'calculates Y distance correctly' do
        # Moving 10 units in Y direction
        result = described_class.calculate_distance(0, 0, 0, 0, 10, 0)

        expect(result).to eq(10)
      end
    end

    context 'with diagonal movement (X > Y)' do
      it 'uses weighted diagonal formula' do
        # xdiff = 10, ydiff = 4, zdiff = 0
        # Result: 10 + 4/2 = 12
        result = described_class.calculate_distance(0, 0, 0, 10, 4, 0)

        expect(result).to eq(12.0)
      end
    end

    context 'with diagonal movement (Y > X)' do
      it 'uses weighted diagonal formula' do
        # xdiff = 4, ydiff = 10, zdiff = 0
        # Result: 10 + 4/2 = 12
        result = described_class.calculate_distance(0, 0, 0, 4, 10, 0)

        expect(result).to eq(12.0)
      end
    end

    context 'with Z movement (small horizontal movement)' do
      it 'uses expensive Z formula' do
        # zdiff = 2, xdiff = 10, ydiff = 10 (both < 100)
        # Result: 2 * 10 + 10 + 10 = 40
        result = described_class.calculate_distance(0, 0, 0, 10, 10, 2)

        expect(result).to eq(40)
      end
    end

    context 'with Z movement (large horizontal movement)' do
      it 'uses weighted formula with Z' do
        # zdiff = 2, xdiff = 150, ydiff = 10 (xdiff >= 100)
        # Result: xdiff + ydiff/2 + zdiff/2 = 150 + 5 + 1 = 156
        result = described_class.calculate_distance(0, 0, 0, 150, 10, 2)

        expect(result).to eq(156.0)
      end
    end

    context 'with negative coordinates' do
      it 'handles negative coordinates correctly' do
        # From -5,0,0 to 5,0,0 = distance of 10
        result = described_class.calculate_distance(-5, 0, 0, 5, 0, 0)

        expect(result).to eq(10)
      end
    end
  end

  describe '.time_for_distance' do
    it 'calculates base time correctly' do
      # 10 distance * 175ms = 1750ms
      result = described_class.time_for_distance(10)

      expect(result).to eq(10 * DistanceService::BASE_MS_PER_UNIT)
    end

    it 'applies speed multiplier' do
      # 10 distance * 175ms * 2.0 = 3500ms
      result = described_class.time_for_distance(10, 2.0)

      expect(result).to eq((10 * DistanceService::BASE_MS_PER_UNIT * 2.0).to_i)
    end

    it 'returns integer' do
      result = described_class.time_for_distance(10.5)

      expect(result).to be_a(Integer)
    end
  end

  describe '.time_to_exit' do
    let(:character_instance) do
      double('CharacterInstance',
             position: [50, 50, 5])
    end

    let(:room) do
      double('Room',
             min_x: 0.0, max_x: 100.0,
             min_y: 0.0, max_y: 100.0,
             min_z: 0.0, max_z: 10.0)
    end

    let(:dest_room) do
      double('DestRoom',
             min_x: 0.0, max_x: 100.0,
             min_y: 100.0, max_y: 200.0,
             min_z: 0.0, max_z: 10.0)
    end

    let(:room_exit) do
      double('RoomExit',
             direction: 'north',
             from_room: room,
             to_room: dest_room)
    end

    before do
      allow(room_exit).to receive(:respond_to?).with(:from_x).and_return(false)
    end

    it 'calculates time based on distance to exit' do
      result = described_class.time_to_exit(character_instance, room_exit)

      expect(result).to be > 0
    end

    it 'applies speed multiplier' do
      base_time = described_class.time_to_exit(character_instance, room_exit, 1.0)
      slow_time = described_class.time_to_exit(character_instance, room_exit, 2.0)

      expect(slow_time).to eq(base_time * 2)
    end
  end

  describe '.exit_position_in_room' do
    let(:room) do
      double('Room',
             min_x: 0.0, max_x: 100.0,
             min_y: 0.0, max_y: 100.0,
             min_z: 0.0, max_z: 10.0)
    end

    context 'with explicit exit position' do
      let(:room_exit) do
        double('RoomExit',
               from_x: 25.0,
               from_y: 75.0,
               from_z: 5.0,
               from_room: room)
      end

      before do
        allow(room_exit).to receive(:respond_to?).with(:from_x).and_return(true)
      end

      it 'uses explicit position' do
        result = described_class.exit_position_in_room(room_exit)

        expect(result).to eq([25.0, 75.0, 5.0])
      end
    end

    context 'without explicit exit position' do
      let(:dest_room) do
        double('DestRoom',
               min_x: 0.0, max_x: 100.0,
               min_y: 100.0, max_y: 200.0,
               min_z: 0.0, max_z: 10.0)
      end

      let(:room_exit) do
        double('RoomExit',
               direction: 'north',
               from_room: room,
               to_room: dest_room)
      end

      before do
        allow(room_exit).to receive(:respond_to?).with(:from_x).and_return(false)
      end

      it 'calculates boundary crossing point' do
        result = described_class.exit_position_in_room(room_exit)

        # Rooms share edge at y=100, x range 0-100 → midpoint (50, 100, 5)
        expect(result).to eq([50.0, 100.0, 5.0])
      end
    end
  end

  describe '.arrival_position' do
    let(:room) do
      double('Room',
             min_x: 0.0, max_x: 100.0,
             min_y: 0.0, max_y: 100.0,
             min_z: 0.0, max_z: 10.0)
    end

    context 'with explicit arrival position' do
      let(:room_exit) do
        double('RoomExit',
               to_x: 50.0,
               to_y: 0.0,
               to_z: 5.0,
               to_room: room)
      end

      before do
        allow(room_exit).to receive(:respond_to?).with(:to_x).and_return(true)
      end

      it 'uses explicit position' do
        result = described_class.arrival_position(room_exit)

        expect(result).to eq([50.0, 0.0, 5.0])
      end
    end

    context 'without explicit arrival position' do
      let(:from_room) do
        double('FromRoom',
               min_x: 0.0, max_x: 100.0,
               min_y: -100.0, max_y: 0.0,
               min_z: 0.0, max_z: 10.0)
      end

      let(:room_exit) do
        double('RoomExit',
               direction: 'north',
               from_room: from_room,
               to_room: room)
      end

      before do
        allow(room_exit).to receive(:respond_to?).with(:to_x).and_return(false)
      end

      it 'calculates boundary crossing point' do
        result = described_class.arrival_position(room_exit)

        # Rooms share edge at y=0, x range 0-100 → midpoint (50, 0, 5)
        expect(result).to eq([50.0, 0.0, 5.0])
      end
    end
  end

  describe '.wall_position' do
    let(:room) do
      double('Room',
             min_x: 0.0, max_x: 100.0,
             min_y: 0.0, max_y: 100.0,
             min_z: 0.0, max_z: 10.0)
    end

    it 'calculates north wall position' do
      result = described_class.wall_position(room, 'north')

      expect(result).to eq([50.0, 100.0, 5.0])
    end

    it 'calculates south wall position' do
      result = described_class.wall_position(room, 'south')

      expect(result).to eq([50.0, 0.0, 5.0])
    end

    it 'calculates east wall position' do
      result = described_class.wall_position(room, 'east')

      expect(result).to eq([100.0, 50.0, 5.0])
    end

    it 'calculates west wall position' do
      result = described_class.wall_position(room, 'west')

      expect(result).to eq([0.0, 50.0, 5.0])
    end

    it 'calculates up position' do
      result = described_class.wall_position(room, 'up')

      expect(result).to eq([50.0, 50.0, 10.0])
    end

    it 'calculates down position' do
      result = described_class.wall_position(room, 'down')

      expect(result).to eq([50.0, 50.0, 0.0])
    end

    it 'calculates northeast corner' do
      result = described_class.wall_position(room, 'northeast')

      expect(result).to eq([100.0, 100.0, 5.0])
    end

    it 'calculates northwest corner' do
      result = described_class.wall_position(room, 'northwest')

      expect(result).to eq([0.0, 100.0, 5.0])
    end

    it 'calculates southeast corner' do
      result = described_class.wall_position(room, 'southeast')

      expect(result).to eq([100.0, 0.0, 5.0])
    end

    it 'calculates southwest corner' do
      result = described_class.wall_position(room, 'southwest')

      expect(result).to eq([0.0, 0.0, 5.0])
    end

    it 'returns center for unknown direction' do
      result = described_class.wall_position(room, 'unknown')

      expect(result).to eq([50.0, 50.0, 5.0])
    end

    context 'with room lacking coordinate bounds' do
      let(:basic_room) { double('Room') }

      before do
        allow(basic_room).to receive(:respond_to?).and_return(false)
      end

      it 'uses default bounds' do
        result = described_class.wall_position(basic_room, 'north')

        expect(result).to eq([50.0, 100.0, 5.0]) # Default 0-100 x/y, 0-10 z
      end
    end
  end

  describe '.distance_to_wall' do
    let(:room) do
      double('Room',
             min_x: 0.0, max_x: 100.0,
             min_y: 0.0, max_y: 100.0,
             min_z: 0.0, max_z: 10.0)
    end

    let(:character_instance) do
      double('CharacterInstance',
             position: [50, 50, 5],
             current_room: room)
    end

    it 'calculates distance to north wall' do
      result = described_class.distance_to_wall(character_instance, 'north')

      expect(result).to eq(50.0)
    end

    it 'calculates distance to south wall' do
      result = described_class.distance_to_wall(character_instance, 'south')

      expect(result).to eq(50.0)
    end

    it 'calculates distance to east wall' do
      result = described_class.distance_to_wall(character_instance, 'east')

      expect(result).to eq(50.0)
    end
  end
end
