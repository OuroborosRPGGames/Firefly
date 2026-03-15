# frozen_string_literal: true

require 'spec_helper'

return unless DB.table_exists?(:delve_monsters)

RSpec.describe DelveMonster do
  describe 'constants' do
    it 'defines MONSTER_TYPES' do
      expect(described_class::MONSTER_TYPES).to include('rat', 'spider', 'goblin', 'skeleton', 'dragon')
    end
  end

  describe 'associations' do
    it 'belongs to delve' do
      expect(described_class.association_reflections[:delve]).not_to be_nil
    end

    it 'belongs to current_room' do
      expect(described_class.association_reflections[:current_room]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines active?' do
      expect(described_class.instance_methods).to include(:active?)
    end

    it 'defines alive?' do
      expect(described_class.instance_methods).to include(:alive?)
    end

    it 'defines dead?' do
      expect(described_class.instance_methods).to include(:dead?)
    end

    it 'defines should_move?' do
      expect(described_class.instance_methods).to include(:should_move?)
    end

    it 'defines available_moves' do
      expect(described_class.instance_methods).to include(:available_moves)
    end

    it 'defines take_damage!' do
      expect(described_class.instance_methods).to include(:take_damage!)
    end

    it 'defines display_name' do
      expect(described_class.instance_methods).to include(:display_name)
    end

    it 'defines difficulty_text' do
      expect(described_class.instance_methods).to include(:difficulty_text)
    end
  end

  describe '#active? behavior' do
    it 'returns true when is_active is true' do
      monster = described_class.new
      monster.values[:is_active] = true
      expect(monster.active?).to be true
    end

    it 'returns false when is_active is false' do
      monster = described_class.new
      monster.values[:is_active] = false
      expect(monster.active?).to be false
    end
  end

  describe '#alive? behavior' do
    it 'returns true when hp > 0' do
      monster = described_class.new
      monster.values[:hp] = 5
      expect(monster.alive?).to be true
    end

    it 'returns false when hp is 0' do
      monster = described_class.new
      monster.values[:hp] = 0
      expect(monster.alive?).to be false
    end

    it 'returns false when hp is nil' do
      monster = described_class.new
      monster.values[:hp] = nil
      expect(monster.alive?).to be false
    end
  end

  describe '#display_name behavior' do
    it 'capitalizes the monster type' do
      monster = described_class.new
      monster.values[:monster_type] = 'goblin'
      expect(monster.display_name).to eq('Goblin')
    end
  end

  describe '#direction_arrow' do
    it 'returns up arrow for north' do
      monster = described_class.new
      monster.values[:movement_direction] = 'north'
      expect(monster.direction_arrow).to eq("\u2191")
    end

    it 'returns down arrow for south' do
      monster = described_class.new
      monster.values[:movement_direction] = 'south'
      expect(monster.direction_arrow).to eq("\u2193")
    end

    it 'returns right arrow for east' do
      monster = described_class.new
      monster.values[:movement_direction] = 'east'
      expect(monster.direction_arrow).to eq("\u2192")
    end

    it 'returns left arrow for west' do
      monster = described_class.new
      monster.values[:movement_direction] = 'west'
      expect(monster.direction_arrow).to eq("\u2190")
    end

    it 'returns nil when no direction set' do
      monster = described_class.new
      monster.values[:movement_direction] = nil
      expect(monster.direction_arrow).to be_nil
    end
  end

  describe '#pick_direction!' do
    it 'sets movement_direction from available moves' do
      monster = described_class.new
      room_stub = double('room', id: 1)
      allow(monster).to receive(:available_moves).and_return([
        { direction: 'north', room: room_stub },
        { direction: 'east', room: room_stub }
      ])
      allow(monster).to receive(:update)

      rng = Random.new(42)
      monster.pick_direction!(rng: rng)

      expect(monster).to have_received(:update).with(movement_direction: a_string_matching(/north|east/))
    end

    it 'sets nil when no moves available' do
      monster = described_class.new
      allow(monster).to receive(:available_moves).and_return([])
      allow(monster).to receive(:update)

      monster.pick_direction!

      expect(monster).to have_received(:update).with(movement_direction: nil)
    end
  end

  describe '#next_move' do
    let(:north_room) { double('north_room', id: 10) }
    let(:south_room) { double('south_room', id: 20) }
    let(:east_room) { double('east_room', id: 30) }

    it 'continues in current direction when possible' do
      monster = described_class.new
      monster.values[:movement_direction] = 'north'
      allow(monster).to receive(:available_moves).and_return([
        { direction: 'north', room: north_room },
        { direction: 'south', room: south_room }
      ])

      result = monster.next_move
      expect(result[:direction]).to eq('north')
      expect(result[:room]).to eq(north_room)
    end

    it 'bounces to new direction on wall, avoiding backtrack' do
      monster = described_class.new
      monster.values[:movement_direction] = 'north'
      allow(monster).to receive(:available_moves).and_return([
        { direction: 'south', room: south_room },
        { direction: 'east', room: east_room }
      ])
      allow(monster).to receive(:update)

      result = monster.next_move
      # Should pick east (not south/reverse)
      expect(result[:direction]).to eq('east')
      expect(monster).to have_received(:update).with(movement_direction: 'east')
    end

    it 'uses reverse direction when it is the only option' do
      monster = described_class.new
      monster.values[:movement_direction] = 'north'
      allow(monster).to receive(:available_moves).and_return([
        { direction: 'south', room: south_room }
      ])
      allow(monster).to receive(:update)

      result = monster.next_move
      expect(result[:direction]).to eq('south')
      expect(monster).to have_received(:update).with(movement_direction: 'south')
    end

    it 'picks random direction when none set' do
      monster = described_class.new
      monster.values[:movement_direction] = nil
      allow(monster).to receive(:available_moves).and_return([
        { direction: 'north', room: north_room }
      ])
      allow(monster).to receive(:update)

      result = monster.next_move
      expect(result[:direction]).to eq('north')
      expect(monster).to have_received(:update).with(movement_direction: 'north')
    end

    it 'returns nil when no moves available' do
      monster = described_class.new
      allow(monster).to receive(:available_moves).and_return([])

      expect(monster.next_move).to be_nil
    end
  end

  describe '#lurking?' do
    it 'returns true when lurking is true' do
      monster = described_class.new
      monster.values[:lurking] = true
      expect(monster.lurking?).to be true
    end

    it 'returns false when lurking is false' do
      monster = described_class.new
      monster.values[:lurking] = false
      expect(monster.lurking?).to be false
    end
  end

  describe '#should_move? with lurking' do
    it 'returns false for lurking monsters regardless of RNG' do
      monster = described_class.new
      monster.values[:lurking] = true
      rng = double('rng', rand: 0.0)
      expect(monster.should_move?(rng)).to be false
    end
  end

  describe '#next_move with lurking' do
    it 'returns nil for lurking monsters' do
      monster = described_class.new
      monster.values[:lurking] = true
      allow(monster).to receive(:available_moves).and_return([
        { direction: 'north', room: double('room', id: 1) }
      ])
      expect(monster.next_move).to be_nil
    end
  end

  describe 'instance methods (new)' do
    it 'defines pick_direction!' do
      expect(described_class.instance_methods).to include(:pick_direction!)
    end

    it 'defines next_move' do
      expect(described_class.instance_methods).to include(:next_move)
    end

    it 'defines direction_arrow' do
      expect(described_class.instance_methods).to include(:direction_arrow)
    end
  end
end
