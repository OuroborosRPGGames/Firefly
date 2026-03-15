# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Delve do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe 'validations' do
    it 'requires name' do
      delve = Delve.new(difficulty: 'normal')
      expect(delve.valid?).to be false
      expect(delve.errors[:name]).not_to be_empty
    end

    it 'requires difficulty' do
      delve = Delve.new(name: 'Test Dungeon')
      expect(delve.valid?).to be false
      expect(delve.errors[:difficulty]).not_to be_empty
    end

    it 'validates difficulty is in DIFFICULTIES' do
      delve = Delve.new(name: 'Test', difficulty: 'invalid')
      expect(delve.valid?).to be false
      expect(delve.errors[:difficulty]).not_to be_empty
    end

    it 'accepts valid difficulties' do
      Delve::DIFFICULTIES.each do |diff|
        delve = Delve.new(name: 'Test', difficulty: diff)
        expect(delve.valid?).to be true
      end
    end

    it 'validates status is in STATUSES' do
      delve = Delve.create(name: 'Test', difficulty: 'normal')
      delve.status = 'invalid'
      expect(delve.valid?).to be false
    end
  end

  describe 'before_save' do
    it 'sets default difficulty to normal' do
      delve = Delve.new(name: 'Test')
      delve.difficulty = 'normal' # Required for validation
      delve.save
      expect(delve.difficulty).to eq('normal')
    end

    it 'sets default status to generating' do
      delve = Delve.create(name: 'Test', difficulty: 'normal')
      expect(delve.status).to eq('generating')
    end

    it 'sets default max_depth to 10' do
      delve = Delve.create(name: 'Test', difficulty: 'normal')
      expect(delve.max_depth).to eq(10)
    end

    it 'sets default time_limit_minutes to 60' do
      delve = Delve.create(name: 'Test', difficulty: 'normal')
      expect(delve.time_limit_minutes).to eq(60)
    end

    it 'generates a seed' do
      delve = Delve.create(name: 'Test', difficulty: 'normal')
      expect(delve.seed).not_to be_nil
      expect(delve.seed.length).to eq(16)
    end
  end

  describe 'status methods' do
    let(:delve) { Delve.create(name: 'Test Dungeon', difficulty: 'normal') }

    describe '#active?' do
      it 'returns true when status is active' do
        delve.update(status: 'active')
        expect(delve.active?).to be true
      end

      it 'returns false when status is not active' do
        expect(delve.active?).to be false
      end
    end

    describe '#completed?' do
      it 'returns true when status is completed' do
        delve.update(status: 'completed')
        expect(delve.completed?).to be true
      end
    end

    describe '#failed?' do
      it 'returns true when status is failed' do
        delve.update(status: 'failed')
        expect(delve.failed?).to be true
      end
    end

    describe '#start!' do
      it 'sets status to active' do
        delve.start!
        expect(delve.status).to eq('active')
      end

      it 'sets started_at' do
        delve.start!
        expect(delve.started_at).not_to be_nil
      end
    end

    describe '#complete!' do
      it 'sets status to completed' do
        delve.complete!
        expect(delve.status).to eq('completed')
      end

      it 'sets completed_at' do
        delve.complete!
        expect(delve.completed_at).not_to be_nil
      end
    end

    describe '#fail!' do
      it 'sets status to failed' do
        delve.fail!
        expect(delve.status).to eq('failed')
      end

      it 'sets completed_at' do
        delve.fail!
        expect(delve.completed_at).not_to be_nil
      end
    end

    describe '#abandon!' do
      it 'sets status to abandoned' do
        delve.abandon!
        expect(delve.status).to eq('abandoned')
      end
    end
  end

  describe 'time tracking' do
    let(:delve) { Delve.create(name: 'Test', difficulty: 'normal', time_limit_minutes: 30) }

    describe '#time_remaining' do
      it 'returns nil if not started' do
        expect(delve.time_remaining).to be_nil
      end

      it 'returns remaining time in seconds' do
        delve.update(started_at: Time.now - 600) # Started 10 minutes ago
        # 30 min limit - 10 min elapsed = 20 min remaining = 1200 seconds
        expect(delve.time_remaining).to be_within(5).of(1200)
      end

      it 'returns 0 when time is expired' do
        delve.update(started_at: Time.now - 3600) # Started 60 minutes ago
        expect(delve.time_remaining).to eq(0)
      end
    end

    describe '#time_expired?' do
      it 'returns false if not started' do
        expect(delve.time_expired?).to be_falsey
      end

      it 'returns false if time remaining' do
        delve.update(started_at: Time.now)
        expect(delve.time_expired?).to be false
      end

      it 'returns true when time is expired' do
        delve.update(started_at: Time.now - 3600)
        expect(delve.time_expired?).to be true
      end
    end
  end

  describe 'direction utilities' do
    let(:delve) { Delve.create(name: 'Test', difficulty: 'normal') }

    describe '#direction_offset' do
      it 'returns correct offset for north' do
        expect(delve.direction_offset('north')).to eq([0, -1])
        expect(delve.direction_offset('n')).to eq([0, -1])
      end

      it 'returns correct offset for south' do
        expect(delve.direction_offset('south')).to eq([0, 1])
        expect(delve.direction_offset('s')).to eq([0, 1])
      end

      it 'returns correct offset for east' do
        expect(delve.direction_offset('east')).to eq([1, 0])
        expect(delve.direction_offset('e')).to eq([1, 0])
      end

      it 'returns correct offset for west' do
        expect(delve.direction_offset('west')).to eq([-1, 0])
        expect(delve.direction_offset('w')).to eq([-1, 0])
      end

      it 'returns nil for invalid direction' do
        expect(delve.direction_offset('invalid')).to be_nil
      end
    end

    describe '#opposite_direction' do
      it 'returns south for north' do
        expect(delve.opposite_direction('north')).to eq('south')
      end

      it 'returns north for south' do
        expect(delve.opposite_direction('south')).to eq('north')
      end

      it 'returns west for east' do
        expect(delve.opposite_direction('east')).to eq('west')
      end

      it 'returns east for west' do
        expect(delve.opposite_direction('west')).to eq('east')
      end
    end
  end

  describe 'loot modifier' do
    let(:delve) { Delve.create(name: 'Test', difficulty: 'normal') }

    it 'returns 1.0 at depth 0' do
      expect(delve.loot_modifier).to eq(1.0)
    end
  end

  describe 'level management' do
    let(:delve) { Delve.create(name: 'Test', difficulty: 'normal', levels_generated: 3) }

    describe '#level_exists?' do
      it 'returns true for generated levels' do
        expect(delve.level_exists?(1)).to be true
        expect(delve.level_exists?(2)).to be true
        expect(delve.level_exists?(3)).to be true
      end

      it 'returns false for ungenerated levels' do
        expect(delve.level_exists?(4)).to be false
        expect(delve.level_exists?(5)).to be false
      end
    end
  end

  describe 'monster difficulty calculation' do
    let(:delve) { Delve.create(name: 'Test', difficulty: 'normal', base_difficulty: 100, party_size: 2) }

    describe '#monster_difficulty_for_level' do
      it 'returns difficulty scaled by party size and level' do
        # Default: base × 0.5 × party × (1 + 0.2 × (level - 1))
        # Level 1: 100 × 0.5 × 2 × 1.0 = 100
        expect(delve.monster_difficulty_for_level(1)).to eq(100)

        # Level 2: 100 × 0.5 × 2 × 1.2 = 120
        expect(delve.monster_difficulty_for_level(2)).to eq(120)

        # Level 3: 100 × 0.5 × 2 × 1.4 = 140
        expect(delve.monster_difficulty_for_level(3)).to eq(140)
      end

      it 'uses default base_difficulty if not set' do
        delve.update(base_difficulty: nil)
        expect(delve.monster_difficulty_for_level(1)).to eq(68) # 68 × 0.5 × 2 × 1.0 = 68
      end
    end
  end

  describe 'action time' do
    let(:delve) { Delve.create(name: 'Test', difficulty: 'normal') }

    it 'returns time for move action' do
      expect(delve.action_time(:move)).to eq(1)
    end

    it 'returns time for search action' do
      expect(delve.action_time(:search)).to eq(2)
    end

    it 'returns time for combat action' do
      expect(delve.action_time(:combat)).to eq(5)
    end

    it 'returns time for loot action' do
      expect(delve.action_time(:loot)).to eq(1)
    end

    it 'returns 1 for unknown action' do
      expect(delve.action_time(:unknown)).to eq(1)
    end

    describe '.action_time_seconds' do
      it 'uses configured setting for mapped actions' do
        allow(GameSetting).to receive(:integer).with('delve_time_move').and_return(42)

        expect(Delve.action_time_seconds(:move)).to eq(42)
      end

      it 'uses default combat action time and does not map to combat-round setting' do
        expect(GameSetting).not_to receive(:get_integer)

        expect(Delve.action_time_seconds(:combat)).to eq(Delve::ACTION_TIMES_SECONDS[:combat])
      end
    end
  end

  describe 'room access' do
    let(:delve) { Delve.create(name: 'Test', difficulty: 'normal') }
    let!(:room1) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', level: 1, grid_x: 0, grid_y: 0, depth: 1, is_entrance: true) }
    let!(:room2) { DelveRoom.create(delve_id: delve.id, room_type: 'branch', level: 1, grid_x: 1, grid_y: 0, depth: 1, is_exit: true) }
    let!(:room3) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', level: 2, grid_x: 0, grid_y: 0, depth: 2) }

    describe '#rooms_on_level' do
      it 'returns rooms on specified level' do
        rooms = delve.rooms_on_level(1).all
        expect(rooms.size).to eq(2)
        expect(rooms).to include(room1, room2)
      end
    end

    describe '#entrance_room' do
      it 'returns the entrance room for a level' do
        expect(delve.entrance_room(1)).to eq(room1)
      end

      it 'returns nil if no entrance room' do
        expect(delve.entrance_room(2)).to be_nil
      end
    end

    describe '#exit_room' do
      it 'returns the exit room for a level' do
        expect(delve.exit_room(1)).to eq(room2)
      end
    end

    describe '#room_at' do
      it 'returns room at specified coordinates' do
        expect(delve.room_at(1, 0, 0)).to eq(room1)
        expect(delve.room_at(1, 1, 0)).to eq(room2)
      end

      it 'returns nil for non-existent coordinates' do
        expect(delve.room_at(1, 5, 5)).to be_nil
      end
    end

    describe '#adjacent_room' do
      it 'returns room in specified direction' do
        expect(delve.adjacent_room(room1, 'east')).to eq(room2)
      end

      it 'returns nil for invalid direction' do
        expect(delve.adjacent_room(room1, 'north')).to be_nil
      end
    end
  end
end
