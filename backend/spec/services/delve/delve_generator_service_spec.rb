# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveGeneratorService do
  # ============================================
  # Constants
  # ============================================

  describe 'constants' do
    describe 'ROOM_TYPES' do
      it 'includes all expected shape-based room types' do
        expect(described_class::ROOM_TYPES).to include('corridor', 'corner', 'branch', 'terminal')
      end

      it 'is frozen' do
        expect(described_class::ROOM_TYPES).to be_frozen
      end
    end

    describe 'MONSTERS' do
      it 'includes low tier monsters' do
        expect(described_class::MONSTERS).to include('rat', 'spider', 'goblin')
      end

      it 'includes high tier monsters' do
        expect(described_class::MONSTERS).to include('demon', 'dragon')
      end

      it 'is frozen' do
        expect(described_class::MONSTERS).to be_frozen
      end

      it 'has monsters in ascending tier order' do
        expect(described_class::MONSTERS.first).to eq('rat')
        expect(described_class::MONSTERS.last).to eq('dragon')
      end
    end

    describe 'REVERSE_DIR' do
      it 'maps each direction to its opposite' do
        expect(described_class::REVERSE_DIR[:north]).to eq(:south)
        expect(described_class::REVERSE_DIR[:south]).to eq(:north)
        expect(described_class::REVERSE_DIR[:east]).to eq(:west)
        expect(described_class::REVERSE_DIR[:west]).to eq(:east)
      end
    end

    describe 'DIRECTION_DELTA' do
      it 'maps directions to [dx, dy] deltas' do
        expect(described_class::DIRECTION_DELTA[:north]).to eq([0, -1])
        expect(described_class::DIRECTION_DELTA[:south]).to eq([0, 1])
        expect(described_class::DIRECTION_DELTA[:east]).to eq([1, 0])
        expect(described_class::DIRECTION_DELTA[:west]).to eq([-1, 0])
      end
    end
  end

  # ============================================
  # Direction Helpers (private, tested via send)
  # ============================================

  describe 'direction helpers' do
    let(:service) { described_class }

    describe 'reverse_direction' do
      it 'returns the opposite direction' do
        expect(service.send(:reverse_direction, :north)).to eq(:south)
        expect(service.send(:reverse_direction, :east)).to eq(:west)
      end
    end

    describe 'valid_turns' do
      it 'returns perpendicular directions for north/south' do
        expect(service.send(:valid_turns, :north)).to match_array(%i[east west])
        expect(service.send(:valid_turns, :south)).to match_array(%i[east west])
      end

      it 'returns perpendicular directions for east/west' do
        expect(service.send(:valid_turns, :east)).to match_array(%i[north south])
        expect(service.send(:valid_turns, :west)).to match_array(%i[north south])
      end
    end

    describe 'can_place?' do
      let(:grid) { Array.new(5) { Array.new(5) { nil } } }

      it 'returns true for empty in-bounds cell' do
        expect(service.send(:can_place?, grid, 2, 2, 5, 5)).to be true
      end

      it 'returns false for out-of-bounds cell' do
        expect(service.send(:can_place?, grid, -1, 0, 5, 5)).to be false
        expect(service.send(:can_place?, grid, 5, 0, 5, 5)).to be false
      end

      it 'returns false for occupied cell' do
        grid[2][2] = { type: :tunnel }
        expect(service.send(:can_place?, grid, 2, 2, 5, 5)).to be false
      end
    end
  end

  # ============================================
  # Segment Constructors (private, tested via send)
  # ============================================

  describe 'segment constructors' do
    let(:service) { described_class }
    let(:rng) { Random.new(42) }
    let(:w) { 10 }
    let(:h) { 10 }

    describe 'construct_passage' do
      it 'places 3 rooms ahead of cursor in a straight line' do
        grid = Array.new(h) { Array.new(w) { nil } }
        result = service.send(:construct_passage, grid, 5, 2, :south, w, h, rng)

        expect(result).not_to be_nil
        expect(result[:rooms].length).to eq(3)
        expect(result[:rooms]).to eq([[5, 3], [5, 4], [5, 5]])
        expect(result[:end_dir]).to eq(:south)
        expect(grid[3][5]).not_to be_nil
        expect(grid[4][5]).not_to be_nil
        expect(grid[5][5]).not_to be_nil
        # Cursor position untouched
        expect(grid[2][5]).to be_nil
      end

      it 'returns nil when blocked by boundary' do
        grid = Array.new(h) { Array.new(w) { nil } }
        result = service.send(:construct_passage, grid, 5, 7, :south, w, h, rng)
        expect(result).to be_nil
      end

      it 'returns nil when blocked by existing room' do
        grid = Array.new(h) { Array.new(w) { nil } }
        grid[4][5] = { type: :tunnel }
        result = service.send(:construct_passage, grid, 5, 2, :south, w, h, rng)
        expect(result).to be_nil
        # Verify no partial writes
        expect(grid[3][5]).to be_nil
        expect(grid[5][5]).to be_nil
      end
    end

    describe 'construct_corner' do
      it 'places 2 straight rooms ahead then 1 perpendicular room' do
        grid = Array.new(h) { Array.new(w) { nil } }
        result = service.send(:construct_corner, grid, 5, 2, :south, w, h, rng)

        expect(result).not_to be_nil
        expect(result[:rooms].length).to eq(3)
        # First 2 rooms go south (ahead of cursor)
        expect(result[:rooms][0]).to eq([5, 3])
        expect(result[:rooms][1]).to eq([5, 4])
        # Third room turns perpendicular
        expect(result[:end_dir]).to satisfy { |d| %i[east west].include?(d) }
        # Cursor position untouched
        expect(grid[2][5]).to be_nil
      end

      it 'returns nil when first position ahead is blocked' do
        grid = Array.new(h) { Array.new(w) { nil } }
        grid[3][5] = { type: :tunnel }
        result = service.send(:construct_corner, grid, 5, 2, :south, w, h, rng)
        expect(result).to be_nil
      end

      it 'tries both perpendicular directions' do
        grid = Array.new(h) { Array.new(w) { nil } }
        # Block one perpendicular direction (east from [5,4])
        grid[4][6] = { type: :tunnel }
        result = service.send(:construct_corner, grid, 5, 2, :south, w, h, rng)

        # Should still succeed using west
        expect(result).not_to be_nil
      end
    end

    describe 'construct_branch' do
      it 'places junction ahead + 2 perpendicular arms' do
        grid = Array.new(h) { Array.new(w) { nil } }
        result = service.send(:construct_branch, grid, 5, 2, :south, w, h, rng)

        expect(result).not_to be_nil
        expect(result[:rooms].length).to eq(3)
        expect(result[:junction]).to eq([5, 3])
        expect(result[:arm1]).to include(:x, :y, :dir)
        expect(result[:arm2]).to include(:x, :y, :dir)
        # Cursor position untouched
        expect(grid[2][5]).to be_nil
      end

      it 'returns nil when junction blocked' do
        grid = Array.new(h) { Array.new(w) { nil } }
        grid[3][5] = { type: :tunnel }
        result = service.send(:construct_branch, grid, 5, 2, :south, w, h, rng)
        expect(result).to be_nil
      end

      it 'returns nil when either arm is blocked' do
        grid = Array.new(h) { Array.new(w) { nil } }
        # Block east arm from junction [5,3]
        grid[3][6] = { type: :tunnel }
        result = service.send(:construct_branch, grid, 5, 2, :south, w, h, rng)
        expect(result).to be_nil
      end
    end

    describe 'try_segment' do
      it 'returns a passage or corner result' do
        grid = Array.new(h) { Array.new(w) { nil } }
        result = service.send(:try_segment, grid, 5, 2, :south, w, h, rng)

        expect(result).not_to be_nil
        expect(result[:rooms].length).to eq(3)
        expect(result).to include(:end_x, :end_y, :end_dir)
      end

      it 'returns nil when no segment fits' do
        grid = Array.new(h) { Array.new(w) { nil } }
        # Block all directions from corner position
        result = service.send(:try_segment, grid, 0, 0, :north, w, h, rng)
        expect(result).to be_nil
      end
    end
  end

  # ============================================
  # Class Methods
  # ============================================

  describe '.generate_level!' do
    let(:delve) do
      instance_double(
        Delve,
        id: 1,
        grid_width: 10,
        grid_height: 10,
        seed: 'test_seed',
        difficulty: 'normal',
        location: nil
      )
    end

    before do
      # Mock DelveRoom creation
      allow(DelveRoom).to receive(:create) do |attrs|
        room_values = {
          id: rand(1..1000),
          grid_x: attrs[:grid_x],
          grid_y: attrs[:grid_y],
          room_type: attrs[:room_type],
          is_entrance: attrs[:is_entrance],
          is_exit: attrs[:is_exit],
          is_boss: false,
          is_terminal: false,
          has_puzzle: false,
          has_trap: false,
          has_treasure: false,
          monster_type: nil,
          monster_cleared: false,
          loot_value: 0,
          available_exits: [],
          room_id: nil,
          room: nil
        }
        room = instance_double(DelveRoom, **room_values)
        allow(room).to receive(:update)
        allow(room).to receive(:reload).and_return(room)
        allow(room).to receive(:values).and_return(room_values)
        room
      end

      # Mock external services
      allow(DelveTreasureService).to receive(:generate!)
      allow(DelvePuzzleService).to receive(:generate!)
      allow(DelveTrapService).to receive(:generate!)
      allow(DelveMonsterService).to receive(:spawn_monsters!)
      allow(DelveMonsterService).to receive(:spawn_lurkers!)
      allow(DelveBlocker).to receive(:create)
      allow(DelveBlocker).to receive(:first).and_return(nil)
      allow(delve).to receive(:entrance_room).and_return(nil)
      allow(delve).to receive(:adjacent_room).and_return(nil)

      # Mock batch operations used by optimized generator
      delve_room_dataset = double('dataset', update: true)
      allow(DelveRoom).to receive(:where).and_return(delve_room_dataset)
      empty_dataset = double('empty_dataset', all: [], each: nil, group_by: {})
      allow(empty_dataset).to receive(:each).and_return([].each)
      allow(empty_dataset).to receive(:exclude).and_return(empty_dataset)
      allow(DelveBlocker).to receive(:where).and_return(empty_dataset)
      allow(DelveTrap).to receive(:where).and_return(empty_dataset)
      allow(DelvePuzzle).to receive(:where).and_return(empty_dataset)

      # Mock room creation infrastructure for create_real_rooms!
      pool_location = double('location', id: 1)
      allow(Location).to receive(:first).and_return(pool_location)
      allow(RoomTemplate).to receive(:first).and_return(nil)
      allow(RoomTemplate).to receive(:create).and_return(double('template', id: 1))
      mock_room = double('room', id: 1, min_x: 0.0, max_x: 12.0, min_y: 0.0, max_y: 12.0, update: true)
      allow(TemporaryRoomPoolService).to receive(:acquire_for_delve).and_return(
        double('result', success?: true, :[] => mock_room)
      )
      allow(Room).to receive(:where).and_return(double('room_ds', all: [mock_room], delete: true))
      allow(RoomFeature).to receive(:where).and_return(double('rf_ds', delete: true))
      allow(DB).to receive(:[]).and_return(double('table', multi_insert: true))

      # Mock GameConfig
      allow(GameConfig::Delve).to receive_message_chain(:DENSITY).and_return({
                                                                               room_ratio: 0.5,
                                                                               main_tunnel_ratio: 0.25,
                                                                               min_main_rooms: 5,
                                                                               min_boss_rooms: 5
                                                                             })
      allow(GameConfig::Delve).to receive_message_chain(:FRACTAL).and_return({
                                                                               initial_branch_chance: 9,
                                                                               branch_chance_ramp: 2,
                                                                               sub_branch_chance: 4,
                                                                               min_branch_budget: 6,
                                                                               segment_cost: 3
                                                                             })
      allow(GameConfig::Delve).to receive_message_chain(:CONTENT_WEIGHTS).and_return({
                                                                                       normal: { empty: 45, monster: 20, puzzle: 8 }
                                                                                     })
      allow(GameConfig::Delve).to receive_message_chain(:CONTENT).and_return({
                                                                               blocker_chance: 0.15,
                                                                               trap_chance: 0.1
                                                                             })
    end

    it 'returns an array of rooms' do
      result = described_class.generate_level!(delve, 1)
      expect(result).to be_an(Array)
    end

    it 'creates DelveRoom records' do
      expect(DelveRoom).to receive(:create).at_least(:once)
      described_class.generate_level!(delve, 1)
    end

    it 'calls monster spawning service' do
      expect(DelveMonsterService).to receive(:spawn_monsters!).with(delve, 1, anything)
      described_class.generate_level!(delve, 1)
    end

    it 'calls lurker spawning service' do
      expect(DelveMonsterService).to receive(:spawn_lurkers!).with(delve, 1, anything)
      described_class.generate_level!(delve, 1)
    end

    it 'uses delve dimensions for grid' do
      result = described_class.generate_level!(delve, 1)
      expect(result.length).to be > 0
    end

    context 'with nil grid dimensions' do
      let(:delve) do
        instance_double(
          Delve,
          id: 1,
          grid_width: nil,
          grid_height: nil,
          seed: 'test_seed',
          difficulty: 'normal',
          location: nil
        )
      end

      it 'uses default 15x15 grid' do
        result = described_class.generate_level!(delve, 1)
        expect(result).to be_an(Array)
      end
    end

    context 'with different level numbers' do
      it 'generates reproducible layouts with same seed' do
        positions1 = []
        positions2 = []

        allow(DelveRoom).to receive(:create) do |attrs|
          positions1 << [attrs[:grid_x], attrs[:grid_y]]
          vals = { id: rand(1..1000), grid_x: attrs[:grid_x], grid_y: attrs[:grid_y],
                   room_type: attrs[:room_type], is_entrance: false, is_exit: false, is_boss: false, is_terminal: false,
                   has_puzzle: false, has_trap: false, has_treasure: false, monster_type: nil, monster_cleared: false,
                   loot_value: 0, available_exits: [], room_id: nil, room: nil }
          r = instance_double(DelveRoom, **vals)
          allow(r).to receive(:update)
          allow(r).to receive(:reload).and_return(r)
          allow(r).to receive(:values).and_return(vals)
          r
        end
        described_class.generate_level!(delve, 1)

        allow(DelveRoom).to receive(:create) do |attrs|
          positions2 << [attrs[:grid_x], attrs[:grid_y]]
          vals = { id: rand(1..1000), grid_x: attrs[:grid_x], grid_y: attrs[:grid_y],
                   room_type: attrs[:room_type], is_entrance: false, is_exit: false, is_boss: false, is_terminal: false,
                   has_puzzle: false, has_trap: false, has_treasure: false, monster_type: nil, monster_cleared: false,
                   loot_value: 0, available_exits: [], room_id: nil, room: nil }
          r = instance_double(DelveRoom, **vals)
          allow(r).to receive(:update)
          allow(r).to receive(:reload).and_return(r)
          allow(r).to receive(:values).and_return(vals)
          r
        end
        described_class.generate_level!(delve, 1)

        # Same seed + same level = same positions (deterministic)
        expect(positions1).to eq(positions2)
      end
    end
  end

  # ============================================
  # Private Methods (tested via effects)
  # ============================================

  describe 'private methods' do
    describe 'shape inference' do
      let(:service) { described_class }

      it 'infers terminal for 0-1 exits' do
        grid = Array.new(5) { Array.new(5) { nil } }
        grid[2][2] = { type: :tunnel }
        expect(service.send(:infer_room_shape, grid, 2, 2)).to eq('terminal')
      end

      it 'infers corridor for 2 opposite exits' do
        grid = Array.new(5) { Array.new(5) { nil } }
        grid[1][2] = { type: :tunnel }
        grid[2][2] = { type: :tunnel }
        grid[3][2] = { type: :tunnel }
        expect(service.send(:infer_room_shape, grid, 2, 2)).to eq('corridor')
      end

      it 'infers corner for 2 perpendicular exits' do
        grid = Array.new(5) { Array.new(5) { nil } }
        grid[1][2] = { type: :tunnel }
        grid[2][2] = { type: :tunnel }
        grid[2][3] = { type: :tunnel }
        expect(service.send(:infer_room_shape, grid, 2, 2)).to eq('corner')
      end

      it 'infers branch for 3+ exits' do
        grid = Array.new(5) { Array.new(5) { nil } }
        grid[1][2] = { type: :tunnel }
        grid[2][2] = { type: :tunnel }
        grid[3][2] = { type: :tunnel }
        grid[2][3] = { type: :tunnel }
        expect(service.send(:infer_room_shape, grid, 2, 2)).to eq('branch')
      end
    end

    describe 'add_treasures!' do
      let(:service) { described_class }

      it 'does not place treasure in the entrance room even if terminal' do
        entrance_room = instance_double(DelveRoom, is_terminal: true, is_exit: false, is_entrance: true)
        terminal_room = instance_double(DelveRoom, is_terminal: true, is_exit: false, is_entrance: false)
        allow(terminal_room).to receive(:update)

        rooms = [entrance_room, terminal_room]
        rng = Random.new(42)

        expect(DelveTreasureService).to receive(:generate!).with(terminal_room, 1, :modern).once
        expect(DelveTreasureService).not_to receive(:generate!).with(entrance_room, anything, anything)

        service.send(:add_treasures!, instance_double(Delve, id: 1), 1, rooms, :modern, rng)
      end
    end

    describe 'boss monster assignment' do
      let(:service) { described_class }

      it 'assigns higher tier monsters as bosses' do
        results = 10.times.map do |i|
          rng = Random.new(i)
          service.send(:assign_boss_monster, 5, rng)
        end

        mid_high_tier = %w[orc troll ogre demon dragon]
        mid_high_count = results.count { |m| mid_high_tier.include?(m) }
        expect(mid_high_count).to be >= 3
      end
    end

    describe 'helper methods' do
      let(:service) { described_class }

      describe 'in_bounds?' do
        it 'returns true for valid coordinates' do
          expect(service.send(:in_bounds?, 5, 5, 10, 10)).to be true
        end

        it 'returns false for negative x' do
          expect(service.send(:in_bounds?, -1, 5, 10, 10)).to be false
        end

        it 'returns false for negative y' do
          expect(service.send(:in_bounds?, 5, -1, 10, 10)).to be false
        end

        it 'returns false for x >= width' do
          expect(service.send(:in_bounds?, 10, 5, 10, 10)).to be false
        end

        it 'returns false for y >= height' do
          expect(service.send(:in_bounds?, 5, 10, 10, 10)).to be false
        end
      end

      describe 'weighted_sample' do
        it 'returns keys from weights hash' do
          weights = { corridor: 50, chamber: 30, monster: 20 }
          rng = Random.new(42)
          result = service.send(:weighted_sample, weights, rng)
          expect(%w[corridor chamber monster]).to include(result)
        end

        it 'favors higher weighted options over many samples' do
          weights = { common: 90, rare: 10 }
          results = 100.times.map do |i|
            rng = Random.new(i)
            service.send(:weighted_sample, weights, rng)
          end

          common_count = results.count { |r| r == 'common' }
          expect(common_count).to be > 70
        end
      end
    end
  end

  # ============================================
  # Real Room Creation (integration)
  # ============================================

  describe 'real room creation' do
    let!(:universe) { create(:universe) }
    let!(:world) { create(:world, universe: universe) }
    let!(:zone) { create(:zone, world: world) }
    let(:delve) { create(:delve, grid_width: 5, grid_height: 5, seed: '12345') }

    before do
      RoomTemplate.find_or_create(template_type: 'delve_room', category: 'delve') do |t|
        t.name = 'Delve Room'
        t.short_description = 'A dark dungeon chamber.'
        t.width = 30
        t.length = 30
        t.height = 10
        t.active = true
        t.room_type = 'dungeon'
      end
    end

    it 'creates real Room records for each DelveRoom' do
      rooms = described_class.generate_level!(delve, 1)

      rooms.each do |delve_room|
        delve_room.reload
        expect(delve_room.room_id).not_to be_nil
        real_room = delve_room.room
        expect(real_room).to be_a(Room)
        expect(real_room.is_temporary).to be true
      end
    end

    it 'places rooms centered within 30ft grid cells with type-appropriate sizes' do
      rooms = described_class.generate_level!(delve, 1)
      room = rooms.first
      room.reload
      real_room = room.room

      # Room dimensions vary by type; corridors are rectangular, others are square
      room_width = real_room.max_x - real_room.min_x
      room_height = real_room.max_y - real_room.min_y
      valid_widths = [6.0, 12.0, 18.0, 20.0, 24.0, 26.0]
      valid_heights = [6.0, 12.0, 18.0, 20.0, 24.0, 26.0]
      expect(valid_widths).to include(room_width)
      expect(valid_heights).to include(room_height)

      # Verify room is centered in grid cell
      grid_origin_x = room.grid_x * 30.0
      offset_x = (30.0 - room_width) / 2.0
      expect(real_room.min_x).to eq(grid_origin_x + offset_x)
      expect(real_room.max_x).to eq(grid_origin_x + offset_x + room_width)
    end

    it 'creates wall and door features based on adjacency' do
      rooms = described_class.generate_level!(delve, 1)
      room = rooms.first
      room.reload

      features = RoomFeature.where(room_id: room.room_id).all
      expect(features).not_to be_empty
      expect(features.any? { |f| f.feature_type == 'wall' }).to be true
    end

    it 'sets descriptions on real rooms' do
      rooms = described_class.generate_level!(delve, 1)
      room = rooms.first
      room.reload

      expect(room.room.short_description).not_to be_nil
      expect(room.room.short_description.length).to be > 10
    end
  end

  # ============================================
  # Method Existence
  # ============================================

  describe 'class methods' do
    it 'defines generate_level!' do
      expect(described_class).to respond_to(:generate_level!)
    end
  end
end
