# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterLookupHelper do
  # Create a test class that includes the helper
  let(:test_class) { Class.new { include CharacterLookupHelper }.new }

  let(:room) { create(:room) }
  let(:other_room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character1) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:character2) { create(:character, forename: 'Bob', surname: 'Jones') }
  let(:character3) { create(:character, forename: 'Charlie') }

  describe '#find_online_character' do
    let!(:online_instance) do
      create(:character_instance, character: character1, reality: reality, current_room: room, online: true)
    end
    let!(:offline_instance) do
      create(:character_instance, character: character2, reality: reality, current_room: room, online: false)
    end

    it 'returns the online character instance' do
      result = test_class.find_online_character(character1.id)
      expect(result).to eq online_instance
    end

    it 'returns nil for offline characters' do
      result = test_class.find_online_character(character2.id)
      expect(result).to be_nil
    end

    it 'returns nil for nil character_id' do
      result = test_class.find_online_character(nil)
      expect(result).to be_nil
    end

    it 'returns nil for non-existent character' do
      result = test_class.find_online_character(999_999)
      expect(result).to be_nil
    end
  end

  describe '#find_characters_in_room' do
    let!(:instance1) do
      create(:character_instance, character: character1, reality: reality, current_room: room, online: true)
    end
    let!(:instance2) do
      create(:character_instance, character: character2, reality: reality, current_room: room, online: true)
    end
    let!(:offline_instance) do
      create(:character_instance, character: character3, reality: reality, current_room: room, online: false)
    end
    let!(:other_room_instance) do
      create(:character_instance, character: create(:character), reality: reality, current_room: other_room, online: true)
    end

    it 'returns only online characters in the specified room' do
      result = test_class.find_characters_in_room(room.id)
      expect(result).to contain_exactly(instance1, instance2)
    end

    it 'does not include offline characters' do
      result = test_class.find_characters_in_room(room.id)
      expect(result).not_to include(offline_instance)
    end

    it 'does not include characters in other rooms' do
      result = test_class.find_characters_in_room(room.id)
      expect(result).not_to include(other_room_instance)
    end

    it 'returns empty array for nil room_id' do
      result = test_class.find_characters_in_room(nil)
      expect(result).to eq []
    end

    it 'returns empty array for room with no characters' do
      empty_room = create(:room)
      result = test_class.find_characters_in_room(empty_room.id)
      expect(result).to eq []
    end
  end

  describe '#find_all_online_characters' do
    let!(:instance1) do
      create(:character_instance, character: character1, reality: reality, current_room: room, online: true)
    end
    let!(:instance2) do
      create(:character_instance, character: character2, reality: reality, current_room: other_room, online: true)
    end
    let!(:offline_instance) do
      create(:character_instance, character: character3, reality: reality, current_room: room, online: false)
    end

    it 'returns all online characters' do
      result = test_class.find_all_online_characters
      expect(result).to include(instance1, instance2)
    end

    it 'does not include offline characters' do
      result = test_class.find_all_online_characters
      expect(result).not_to include(offline_instance)
    end
  end

  describe '#find_others_in_room' do
    let!(:instance1) do
      create(:character_instance, character: character1, reality: reality, current_room: room, online: true)
    end
    let!(:instance2) do
      create(:character_instance, character: character2, reality: reality, current_room: room, online: true)
    end

    it 'returns other online characters excluding the specified one' do
      result = test_class.find_others_in_room(room.id, exclude_id: instance1.id)
      expect(result).to contain_exactly(instance2)
    end

    it 'returns all online characters when exclude_id is not in room' do
      result = test_class.find_others_in_room(room.id, exclude_id: 999_999)
      expect(result).to contain_exactly(instance1, instance2)
    end

    it 'returns empty array for nil room_id' do
      result = test_class.find_others_in_room(nil, exclude_id: instance1.id)
      expect(result).to eq []
    end
  end

  describe '#find_character_room_then_global' do
    let!(:alice_instance) do
      create(:character_instance, character: character1, reality: reality, current_room: room, online: true, status: 'alive')
    end
    let!(:bob_instance) do
      create(:character_instance, character: character2, reality: reality, current_room: other_room, online: true, status: 'alive')
    end

    it 'finds character in the same room by exact name' do
      result = test_class.find_character_room_then_global('Alice', room: room)
      expect(result).to eq alice_instance
    end

    it 'finds character in the same room by partial name' do
      result = test_class.find_character_room_then_global('Ali', room: room)
      expect(result).to eq alice_instance
    end

    it 'finds character globally when not in room' do
      result = test_class.find_character_room_then_global('Bob', room: room)
      expect(result).to eq bob_instance
    end

    it 'returns nil for empty name' do
      result = test_class.find_character_room_then_global('', room: room)
      expect(result).to be_nil
    end

    it 'returns nil for nil name' do
      result = test_class.find_character_room_then_global(nil, room: room)
      expect(result).to be_nil
    end

    it 'respects exclude_instance_id' do
      result = test_class.find_character_room_then_global(
        'Alice',
        room: room,
        exclude_instance_id: alice_instance.id
      )
      expect(result).to be_nil
    end

    it 'respects reality_id filter' do
      other_reality = create(:reality)
      result = test_class.find_character_room_then_global(
        'Alice',
        room: room,
        reality_id: other_reality.id
      )
      # Alice is in a different reality, so should not match
      expect(result).to be_nil
    end
  end

  describe '#find_character_by_name_globally' do
    let!(:alice) { create(:character, forename: 'Alice', surname: 'Smith') }
    let!(:bob) { create(:character, forename: 'Bob', surname: 'Jones') }

    it 'finds character by exact forename' do
      result = test_class.find_character_by_name_globally('Alice')
      expect(result).to eq alice
    end

    it 'finds character by case-insensitive forename' do
      result = test_class.find_character_by_name_globally('alice')
      expect(result).to eq alice
    end

    it 'finds character by partial name match' do
      result = test_class.find_character_by_name_globally('Ali')
      expect(result).to eq alice
    end

    it 'returns nil for empty name' do
      result = test_class.find_character_by_name_globally('')
      expect(result).to be_nil
    end

    it 'returns nil for nil name' do
      result = test_class.find_character_by_name_globally(nil)
      expect(result).to be_nil
    end

    it 'returns nil when no match found' do
      result = test_class.find_character_by_name_globally('Nonexistent')
      expect(result).to be_nil
    end
  end
end
