# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterKnowledge do
  let!(:user1) { User.create(username: 'user1', email: 'user1@example.com', password_hash: 'hash1', salt: 'salt1') }
  let!(:user2) { User.create(username: 'user2', email: 'user2@example.com', password_hash: 'hash2', salt: 'salt2') }
  
  let!(:knower_character) do
    Character.create(
      user: user1,
      forename: 'Alice',
      surname: 'Smith',
      race: 'human',
      character_class: 'warrior',
      is_npc: false
    )
  end

  let!(:known_character) do
    Character.create(
      user: user2,
      forename: 'Bob',
      surname: 'Jones',
      race: 'elf',
      character_class: 'mage',
      is_npc: false
    )
  end

  describe 'validations' do
    it 'requires knower_character_id' do
      knowledge = CharacterKnowledge.new(known_character_id: known_character.id)
      expect(knowledge).not_to be_valid
      expect(knowledge.errors[:knower_character_id]).to include("is not present")
    end

    it 'requires known_character_id' do
      knowledge = CharacterKnowledge.new(knower_character_id: knower_character.id)
      expect(knowledge).not_to be_valid
      expect(knowledge.errors[:known_character_id]).to include("is not present")
    end

    it 'prevents self-knowledge' do
      knowledge = CharacterKnowledge.new(
        knower_character_id: knower_character.id,
        known_character_id: knower_character.id
      )
      expect(knowledge).not_to be_valid
      expect(knowledge.errors[:base]).to include("Character cannot have knowledge about themselves")
    end

    it 'is valid with different characters' do
      knowledge = CharacterKnowledge.new(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id
      )
      expect(knowledge).to be_valid
    end
  end

  describe 'before_save callbacks' do
    let!(:knowledge) do
      CharacterKnowledge.create(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id
      )
    end

    it 'sets default is_known to false' do
      expect(knowledge.is_known).to be false
    end

    it 'sets first_met_at timestamp' do
      expect(knowledge.first_met_at).not_to be_nil
      expect(knowledge.first_met_at).to be_within(1).of(Time.now)
    end

    it 'sets last_seen_at timestamp' do
      expect(knowledge.last_seen_at).not_to be_nil
      expect(knowledge.last_seen_at).to be_within(1).of(Time.now)
    end
  end

  describe 'associations' do
    let!(:knowledge) do
      CharacterKnowledge.create(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id
      )
    end

    it 'belongs to knower_character' do
      expect(knowledge.knower_character).to eq(knower_character)
    end

    it 'belongs to known_character' do
      expect(knowledge.known_character).to eq(known_character)
    end
  end

  describe '#mark_seen!' do
    let!(:knowledge) do
      CharacterKnowledge.create(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id,
        last_seen_at: Time.now - 3600
      )
    end

    it 'updates last_seen_at to current time' do
      old_time = knowledge.last_seen_at
      knowledge.mark_seen!
      knowledge.reload
      
      expect(knowledge.last_seen_at).to be > old_time
      expect(knowledge.last_seen_at).to be_within(1).of(Time.now)
    end
  end

  describe '#mark_known!' do
    let!(:knowledge) do
      CharacterKnowledge.create(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id,
        is_known: false,
        known_name: nil,
        last_seen_at: Time.now - 3600
      )
    end

    context 'with a custom name' do
      it 'marks as known with custom name' do
        knowledge.mark_known!('Sir Bob')
        knowledge.reload
        
        expect(knowledge.is_known).to be true
        expect(knowledge.known_name).to eq('Sir Bob')
        expect(knowledge.last_seen_at).to be_within(1).of(Time.now)
      end
    end

    context 'without a custom name' do
      it 'marks as known with full name' do
        knowledge.mark_known!
        knowledge.reload
        
        expect(knowledge.is_known).to be true
        expect(knowledge.known_name).to eq('Bob Jones')
        expect(knowledge.last_seen_at).to be_within(1).of(Time.now)
      end
    end
  end

  describe '#mark_unknown!' do
    let!(:knowledge) do
      CharacterKnowledge.create(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id,
        is_known: true,
        known_name: 'Sir Bob'
      )
    end

    it 'marks as unknown and clears known_name' do
      knowledge.mark_unknown!
      knowledge.reload
      
      expect(knowledge.is_known).to be false
      expect(knowledge.known_name).to be_nil
    end
  end

  describe 'unique constraint' do
    let!(:existing_knowledge) do
      CharacterKnowledge.create(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id
      )
    end

    it 'prevents duplicate knowledge entries' do
      duplicate = CharacterKnowledge.new(
        knower_character_id: knower_character.id,
        known_character_id: known_character.id
      )
      
      expect { duplicate.save }.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end
end