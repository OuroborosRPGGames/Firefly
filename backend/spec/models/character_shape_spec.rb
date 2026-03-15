# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterShape do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      shape = described_class.create(
        character: character,
        shape_name: 'Default',
        description: 'A default shape'
      )
      expect(shape).to be_valid
    end

    it 'requires character_id' do
      shape = described_class.new(shape_name: 'Test')
      expect(shape).not_to be_valid
    end

    it 'requires shape_name' do
      shape = described_class.new(character: character)
      expect(shape).not_to be_valid
    end

    it 'validates max length of shape_name (50 chars)' do
      shape = described_class.new(character: character, shape_name: 'x' * 51)
      expect(shape).not_to be_valid
    end

    it 'validates uniqueness of shape_name per character' do
      described_class.create(character: character, shape_name: 'Unique')
      duplicate = described_class.new(character: character, shape_name: 'Unique')
      expect(duplicate).not_to be_valid
    end

    it 'allows same shape_name for different characters' do
      other_character = create(:character)
      described_class.create(character: character, shape_name: 'Common')
      other_shape = described_class.new(character: other_character, shape_name: 'Common')
      expect(other_shape).to be_valid
    end

    it 'validates shape_type inclusion' do
      valid_types = %w[humanoid animal elemental construct undead plant]
      valid_types.each do |type|
        shape = described_class.new(character: character, shape_name: "#{type} shape", shape_type: type)
        expect(shape).to be_valid, "Expected shape_type '#{type}' to be valid"
      end
    end

    it 'rejects invalid shape_type' do
      shape = described_class.new(character: character, shape_name: 'Test', shape_type: 'invalid')
      expect(shape).not_to be_valid
    end

    it 'validates size inclusion' do
      valid_sizes = %w[tiny small medium large huge gargantuan]
      valid_sizes.each do |size|
        shape = described_class.new(character: character, shape_name: "#{size} shape", size: size)
        expect(shape).to be_valid, "Expected size '#{size}' to be valid"
      end
    end

    it 'rejects invalid size' do
      shape = described_class.new(character: character, shape_name: 'Test', size: 'enormous')
      expect(shape).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to character' do
      shape = create(:character_shape, character: character)
      expect(shape.character).to eq(character)
    end

    it 'has many character_instances' do
      shape = described_class.create(character: character, shape_name: 'Test')
      expect(shape).to respond_to(:character_instances)
    end

    it 'has many appearances' do
      shape = described_class.create(character: character, shape_name: 'Test')
      expect(shape).to respond_to(:appearances)
    end
  end

  describe 'defaults' do
    it 'defaults shape_type to humanoid' do
      shape = described_class.create(character: character, shape_name: 'Test')
      expect(shape.shape_type).to eq('humanoid')
    end

    it 'defaults size to medium' do
      shape = described_class.create(character: character, shape_name: 'Test')
      expect(shape.size).to eq('medium')
    end
  end

  describe 'default shape behavior' do
    it 'makes first shape the default' do
      shape = described_class.create(character: character, shape_name: 'First')
      expect(shape.reload.is_default_shape).to be true
    end

    it 'unsets other defaults when setting new default' do
      first_shape = described_class.create(character: character, shape_name: 'First', is_default_shape: true)
      second_shape = described_class.create(character: character, shape_name: 'Second', is_default_shape: true)

      expect(first_shape.reload.is_default_shape).to be false
      expect(second_shape.is_default_shape).to be true
    end

    it 'only affects shapes of the same character' do
      other_character = create(:character)
      first_shape = described_class.create(character: character, shape_name: 'First', is_default_shape: true)
      other_shape = described_class.create(character: other_character, shape_name: 'Other', is_default_shape: true)

      expect(first_shape.reload.is_default_shape).to be true
      expect(other_shape.is_default_shape).to be true
    end
  end
end
