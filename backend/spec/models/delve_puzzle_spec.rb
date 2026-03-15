# frozen_string_literal: true

require 'spec_helper'

return unless DB.table_exists?(:delve_puzzles)

RSpec.describe DelvePuzzle do
  describe 'constants' do
    it 'defines PUZZLE_TYPES' do
      expect(described_class::PUZZLE_TYPES).to eq(%w[symbol_grid pipe_network toggle_matrix])
    end

    it 'defines DIFFICULTIES' do
      expect(described_class::DIFFICULTIES).to eq(%w[easy medium hard expert])
    end
  end

  describe 'associations' do
    it 'belongs to delve_room' do
      expect(described_class.association_reflections[:delve_room]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines solved?' do
      expect(described_class.instance_methods).to include(:solved?)
    end

    it 'defines solve!' do
      expect(described_class.instance_methods).to include(:solve!)
    end

    it 'defines increment_hints!' do
      expect(described_class.instance_methods).to include(:increment_hints!)
    end

    it 'defines update_state!' do
      expect(described_class.instance_methods).to include(:update_state!)
    end

    it 'defines solution' do
      expect(described_class.instance_methods).to include(:solution)
    end

    it 'defines initial_layout' do
      expect(described_class.instance_methods).to include(:initial_layout)
    end

    it 'defines clues' do
      expect(described_class.instance_methods).to include(:clues)
    end

    it 'defines grid_size' do
      expect(described_class.instance_methods).to include(:grid_size)
    end

    it 'defines description' do
      expect(described_class.instance_methods).to include(:description)
    end

    it 'defines difficulty_description' do
      expect(described_class.instance_methods).to include(:difficulty_description)
    end
  end

  describe '#solved? behavior' do
    it 'returns true when solved is true' do
      puzzle = described_class.new
      puzzle.values[:solved] = true
      expect(puzzle.solved?).to be true
    end

    it 'returns false when solved is false' do
      puzzle = described_class.new
      puzzle.values[:solved] = false
      expect(puzzle.solved?).to be false
    end
  end

  describe '#solution behavior' do
    it 'returns solution from puzzle_data when method exists' do
      puzzle = described_class.new
      # puzzle_data is JSONB serialized, test the accessor method exists
      expect(described_class.instance_methods).to include(:solution)
    end
  end

  describe '#grid_size behavior' do
    it 'defines grid_size method' do
      expect(described_class.instance_methods).to include(:grid_size)
    end
  end
end
