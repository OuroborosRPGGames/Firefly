# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GameInstance, type: :model do
  let(:character) { create(:character) }
  let(:game_pattern) { GamePattern.create(name: 'Test', created_by: character.id) }
  let(:room) { create(:room) }
  let(:item) { create(:item, :in_room, room: room) }

  describe 'validations' do
    it 'requires game_pattern_id' do
      instance = GameInstance.new(room_id: room.id)
      expect(instance.valid?).to be false
    end

    it 'requires either item_id or room_id' do
      instance = GameInstance.new(game_pattern_id: game_pattern.id)
      expect(instance.valid?).to be false
      expect(instance.errors[:base]).to include('Must be attached to either an item or a room')
    end

    it 'cannot have both item_id and room_id' do
      instance = GameInstance.new(
        game_pattern_id: game_pattern.id,
        item_id: item.id,
        room_id: room.id
      )
      expect(instance.valid?).to be false
      expect(instance.errors[:base]).to include('Cannot be attached to both an item and a room')
    end

    it 'is valid with pattern and room' do
      instance = GameInstance.new(game_pattern_id: game_pattern.id, room_id: room.id)
      expect(instance.valid?).to be true
    end

    it 'is valid with pattern and item' do
      instance = GameInstance.new(game_pattern_id: game_pattern.id, item_id: item.id)
      expect(instance.valid?).to be true
    end

    it 'validates custom_name max length' do
      instance = GameInstance.new(
        game_pattern_id: game_pattern.id,
        room_id: room.id,
        custom_name: 'a' * 101
      )
      expect(instance.valid?).to be false
    end
  end

  describe '#display_name' do
    it 'returns custom_name if set' do
      instance = GameInstance.new(custom_name: 'My Darts', game_pattern_id: game_pattern.id)
      expect(instance.display_name).to eq('My Darts')
    end

    it 'returns pattern name if no custom_name' do
      instance = GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id)
      expect(instance.display_name).to eq('Test')
    end

    it 'returns Unknown Game if no pattern' do
      instance = GameInstance.new
      expect(instance.display_name).to eq('Unknown Game')
    end
  end

  describe '#room_fixture?' do
    it 'returns true when attached to room' do
      instance = GameInstance.new(room_id: room.id)
      expect(instance.room_fixture?).to be true
    end

    it 'returns false when attached to item' do
      instance = GameInstance.new(item_id: item.id)
      expect(instance.room_fixture?).to be false
    end
  end

  describe '#item_attached?' do
    it 'returns true when attached to item' do
      instance = GameInstance.new(item_id: item.id)
      expect(instance.item_attached?).to be true
    end

    it 'returns false when attached to room' do
      instance = GameInstance.new(room_id: room.id)
      expect(instance.item_attached?).to be false
    end
  end

  describe '#scoring?' do
    it 'returns true when pattern has scoring' do
      game_pattern.update(has_scoring: true)
      instance = GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id)
      expect(instance.scoring?).to be true
    end

    it 'returns false when pattern has no scoring' do
      instance = GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id)
      expect(instance.scoring?).to be false
    end

    it 'returns false when no pattern' do
      instance = GameInstance.new
      expect(instance.scoring?).to be false
    end
  end

  describe '#branches' do
    it 'returns branches from pattern' do
      branch = GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'test',
        display_name: 'Test'
      )
      instance = GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id)
      expect(instance.branches).to include(branch)
    end

    it 'returns empty array when no pattern' do
      instance = GameInstance.new
      expect(instance.branches).to eq([])
    end
  end

  describe '#single_branch?' do
    it 'returns true when pattern has one branch' do
      GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'test',
        display_name: 'Test'
      )
      instance = GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id)
      expect(instance.single_branch?).to be true
    end

    it 'returns false when pattern has multiple branches' do
      GamePatternBranch.create(game_pattern_id: game_pattern.id, name: 'a', display_name: 'A')
      GamePatternBranch.create(game_pattern_id: game_pattern.id, name: 'b', display_name: 'B')
      instance = GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id)
      expect(instance.single_branch?).to be false
    end
  end
end
