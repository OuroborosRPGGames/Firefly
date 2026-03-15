# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pet do
  let(:character) { create(:character) }
  let(:room) { create(:room) }

  describe 'constants' do
    it 'defines PET_TYPES' do
      expect(described_class::PET_TYPES).to eq(%w[dog cat bird horse familiar mythical])
    end

    it 'defines MOODS' do
      expect(described_class::MOODS).to eq(%w[happy content tired hungry playful scared aggressive])
    end
  end

  describe 'validations' do
    it 'requires owner_id' do
      pet = described_class.new(name: 'Buddy', species: 'Dog')
      expect(pet.valid?).to be false
      expect(pet.errors[:owner_id]).to include('is not present')
    end

    it 'requires name' do
      pet = described_class.new(owner_id: character.id, species: 'Dog')
      expect(pet.valid?).to be false
      expect(pet.errors[:name]).to include('is not present')
    end

    it 'requires species' do
      pet = described_class.new(owner_id: character.id, name: 'Buddy')
      expect(pet.valid?).to be false
      expect(pet.errors[:species]).to include('is not present')
    end

    it 'validates name max length' do
      pet = described_class.new(owner_id: character.id, name: 'A' * 51, species: 'Dog')
      expect(pet.valid?).to be false
      expect(pet.errors[:name]).not_to be_empty
    end

    it 'validates species max length' do
      pet = described_class.new(owner_id: character.id, name: 'Buddy', species: 'A' * 51)
      expect(pet.valid?).to be false
      expect(pet.errors[:species]).not_to be_empty
    end

    it 'validates pet_type is in PET_TYPES' do
      pet = described_class.new(owner_id: character.id, name: 'Buddy', species: 'Dog', pet_type: 'invalid')
      expect(pet.valid?).to be false
      expect(pet.errors[:pet_type]).not_to be_empty
    end

    it 'validates mood is in MOODS' do
      pet = described_class.new(owner_id: character.id, name: 'Buddy', species: 'Dog', mood: 'invalid')
      expect(pet.valid?).to be false
      expect(pet.errors[:mood]).not_to be_empty
    end

    it 'accepts valid pet_type' do
      described_class::PET_TYPES.each do |pet_type|
        pet = described_class.new(owner_id: character.id, name: 'Buddy', species: 'Dog', pet_type: pet_type)
        expect(pet.valid?).to(be(true), "Expected pet_type '#{pet_type}' to be valid, got errors: #{pet.errors.full_messages}")
      end
    end

    it 'accepts valid mood' do
      described_class::MOODS.each do |mood|
        pet = described_class.new(owner_id: character.id, name: 'Buddy', species: 'Dog', mood: mood)
        expect(pet.valid?).to(be(true), "Expected mood '#{mood}' to be valid, got errors: #{pet.errors.full_messages}")
      end
    end
  end

  describe '#before_save defaults' do
    let(:pet) { described_class.create(owner_id: character.id, name: 'Buddy', species: 'Dog') }

    it 'defaults pet_type to dog' do
      expect(pet.pet_type).to eq('dog')
    end

    it 'defaults mood to content' do
      expect(pet.mood).to eq('content')
    end

    it 'defaults following to true' do
      expect(pet.following).to be true
    end

    it 'defaults loyalty to 50' do
      expect(pet.loyalty).to eq(50)
    end
  end

  describe '#following?' do
    it 'returns true when following is true' do
      pet = described_class.new(following: true)
      expect(pet.following?).to be true
    end

    it 'returns false when following is false' do
      pet = described_class.new(following: false)
      expect(pet.following?).to be false
    end

    it 'returns false when following is nil' do
      pet = described_class.new(following: nil)
      expect(pet.following?).to be false
    end
  end

  describe '#follow!' do
    let(:pet) { described_class.create(owner_id: character.id, name: 'Buddy', species: 'Dog', following: false) }

    it 'sets following to true' do
      pet.follow!
      expect(pet.following).to be true
    end
  end

  describe '#stay!' do
    let(:pet) { described_class.create(owner_id: character.id, name: 'Buddy', species: 'Dog', following: true) }

    it 'sets following to false' do
      pet.stay!
      expect(pet.following).to be false
    end
  end

  describe '#happy?' do
    it 'returns true when mood is happy' do
      pet = described_class.new(mood: 'happy')
      expect(pet.happy?).to be true
    end

    it 'returns false when mood is not happy' do
      pet = described_class.new(mood: 'content')
      expect(pet.happy?).to be false
    end
  end

  describe '#needs_attention?' do
    it 'returns true when mood is hungry' do
      pet = described_class.new(mood: 'hungry')
      expect(pet.needs_attention?).to be true
    end

    it 'returns true when mood is tired' do
      pet = described_class.new(mood: 'tired')
      expect(pet.needs_attention?).to be true
    end

    it 'returns true when mood is scared' do
      pet = described_class.new(mood: 'scared')
      expect(pet.needs_attention?).to be true
    end

    it 'returns false when mood is happy' do
      pet = described_class.new(mood: 'happy')
      expect(pet.needs_attention?).to be false
    end

    it 'returns false when mood is content' do
      pet = described_class.new(mood: 'content')
      expect(pet.needs_attention?).to be false
    end

    it 'returns false when mood is playful' do
      pet = described_class.new(mood: 'playful')
      expect(pet.needs_attention?).to be false
    end
  end

  describe '#loyal?' do
    it 'returns true when loyalty >= 70' do
      pet = described_class.new(loyalty: 70)
      expect(pet.loyal?).to be true
    end

    it 'returns true when loyalty > 70' do
      pet = described_class.new(loyalty: 100)
      expect(pet.loyal?).to be true
    end

    it 'returns false when loyalty < 70' do
      pet = described_class.new(loyalty: 69)
      expect(pet.loyal?).to be false
    end
  end

  describe '#follow_owner!' do
    let(:owner_instance) { create(:character_instance, character: character, current_room: room) }
    let(:pet) { described_class.create(owner_id: character.id, name: 'Buddy', species: 'Dog', following: true) }

    it 'updates current_room_id when following is true' do
      pet.follow_owner!(owner_instance)
      expect(pet.current_room_id).to eq(room.id)
    end

    it 'does not update when following is false' do
      pet.update(following: false)
      pet.follow_owner!(owner_instance)
      expect(pet.current_room_id).to be_nil
    end
  end

  describe '#react_to' do
    let(:pet) { described_class.create(owner_id: character.id, name: 'Buddy', species: 'Dog', mood: 'content', loyalty: 50) }

    context 'when fed' do
      it 'sets mood to happy' do
        pet.react_to(:fed)
        expect(pet.mood).to eq('happy')
      end

      it 'increases loyalty by 5' do
        pet.react_to(:fed)
        expect(pet.loyalty).to eq(55)
      end

      it 'caps loyalty at 100' do
        pet.update(loyalty: 98)
        pet.react_to(:fed)
        expect(pet.loyalty).to eq(100)
      end
    end

    context 'when petted' do
      it 'sets mood to content' do
        pet.update(mood: 'hungry')
        pet.react_to(:petted)
        expect(pet.mood).to eq('content')
      end

      it 'increases loyalty by 2' do
        pet.react_to(:petted)
        expect(pet.loyalty).to eq(52)
      end

      it 'caps loyalty at 100' do
        pet.update(loyalty: 99)
        pet.react_to(:petted)
        expect(pet.loyalty).to eq(100)
      end
    end

    context 'when neglected' do
      it 'sets mood to hungry' do
        pet.react_to(:neglected)
        expect(pet.mood).to eq('hungry')
      end

      it 'decreases loyalty by 5' do
        pet.react_to(:neglected)
        expect(pet.loyalty).to eq(45)
      end

      it 'floors loyalty at 0' do
        pet.update(loyalty: 2)
        pet.react_to(:neglected)
        expect(pet.loyalty).to eq(0)
      end
    end

    context 'when scared' do
      it 'sets mood to scared' do
        pet.react_to(:scared)
        expect(pet.mood).to eq('scared')
      end

      it 'does not change loyalty' do
        pet.react_to(:scared)
        expect(pet.loyalty).to eq(50)
      end
    end
  end

  describe '#idle_action' do
    let(:pet) { described_class.new(owner_id: character.id, name: 'Buddy', species: 'Dog') }

    it 'returns happy actions when mood is happy' do
      pet.mood = 'happy'
      expect(['wags its tail', 'plays excitedly', 'bounds around happily']).to include(pet.idle_action)
    end

    it 'returns content actions when mood is content' do
      pet.mood = 'content'
      expect(['rests quietly', 'watches attentively', 'sits calmly']).to include(pet.idle_action)
    end

    it 'returns hungry actions when mood is hungry' do
      pet.mood = 'hungry'
      expect(['whines softly', 'looks around hopefully', 'paws at the ground']).to include(pet.idle_action)
    end

    it 'returns playful actions when mood is playful' do
      pet.mood = 'playful'
      expect(['chases its tail', 'pounces at shadows', 'rolls around']).to include(pet.idle_action)
    end

    it 'returns default actions for other moods' do
      pet.mood = 'scared'
      expect(['looks around', 'sniffs the air', 'stretches']).to include(pet.idle_action)
    end

    it 'returns default actions for nil mood' do
      pet.mood = nil
      expect(['looks around', 'sniffs the air', 'stretches']).to include(pet.idle_action)
    end
  end

  describe 'associations' do
    let(:pet) { described_class.create(owner_id: character.id, name: 'Buddy', species: 'Dog', current_room_id: room.id) }

    it 'belongs to owner' do
      expect(pet.owner).to eq(character)
    end

    it 'belongs to current_room' do
      expect(pet.current_room).to eq(room)
    end

    it 'allows nil current_room' do
      pet.update(current_room_id: nil)
      expect(pet.current_room).to be_nil
    end
  end
end
