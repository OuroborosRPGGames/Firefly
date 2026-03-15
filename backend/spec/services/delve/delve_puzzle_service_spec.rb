# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelvePuzzleService do
  describe 'constants' do
    it 'defines PUZZLE_TYPES' do
      expect(described_class::PUZZLE_TYPES).to eq(%w[symbol_grid pipe_network toggle_matrix])
    end

    it 'defines DIFFICULTY_BY_LEVEL' do
      expect(described_class::DIFFICULTY_BY_LEVEL).to include(1 => 'easy', 5 => 'hard')
    end
  end

  describe '.generate!' do
    let(:room) { double('DelveRoom', id: 1) }
    let(:seed) { 12345 }

    before do
      allow(DelvePuzzle).to receive(:create).and_return(double('DelvePuzzle', id: 1))
    end

    it 'creates a puzzle for the given room' do
      expect(DelvePuzzle).to receive(:create).with(hash_including(
        delve_room_id: room.id,
        seed: seed
      ))

      described_class.generate!(room, 1, seed)
    end

    it 'uses easy difficulty for level 1' do
      expect(DelvePuzzle).to receive(:create).with(hash_including(
        difficulty: 'easy'
      ))

      described_class.generate!(room, 1, seed)
    end

    it 'uses easy difficulty for level 2' do
      expect(DelvePuzzle).to receive(:create).with(hash_including(
        difficulty: 'easy'
      ))

      described_class.generate!(room, 2, seed)
    end

    it 'uses medium difficulty for level 3' do
      expect(DelvePuzzle).to receive(:create).with(hash_including(
        difficulty: 'medium'
      ))

      described_class.generate!(room, 3, seed)
    end

    it 'uses hard difficulty for level 5+' do
      expect(DelvePuzzle).to receive(:create).with(hash_including(
        difficulty: 'hard'
      ))

      described_class.generate!(room, 5, seed)
    end

    it 'defaults to hard for levels beyond 6' do
      expect(DelvePuzzle).to receive(:create).with(hash_including(
        difficulty: 'hard'
      ))

      described_class.generate!(room, 10, seed)
    end

    it 'generates puzzle data based on puzzle type' do
      expect(DelvePuzzle).to receive(:create).with(hash_including(
        puzzle_data: hash_including(:type)
      ))

      described_class.generate!(room, 1, seed)
    end
  end

  describe '.attempt!' do
    let(:participant) { double('DelveParticipant') }
    let(:puzzle) { double('DelvePuzzle', puzzle_type: 'symbol_grid', solution: [[1, 2], [3, 4]]) }

    before do
      allow(participant).to receive(:accessibility_mode?).and_return(false)
      allow(participant).to receive(:spend_time_seconds!)
      allow(puzzle).to receive(:solve!)
      allow(GameSetting).to receive(:integer).with('delve_time_puzzle_attempt').and_return(15)
    end

    context 'with correct answer' do
      it 'solves the puzzle and returns success' do
        expect(puzzle).to receive(:solve!)

        result = described_class.attempt!(participant, puzzle, [[1, 2], [3, 4]])

        expect(result.success).to be true
        expect(result.data[:solved]).to be true
      end

      it 'spends time for the attempt' do
        expect(participant).to receive(:spend_time_seconds!).with(15)

        described_class.attempt!(participant, puzzle, [[1, 2], [3, 4]])
      end
    end

    context 'with incorrect answer' do
      it 'returns failure result' do
        result = described_class.attempt!(participant, puzzle, [[0, 0], [0, 0]])

        expect(result.success).to be false
        expect(result.data[:solved]).to be false
      end

      it 'does not solve the puzzle' do
        expect(puzzle).not_to receive(:solve!)

        described_class.attempt!(participant, puzzle, [[0, 0], [0, 0]])
      end
    end

    context 'with accessibility mode' do
      let(:char_instance) { double('CharacterInstance') }

      before do
        allow(participant).to receive(:accessibility_mode?).and_return(true)
        allow(participant).to receive(:character_instance).and_return(char_instance)
        allow(participant).to receive(:spend_time_seconds!)
        allow(StatAllocationService).to receive(:get_stat_value).and_return(5)
        allow(puzzle).to receive(:difficulty).and_return('easy')
        allow(GameSetting).to receive(:integer).with('delve_time_puzzle_attempt').and_return(15)
        allow(GameSetting).to receive(:integer).with('delve_base_skill_dc').and_return(10)
      end

      it 'performs a stat check instead of requiring puzzle solution' do
        result = described_class.attempt!(participant, puzzle, nil)

        expect(result.data[:accessibility_check]).to be true
      end

      it 'spends time for the attempt' do
        expect(participant).to receive(:spend_time_seconds!).with(15)

        described_class.attempt!(participant, puzzle, nil)
      end

      it 'can succeed the stat check' do
        # Force high roll by stubbing rand to return high values
        allow(described_class).to receive(:rand).and_return(8)

        result = described_class.attempt!(participant, puzzle, nil)

        expect(result.success).to be true
        expect(result.data[:solved]).to be true
        expect(result.message).to include('alternative way past')
      end

      it 'can fail the stat check' do
        # Force low roll and low stat
        allow(described_class).to receive(:rand).and_return(1)
        allow(StatAllocationService).to receive(:get_stat_value).and_return(1)

        result = described_class.attempt!(participant, puzzle, nil)

        expect(result.success).to be false
        expect(result.data[:solved]).to be false
        expect(result.message).to include('fail')
      end
    end
  end

  describe '.request_help!' do
    let(:participant) { double('DelveParticipant') }
    let(:puzzle) do
      double('DelvePuzzle',
        puzzle_type: 'symbol_grid',
        clues: [{ x: 0, y: 0, symbol: 'A' }],
        hints_used: 1,
        solution: [%w[A B], %w[C D]],
        grid_size: 2,
        puzzle_data: { 'clues' => [{ 'x' => 0, 'y' => 0, 'symbol' => 'A' }] })
    end

    before do
      allow(participant).to receive(:spend_time_seconds!)
      allow(puzzle).to receive(:increment_hints!)
      allow(puzzle).to receive(:update)
      allow(GameSetting).to receive(:integer).with('delve_time_puzzle_help').and_return(nil)
      allow(GameSetting).to receive(:integer).with('delve_time_puzzle_hint').and_return(30)
    end

    it 'spends time for the help' do
      expect(participant).to receive(:spend_time_seconds!).with(30)

      described_class.request_help!(participant, puzzle)
    end

    it 'increments hints used' do
      expect(puzzle).to receive(:increment_hints!)

      described_class.request_help!(participant, puzzle)
    end

    it 'returns a help message' do
      result = described_class.request_help!(participant, puzzle)

      expect(result.success).to be true
      expect(result.message).to be_a(String)
      expect(result.data[:hints_used]).to eq(1)
    end
  end

  describe '.accessibility_stat_check!' do
    let(:participant) { double('DelveParticipant') }
    let(:puzzle) { double('DelvePuzzle', difficulty: 'easy') }
    let(:char_instance) { double('CharacterInstance') }

    before do
      allow(participant).to receive(:spend_time_seconds!)
      allow(participant).to receive(:character_instance).and_return(char_instance)
      allow(StatAllocationService).to receive(:get_stat_value).and_return(5)
      allow(puzzle).to receive(:solve!)
      allow(GameSetting).to receive(:integer).with('delve_time_puzzle_attempt').and_return(15)
      allow(GameSetting).to receive(:integer).with('delve_base_skill_dc').and_return(10)
    end

    it 'returns result with accessibility_check flag' do
      result = described_class.accessibility_stat_check!(participant, puzzle)

      expect(result.data[:accessibility_check]).to be true
    end

    it 'spends time for the attempt' do
      expect(participant).to receive(:spend_time_seconds!).with(15)

      described_class.accessibility_stat_check!(participant, puzzle)
    end

    it 'includes roll data in the result' do
      result = described_class.accessibility_stat_check!(participant, puzzle)

      expect(result.data[:roll]).to include(:dice, :modifier, :total)
      expect(result.data[:dc]).to be_a(Integer)
    end

    it 'solves puzzle on success' do
      # Force high roll
      allow(described_class).to receive(:rand).and_return(8)

      expect(puzzle).to receive(:solve!)
      result = described_class.accessibility_stat_check!(participant, puzzle)

      expect(result.success).to be true
      expect(result.data[:solved]).to be true
    end

    it 'does not solve puzzle on failure' do
      # Force low roll
      allow(described_class).to receive(:rand).and_return(1)
      allow(StatAllocationService).to receive(:get_stat_value).and_return(1)

      expect(puzzle).not_to receive(:solve!)
      result = described_class.accessibility_stat_check!(participant, puzzle)

      expect(result.success).to be false
      expect(result.data[:solved]).to be false
    end
  end

  describe '.get_display' do
    let(:puzzle) do
      double('DelvePuzzle',
        id: 42,
        puzzle_type: 'symbol_grid',
        difficulty: 'medium',
        description: 'A challenging puzzle',
        initial_layout: [[nil, nil], [nil, nil]],
        grid_size: 4,
        clues: [{ x: 0, y: 0, symbol: 'A' }],
        hints_used: 2,
        puzzle_data: { 'symbols' => %w[A B C D] }
      )
    end

    it 'returns display data for the puzzle' do
      display = described_class.get_display(puzzle)

      expect(display[:puzzle_type]).to eq('symbol_grid')
      expect(display[:difficulty]).to eq('medium')
      expect(display[:description]).to eq('A challenging puzzle')
      expect(display[:grid]).to eq([[nil, nil], [nil, nil]])
      expect(display[:size]).to eq(4)
      expect(display[:clues]).to eq([{ x: 0, y: 0, symbol: 'A' }])
      expect(display[:hints_used]).to eq(2)
      expect(display[:puzzle_id]).to eq(puzzle.id)
    end
  end

  describe 'private puzzle generation methods' do
    describe 'generate_symbol_grid' do
      it 'generates grids of correct size for each difficulty' do
        rng = Random.new(1)
        result = described_class.send(:generate_symbol_grid, 'easy', rng)
        expect(result[:size]).to eq(4)

        rng = Random.new(1)
        result = described_class.send(:generate_symbol_grid, 'medium', rng)
        expect(result[:size]).to eq(5)

        rng = Random.new(1)
        result = described_class.send(:generate_symbol_grid, 'hard', rng)
        expect(result[:size]).to eq(6)
      end

      it 'generates higher clue ratio for easier difficulties' do
        rng_easy = Random.new(1)
        easy = described_class.send(:generate_symbol_grid, 'easy', rng_easy)

        rng_hard = Random.new(1)
        hard = described_class.send(:generate_symbol_grid, 'hard', rng_hard)

        # Easy should reveal a higher proportion of cells than hard
        easy_ratio = easy[:clues].length.to_f / (easy[:size] ** 2)
        hard_ratio = hard[:clues].length.to_f / (hard[:size] ** 2)
        expect(easy_ratio).to be > hard_ratio
      end
    end

    describe 'generate_pipe_network' do
      it 'generates pipe networks of correct size' do
        rng = Random.new(1)
        result = described_class.send(:generate_pipe_network, 'easy', rng)

        expect(result[:size]).to eq(4)
        expect(result[:source]).to be_an(Array)
        expect(result[:drain]).to be_an(Array)
      end
    end

    describe 'generate_toggle_matrix' do
      it 'generates toggle matrices of correct size' do
        rng = Random.new(1)
        result = described_class.send(:generate_toggle_matrix, 'easy', rng)

        expect(result[:size]).to eq(3)
        expect(result[:target_state]).to eq(true)
      end
    end
  end

  describe 'validation methods' do
    describe 'validate_pipe_network' do
      # 2x2 grid: source at [0,0], drain at [1,1]
      # Valid path: source connects N+S (straight rot=0), then [1,0] connects N+E (bend rot=0),
      #   [1,1] connects W+S (bend rot=2) to drain south
      let(:puzzle_data) { { 'source' => [0, 0], 'drain' => [1, 1], 'size' => 2 } }
      let(:puzzle) do
        double('DelvePuzzle',
               puzzle_type: 'pipe_network',
               puzzle_data: puzzle_data,
               grid_size: 2)
      end

      it 'returns true for a connected path from source to drain' do
        # Source [0,0]: straight rot=0 connects N+S (source connects north ✓)
        # [1,0]: bend rot=0 connects N+E (connects to source via N, to [1,1] via E)
        # [0,1]: straight rot=1 connects E+W (not on path)
        # [1,1]: bend rot=2 connects S+W (drain connects south ✓, connects to [1,0] via W)
        answer = [[{ 'type' => 'straight', 'rotation' => 0 }, { 'type' => 'straight', 'rotation' => 1 }],
                  [{ 'type' => 'bend', 'rotation' => 0 }, { 'type' => 'bend', 'rotation' => 2 }]]
        result = described_class.send(:validate_pipe_network, puzzle, answer)
        expect(result).to be true
      end

      it 'returns false when path is not connected' do
        # All straight horizontal - source won't connect north
        answer = [[{ 'type' => 'straight', 'rotation' => 1 }, { 'type' => 'straight', 'rotation' => 1 }],
                  [{ 'type' => 'straight', 'rotation' => 1 }, { 'type' => 'straight', 'rotation' => 1 }]]
        result = described_class.send(:validate_pipe_network, puzzle, answer)
        expect(result).to be false
      end

      it 'returns false for invalid answer format' do
        result = described_class.send(:validate_pipe_network, puzzle, 'invalid')
        expect(result).to be false
      end
    end

    describe 'validate_toggle_matrix' do
      let(:puzzle) { double('DelvePuzzle', puzzle_type: 'toggle_matrix', puzzle_data: { 'target_state' => true }) }

      it 'returns true when all cells match target' do
        result = described_class.send(:validate_toggle_matrix, puzzle, [[true, true], [true, true]])
        expect(result).to be true
      end

      it 'returns false when cells do not match target' do
        result = described_class.send(:validate_toggle_matrix, puzzle, [[true, false], [true, true]])
        expect(result).to be false
      end

      it 'returns false for invalid answer format' do
        result = described_class.send(:validate_toggle_matrix, puzzle, 'invalid')
        expect(result).to be false
      end
    end
  end

  describe 'help generation' do
    describe 'generate_help' do
      it 'generates help for symbol_grid' do
        puzzle = double('DelvePuzzle',
          puzzle_type: 'symbol_grid',
          clues: [{ x: 2, y: 3, symbol: 'B' }],
          solution: [%w[A B C D], %w[A B C D], %w[A B C D], %w[A B C D]],
          grid_size: 4
        )

        help = described_class.send(:generate_help, puzzle)

        expect(help).to be_a(String)
      end

      it 'generates help for pipe_network' do
        # 2x2 grid with source at [0,0] and drain at [1,1]
        initial = [
          [{ 'type' => 'bend', 'rotation' => 3 }, { 'type' => 'straight', 'rotation' => 0 }],
          [{ 'type' => 'straight', 'rotation' => 0 }, { 'type' => 'bend', 'rotation' => 1 }]
        ]
        solution = [
          [{ 'type' => 'bend', 'rotation' => 1 }, { 'type' => 'straight', 'rotation' => 0 }],
          [{ 'type' => 'straight', 'rotation' => 0 }, { 'type' => 'bend', 'rotation' => 2 }]
        ]
        puzzle = double('DelvePuzzle',
          puzzle_type: 'pipe_network',
          solution: solution,
          grid_size: 2,
          puzzle_data: { 'initial' => initial, 'source' => [0, 0], 'drain' => [1, 1] }
        )
        allow(puzzle).to receive(:update)

        help = described_class.send(:generate_help, puzzle)

        expect(help).to include('pipe')
      end

      it 'generates help for toggle_matrix' do
        puzzle = double('DelvePuzzle',
                        puzzle_type: 'toggle_matrix',
                        grid_size: 3,
                        puzzle_data: {
                          'initial' => [[true, false, true], [false, true, false], [true, false, true]],
                          'locked' => []
                        })
        allow(puzzle).to receive(:update)

        help = described_class.send(:generate_help, puzzle)

        expect(help).to include('ON position')
      end

      it 'generates generic help for unknown puzzle type' do
        puzzle = double('DelvePuzzle', puzzle_type: 'unknown')

        help = described_class.send(:generate_help, puzzle)

        expect(help).to eq('Study the puzzle carefully.')
      end

      it 'scales help count with puzzle size' do
        # Size 4 should reveal 2 symbols
        puzzle = double('DelvePuzzle',
          puzzle_type: 'symbol_grid',
          clues: [],
          solution: [%w[A B C D], %w[B A D C], %w[C D A B], %w[D C B A]],
          grid_size: 4
        )

        result = described_class.send(:generate_structured_help, puzzle)

        expect(result[:new_clues].size).to eq(2)
      end
    end
  end
end
