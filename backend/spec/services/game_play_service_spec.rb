# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GamePlayService, type: :service do
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character) }
  let(:room) { create(:room) }
  let(:game_pattern) { GamePattern.create(name: 'Darts', created_by: character.id, has_scoring: true) }
  let(:branch) do
    GamePatternBranch.create(
      game_pattern_id: game_pattern.id,
      name: 'normal',
      display_name: 'Play Normal'
    )
  end

  before do
    # Add results: best to worst
    GamePatternResult.create(game_pattern_branch_id: branch.id, position: 1, message: '**BULLSEYE!**', points: 10)
    GamePatternResult.create(game_pattern_branch_id: branch.id, position: 2, message: 'Good shot!', points: 5)
    GamePatternResult.create(game_pattern_branch_id: branch.id, position: 3, message: 'You missed.', points: 0)

    # Put character in the room
    character_instance.update(current_room_id: room.id)
  end

  let(:game_instance) { GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id) }

  describe '.play' do
    it 'returns a result hash' do
      result = GamePlayService.play(game_instance, branch, character_instance)

      expect(result).to be_a(Hash)
      expect(result[:success]).to be true
      expect(result[:result]).to be_a(GamePatternResult)
      expect(result[:message]).to be_a(String)
    end

    it 'updates score when scoring enabled' do
      GamePlayService.play(game_instance, branch, character_instance)

      score = GameScore.for_player(game_instance, character_instance)
      expect(score.score).to be >= 0
    end

    it 'includes score in result when scoring enabled' do
      result = GamePlayService.play(game_instance, branch, character_instance)

      expect(result[:points]).to be_a(Integer)
      expect(result[:total_score]).to be_a(Integer)
    end

    it 'returns error when no results configured' do
      empty_branch = GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'empty',
        display_name: 'Empty Branch'
      )

      result = GamePlayService.play(game_instance, empty_branch, character_instance)

      expect(result[:success]).to be false
      expect(result[:error]).to include('No results configured')
    end
  end

  describe '.calculate_weights' do
    it 'assigns higher probability to worse results' do
      weights = GamePlayService.calculate_weights(branch.results)

      # First result (best) should have lowest weight
      # Last result (worst) should have highest weight
      expect(weights.first).to be < weights.last
    end

    it 'sums to approximately 100' do
      weights = GamePlayService.calculate_weights(branch.results)
      total = weights.sum

      expect(total).to be_within(1).of(100)
    end

    it 'returns 100 for single result' do
      single_branch = GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'single',
        display_name: 'Single Result'
      )
      GamePatternResult.create(game_pattern_branch_id: single_branch.id, position: 1, message: 'Only result')

      weights = GamePlayService.calculate_weights(single_branch.results)
      expect(weights).to eq([100.0])
    end
  end

  describe '.calculate_stat_modifier' do
    let(:stat_block) { create(:stat_block) }
    let(:stat) { Stat.create(stat_block_id: stat_block.id, name: 'Dexterity', abbreviation: 'DEX') }

    before do
      branch.update(stat_id: stat.id)
    end

    it 'returns 0 when no stat configured' do
      branch.update(stat_id: nil)
      modifier = GamePlayService.calculate_stat_modifier(branch, character_instance, room)
      expect(modifier).to eq(0)
    end

    it 'returns a modifier between -0.4 and 0.4' do
      modifier = GamePlayService.calculate_stat_modifier(branch, character_instance, room)
      expect(modifier).to be_between(-0.4, 0.4)
    end
  end
end
