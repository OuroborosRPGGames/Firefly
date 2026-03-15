# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GamePatternBranch, type: :model do
  let(:character) { create(:character) }
  let(:game_pattern) { GamePattern.create(name: 'Test Game', created_by: character.id) }

  describe 'validations' do
    it 'requires game_pattern_id' do
      branch = GamePatternBranch.new(name: 'test', display_name: 'Test')
      expect(branch.valid?).to be false
    end

    it 'requires name' do
      branch = GamePatternBranch.new(game_pattern_id: game_pattern.id, display_name: 'Test')
      expect(branch.valid?).to be false
    end

    it 'requires display_name' do
      branch = GamePatternBranch.new(game_pattern_id: game_pattern.id, name: 'test')
      expect(branch.valid?).to be false
    end

    it 'is valid with required fields' do
      branch = GamePatternBranch.new(
        game_pattern_id: game_pattern.id,
        name: 'aggressive',
        display_name: 'Play Aggressive'
      )
      expect(branch.valid?).to be true
    end

    it 'validates name max length' do
      branch = GamePatternBranch.new(
        game_pattern_id: game_pattern.id,
        name: 'a' * 51,
        display_name: 'Test'
      )
      expect(branch.valid?).to be false
      expect(branch.errors[:name]).not_to be_empty
    end

    it 'validates display_name max length' do
      branch = GamePatternBranch.new(
        game_pattern_id: game_pattern.id,
        name: 'test',
        display_name: 'a' * 101
      )
      expect(branch.valid?).to be false
      expect(branch.errors[:display_name]).not_to be_empty
    end
  end

  describe 'associations' do
    it 'belongs to game_pattern' do
      branch = GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'test',
        display_name: 'Test'
      )
      expect(branch.game_pattern).to eq(game_pattern)
    end
  end

  describe '#uses_stat?' do
    it 'returns true when stat_id is set' do
      branch = GamePatternBranch.new(stat_id: 1)
      expect(branch.uses_stat?).to be true
    end

    it 'returns false when stat_id is nil' do
      branch = GamePatternBranch.new
      expect(branch.uses_stat?).to be false
    end
  end

  describe '#result_count' do
    it 'returns the number of results' do
      branch = GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'test',
        display_name: 'Test'
      )
      GamePatternResult.create(game_pattern_branch_id: branch.id, position: 1, message: 'Result 1')
      GamePatternResult.create(game_pattern_branch_id: branch.id, position: 2, message: 'Result 2')
      expect(branch.result_count).to eq(2)
    end
  end
end
