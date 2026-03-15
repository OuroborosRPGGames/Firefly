# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterSnapshot do
  let(:character) { create(:character) }
  let(:room) { create(:room) }
  # Minimal valid frozen_state for tests - empty hashes fail presence validation
  let(:valid_frozen_state) { { 'level' => 1, 'health' => 100 } }

  describe 'validations' do
    it 'requires character_id' do
      snapshot = described_class.new(name: 'Test', frozen_state: {}, snapshot_taken_at: Time.now)
      expect(snapshot.valid?).to be false
      expect(snapshot.errors[:character_id]).to include('is not present')
    end

    it 'requires name' do
      snapshot = described_class.new(character_id: character.id, frozen_state: {}, snapshot_taken_at: Time.now)
      expect(snapshot.valid?).to be false
      expect(snapshot.errors[:name]).to include('is not present')
    end

    it 'requires frozen_state' do
      snapshot = described_class.new(character_id: character.id, name: 'Test', snapshot_taken_at: Time.now)
      expect(snapshot.valid?).to be false
      expect(snapshot.errors[:frozen_state]).to include('is not present')
    end

    it 'requires snapshot_taken_at' do
      snapshot = described_class.new(character_id: character.id, name: 'Test', frozen_state: {})
      expect(snapshot.valid?).to be false
      expect(snapshot.errors[:snapshot_taken_at]).to include('is not present')
    end

    it 'validates unique name per character' do
      described_class.create(
        character_id: character.id,
        name: 'Unique Snapshot',
        frozen_state: Sequel.pg_jsonb_wrap(valid_frozen_state),
        snapshot_taken_at: Time.now
      )

      duplicate = described_class.new(
        character_id: character.id,
        name: 'Unique Snapshot',
        frozen_state: Sequel.pg_jsonb_wrap(valid_frozen_state),
        snapshot_taken_at: Time.now
      )
      expect(duplicate.valid?).to be false
      # Sequel puts uniqueness constraint errors on the columns involved
      expect(duplicate.errors.full_messages.join).to include('already taken')
    end

    it 'validates name max length' do
      snapshot = described_class.new(
        character_id: character.id,
        name: 'A' * 101,
        frozen_state: Sequel.pg_jsonb_wrap(valid_frozen_state),
        snapshot_taken_at: Time.now
      )
      expect(snapshot.valid?).to be false
      expect(snapshot.errors[:name]).not_to be_empty
    end

    it 'accepts valid snapshot' do
      snapshot = described_class.new(
        character_id: character.id,
        name: 'Valid Snapshot',
        frozen_state: Sequel.pg_jsonb_wrap(valid_frozen_state),
        snapshot_taken_at: Time.now
      )
      expect(snapshot.valid?).to be true
    end
  end

  describe 'associations' do
    let(:snapshot) do
      described_class.create(
        character_id: character.id,
        room_id: room.id,
        name: 'Test Snapshot',
        frozen_state: Sequel.pg_jsonb_wrap(valid_frozen_state),
        snapshot_taken_at: Time.now
      )
    end

    it 'belongs to character' do
      expect(snapshot.character).to eq(character)
    end

    it 'belongs to room' do
      expect(snapshot.room).to eq(room)
    end
  end

  describe '#can_enter?' do
    let(:other_character) { create(:character) }
    let(:snapshot) do
      described_class.create(
        character_id: character.id,
        name: 'Test Snapshot',
        frozen_state: Sequel.pg_jsonb_wrap(valid_frozen_state),
        allowed_character_ids: Sequel.pg_jsonb_wrap([character.id]),
        snapshot_taken_at: Time.now
      )
    end

    it 'returns true when character is in allowed list' do
      expect(snapshot.can_enter?(character)).to be true
    end

    it 'returns false when character is not in allowed list' do
      expect(snapshot.can_enter?(other_character)).to be false
    end
  end

  describe '#parsed_allowed_ids' do
    it 'returns empty array when nil' do
      snapshot = described_class.new
      snapshot.values[:allowed_character_ids] = nil
      expect(snapshot.parsed_allowed_ids).to eq([])
    end

    it 'parses JSON string' do
      snapshot = described_class.new
      snapshot.values[:allowed_character_ids] = '[1, 2, 3]'
      expect(snapshot.parsed_allowed_ids).to eq([1, 2, 3])
    end

    it 'handles invalid JSON gracefully' do
      snapshot = described_class.new
      snapshot.values[:id] = 1
      snapshot.values[:allowed_character_ids] = 'invalid json'
      expect(snapshot.parsed_allowed_ids).to eq([])
    end

    it 'converts JSONB to array' do
      snapshot = described_class.new
      snapshot.values[:allowed_character_ids] = Sequel.pg_jsonb_wrap([1, 2, 3])
      result = snapshot.parsed_allowed_ids
      expect(result.to_a).to eq([1, 2, 3])
    end
  end

  describe '#parsed_frozen_state' do
    it 'returns empty hash when nil' do
      snapshot = described_class.new
      snapshot.values[:frozen_state] = nil
      expect(snapshot.parsed_frozen_state).to eq({})
    end

    it 'parses JSON string' do
      snapshot = described_class.new
      snapshot.values[:frozen_state] = '{"level": 5, "health": 100}'
      expect(snapshot.parsed_frozen_state).to eq({ 'level' => 5, 'health' => 100 })
    end

    it 'handles invalid JSON gracefully' do
      snapshot = described_class.new
      snapshot.values[:id] = 1
      snapshot.values[:frozen_state] = 'invalid json'
      expect(snapshot.parsed_frozen_state).to eq({})
    end

    it 'returns JSONB hash directly' do
      snapshot = described_class.new
      hash = { 'level' => 5 }
      snapshot.values[:frozen_state] = hash
      expect(snapshot.parsed_frozen_state).to eq(hash)
    end
  end

  describe '#parsed_frozen_inventory' do
    it 'returns empty array when nil' do
      snapshot = described_class.new
      snapshot.values[:frozen_inventory] = nil
      expect(snapshot.parsed_frozen_inventory).to eq([])
    end

    it 'parses JSON string' do
      snapshot = described_class.new
      snapshot.values[:frozen_inventory] = '[{"name": "Sword"}]'
      expect(snapshot.parsed_frozen_inventory).to eq([{ 'name' => 'Sword' }])
    end

    it 'handles invalid JSON gracefully' do
      snapshot = described_class.new
      snapshot.values[:id] = 1
      snapshot.values[:frozen_inventory] = 'invalid'
      expect(snapshot.parsed_frozen_inventory).to eq([])
    end
  end

  describe '#parsed_frozen_descriptions' do
    it 'returns empty array when nil' do
      snapshot = described_class.new
      snapshot.values[:frozen_descriptions] = nil
      expect(snapshot.parsed_frozen_descriptions).to eq([])
    end

    it 'parses JSON string' do
      snapshot = described_class.new
      snapshot.values[:frozen_descriptions] = '[{"content": "Tall"}]'
      expect(snapshot.parsed_frozen_descriptions).to eq([{ 'content' => 'Tall' }])
    end

    it 'handles invalid JSON gracefully' do
      snapshot = described_class.new
      snapshot.values[:id] = 1
      snapshot.values[:frozen_descriptions] = 'invalid'
      expect(snapshot.parsed_frozen_descriptions).to eq([])
    end
  end

  describe '#allowed_characters' do
    let(:other_character) { create(:character) }
    let(:snapshot) do
      described_class.create(
        character_id: character.id,
        name: 'Test',
        frozen_state: Sequel.pg_jsonb_wrap(valid_frozen_state),
        allowed_character_ids: Sequel.pg_jsonb_wrap([character.id, other_character.id]),
        snapshot_taken_at: Time.now
      )
    end

    it 'returns Character objects for allowed IDs' do
      allowed = snapshot.allowed_characters
      expect(allowed).to include(character, other_character)
    end
  end

  describe '.capture' do
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }

    before do
      allow_any_instance_of(Room).to receive(:characters_here).and_return(
        double(select_map: [character.id])
      )
    end

    it 'creates a snapshot with character data' do
      snapshot = described_class.capture(character_instance, name: 'Test Capture')

      expect(snapshot.id).not_to be_nil
      expect(snapshot.character_id).to eq(character.id)
      expect(snapshot.room_id).to eq(room.id)
      expect(snapshot.name).to eq('Test Capture')
      expect(snapshot.snapshot_taken_at).not_to be_nil
    end

    it 'captures allowed character IDs' do
      snapshot = described_class.capture(character_instance, name: 'Test')
      expect(snapshot.parsed_allowed_ids).to include(character.id)
    end

    it 'accepts optional description' do
      snapshot = described_class.capture(
        character_instance,
        name: 'Described',
        description: 'A meaningful moment'
      )
      expect(snapshot.description).to eq('A meaningful moment')
    end
  end

  describe '#restore_to_instance' do
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }
    let(:frozen_state) do
      {
        'level' => 10,
        'health' => 80,
        'max_health' => 100,
        'mana' => 40,
        'max_mana' => 50,
        'experience' => 5000,
        'stance' => 'sitting',
        'stats' => [],
        'abilities' => []
      }
    end
    let(:snapshot) do
      described_class.create(
        character_id: character.id,
        name: 'Restore Test',
        frozen_state: Sequel.pg_jsonb_wrap(frozen_state),
        snapshot_taken_at: Time.now
      )
    end

    it 'restores character instance state from snapshot' do
      snapshot.restore_to_instance(character_instance)
      character_instance.reload

      expect(character_instance.level).to eq(10)
      expect(character_instance.health).to eq(80)
      expect(character_instance.max_health).to eq(100)
      expect(character_instance.mana).to eq(40)
      expect(character_instance.max_mana).to eq(50)
    end

    it 'always restores status as alive' do
      snapshot.restore_to_instance(character_instance)
      character_instance.reload

      expect(character_instance.status).to eq('alive')
    end
  end
end
