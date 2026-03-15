# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GamePatternResult, type: :model do
  let(:character) { create(:character) }
  let(:game_pattern) { GamePattern.create(name: 'Test', created_by: character.id) }
  let(:branch) do
    GamePatternBranch.create(
      game_pattern_id: game_pattern.id,
      name: 'test',
      display_name: 'Test'
    )
  end

  describe 'validations' do
    it 'requires game_pattern_branch_id' do
      result = GamePatternResult.new(position: 1, message: 'Test')
      expect(result.valid?).to be false
    end

    it 'requires position' do
      result = GamePatternResult.new(game_pattern_branch_id: branch.id, message: 'Test')
      expect(result.valid?).to be false
    end

    it 'requires message' do
      result = GamePatternResult.new(game_pattern_branch_id: branch.id, position: 1)
      expect(result.valid?).to be false
    end

    it 'is valid with required fields' do
      result = GamePatternResult.new(
        game_pattern_branch_id: branch.id,
        position: 1,
        message: '**BULLSEYE!**'
      )
      expect(result.valid?).to be true
    end

    it 'validates position is at least 1' do
      result = GamePatternResult.new(
        game_pattern_branch_id: branch.id,
        position: 0,
        message: 'Test'
      )
      expect(result.valid?).to be false
    end
  end

  describe '#best?' do
    it 'returns true for position 1' do
      result = GamePatternResult.new(position: 1)
      expect(result.best?).to be true
    end

    it 'returns false for other positions' do
      result = GamePatternResult.new(position: 2)
      expect(result.best?).to be false
    end
  end

  describe '#worst?' do
    it 'returns true when position equals result_count' do
      result1 = GamePatternResult.create(game_pattern_branch_id: branch.id, position: 1, message: 'Best')
      result2 = GamePatternResult.create(game_pattern_branch_id: branch.id, position: 2, message: 'Worst')
      expect(result2.worst?).to be true
      expect(result1.worst?).to be false
    end

    it 'returns false when no branch' do
      result = GamePatternResult.new(position: 1)
      expect(result.worst?).to be false
    end
  end

  describe '#point_value' do
    it 'returns points when set' do
      result = GamePatternResult.new(points: 10)
      expect(result.point_value).to eq(10)
    end

    it 'returns 0 when points is nil' do
      result = GamePatternResult.new
      expect(result.point_value).to eq(0)
    end
  end
end
