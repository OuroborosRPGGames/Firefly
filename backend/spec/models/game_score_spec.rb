# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GameScore, type: :model do
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character) }
  let(:game_pattern) { GamePattern.create(name: 'Test', created_by: character.id) }
  let(:room) { create(:room) }
  let(:game_instance) { GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id) }

  describe 'validations' do
    it 'requires game_instance_id' do
      score = GameScore.new(character_instance_id: character_instance.id)
      expect(score.valid?).to be false
    end

    it 'requires character_instance_id' do
      score = GameScore.new(game_instance_id: game_instance.id)
      expect(score.valid?).to be false
    end

    it 'is valid with required fields' do
      score = GameScore.new(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id
      )
      expect(score.valid?).to be true
    end
  end

  describe '#add_points' do
    it 'adds points to score' do
      score = GameScore.create(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id,
        score: 10
      )
      score.add_points(5)
      expect(score.reload.score).to eq(15)
    end

    it 'handles nil score' do
      score = GameScore.create(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id
      )
      score.add_points(5)
      expect(score.reload.score).to eq(5)
    end
  end

  describe '#reset!' do
    it 'sets score to zero' do
      score = GameScore.create(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id,
        score: 25
      )
      score.reset!
      expect(score.reload.score).to eq(0)
    end
  end

  describe '.for_player' do
    it 'finds or creates score for player' do
      score = GameScore.for_player(game_instance, character_instance)
      expect(score).to be_a(GameScore)
      expect(score.game_instance_id).to eq(game_instance.id)
      expect(score.character_instance_id).to eq(character_instance.id)
    end

    it 'returns existing score if present' do
      existing = GameScore.create(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id,
        score: 42
      )
      found = GameScore.for_player(game_instance, character_instance)
      expect(found.id).to eq(existing.id)
      expect(found.score).to eq(42)
    end

    it 'initializes score to 0 for new records' do
      score = GameScore.for_player(game_instance, character_instance)
      expect(score.score).to eq(0)
    end
  end

  describe '.clear_for_room' do
    it 'deletes all scores for games in a room' do
      GameScore.create(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id,
        score: 10
      )
      expect { GameScore.clear_for_room(room.id, character_instance.id) }
        .to change { GameScore.count }.by(-1)
    end

    it 'does nothing when room has no games' do
      other_room = create(:room)
      GameScore.create(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id,
        score: 10
      )
      expect { GameScore.clear_for_room(other_room.id, character_instance.id) }
        .not_to(change { GameScore.count })
    end
  end

  describe '.clear_for_items' do
    it 'deletes scores for games on items owned by character' do
      item = create(:item, character_instance: character_instance)
      item_game = GameInstance.create(game_pattern_id: game_pattern.id, item_id: item.id)
      GameScore.create(
        game_instance_id: item_game.id,
        character_instance_id: character_instance.id,
        score: 10
      )
      expect { GameScore.clear_for_items(character_instance.id) }
        .to change { GameScore.count }.by(-1)
    end

    it 'does nothing when character has no items with games' do
      GameScore.create(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id,
        score: 10
      )
      expect { GameScore.clear_for_items(character_instance.id) }
        .not_to(change { GameScore.count })
    end
  end
end
