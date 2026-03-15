# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveVisibilityService do
  let(:current_room) do
    instance_double('DelveRoom',
                    id: 1,
                    grid_x: 5,
                    grid_y: 5,
                    level: 1,
                    explored?: true,
                    has_monster?: false,
                    is_exit: false,
                    room_type: 'corridor')
  end
  let(:nearby_room) do
    instance_double('DelveRoom',
                    id: 2,
                    grid_x: 6,
                    grid_y: 5,
                    level: 1,
                    explored?: true,
                    has_monster?: true,
                    is_exit: false,
                    room_type: 'branch')
  end
  let(:far_room) do
    instance_double('DelveRoom',
                    id: 3,
                    grid_x: 10,
                    grid_y: 10,
                    level: 1,
                    explored?: false,
                    has_monster?: false,
                    is_exit: false,
                    room_type: 'corridor')
  end
  let(:exit_room) do
    instance_double('DelveRoom',
                    id: 4,
                    grid_x: 7,
                    grid_y: 5,
                    level: 1,
                    explored?: false,
                    has_monster?: false,
                    is_exit: true,
                    room_type: 'terminal')
  end
  let(:delve) do
    instance_double('Delve')
  end
  let(:participant) do
    instance_double('DelveParticipant',
                    current_room: current_room,
                    delve: delve)
  end

  describe 'constants' do
    it 'defines DANGER_VISIBILITY_RANGE' do
      expect(described_class::DANGER_VISIBILITY_RANGE).to eq(3)
    end
  end

  describe 'class methods' do
    it 'responds to visible_rooms' do
      expect(described_class).to respond_to(:visible_rooms)
    end

    it 'responds to can_see_contents?' do
      expect(described_class).to respond_to(:can_see_contents?)
    end

    it 'responds to can_see_danger?' do
      expect(described_class).to respond_to(:can_see_danger?)
    end

    it 'responds to revealed_rooms' do
      expect(described_class).to respond_to(:revealed_rooms)
    end

    it 'responds to danger_warnings' do
      expect(described_class).to respond_to(:danger_warnings)
    end
  end

  describe '.visible_rooms' do
    before do
      allow(delve).to receive(:rooms_on_level).and_return(
        double(all: [current_room, nearby_room, far_room])
      )
    end

    it 'returns empty array if no current room' do
      allow(participant).to receive(:current_room).and_return(nil)
      result = described_class.visible_rooms(participant)
      expect(result).to eq([])
    end

    it 'returns array of room visibility data' do
      result = described_class.visible_rooms(participant)
      expect(result).to be_an(Array)
      expect(result.first).to include(:room, :grid_x, :grid_y, :distance, :visibility)
    end

    it 'marks current room with full visibility' do
      result = described_class.visible_rooms(participant)
      current = result.find { |r| r[:room] == current_room }
      expect(current[:visibility]).to eq(:full)
      expect(current[:show_contents]).to be true
    end

    it 'marks nearby rooms with danger visibility' do
      result = described_class.visible_rooms(participant)
      nearby = result.find { |r| r[:room] == nearby_room }
      expect(nearby[:visibility]).to eq(:danger)
      expect(nearby[:show_danger]).to be true
    end

    it 'marks far rooms as hidden or explored' do
      result = described_class.visible_rooms(participant)
      far = result.find { |r| r[:room] == far_room }
      expect(far[:visibility]).to eq(:hidden)
    end
  end

  describe '.can_see_contents?' do
    it 'returns false if no current room' do
      allow(participant).to receive(:current_room).and_return(nil)
      expect(described_class.can_see_contents?(participant, nearby_room)).to be false
    end

    it 'returns true for current room' do
      expect(described_class.can_see_contents?(participant, current_room)).to be true
    end

    it 'returns false for other rooms' do
      expect(described_class.can_see_contents?(participant, nearby_room)).to be false
    end
  end

  describe '.can_see_danger?' do
    it 'returns true for current room' do
      expect(described_class.can_see_danger?(participant, current_room)).to be true
    end

    it 'returns true for nearby rooms within range' do
      expect(described_class.can_see_danger?(participant, nearby_room)).to be true
    end

    it 'returns false for rooms beyond range' do
      expect(described_class.can_see_danger?(participant, far_room)).to be false
    end

    it 'returns false if no current room' do
      allow(participant).to receive(:current_room).and_return(nil)
      expect(described_class.can_see_danger?(participant, nearby_room)).to be false
    end
  end

  describe '.revealed_rooms' do
    before do
      allow(delve).to receive(:rooms_on_level).and_return(
        double(all: [current_room, nearby_room, far_room])
      )
    end

    it 'returns empty array if no current room' do
      allow(participant).to receive(:current_room).and_return(nil)
      result = described_class.revealed_rooms(participant)
      expect(result).to eq([])
    end

    it 'includes visible rooms' do
      result = described_class.revealed_rooms(participant)
      expect(result).to include(current_room)
      expect(result).to include(nearby_room)
    end

    it 'excludes far unexplored rooms' do
      result = described_class.revealed_rooms(participant)
      expect(result).not_to include(far_room)
    end
  end

  describe '.danger_warnings' do
    before do
      allow(delve).to receive(:rooms_on_level).and_return(
        double(all: [current_room, nearby_room, exit_room])
      )
    end

    it 'returns empty array if no current room' do
      allow(participant).to receive(:current_room).and_return(nil)
      result = described_class.danger_warnings(participant)
      expect(result).to eq([])
    end

    it 'warns about nearby monsters' do
      result = described_class.danger_warnings(participant)
      expect(result.any? { |w| w.include?('danger') }).to be true
    end

    it 'warns about nearby exits' do
      result = described_class.danger_warnings(participant)
      expect(result.any? { |w| w.include?('stairs') }).to be true
    end

    it 'includes direction in warnings' do
      result = described_class.danger_warnings(participant)
      expect(result.any? { |w| w.include?('east') }).to be true
    end
  end
end
