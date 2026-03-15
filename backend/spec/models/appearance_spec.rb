# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Appearance do
  let(:character_shape) { create(:character_shape) }

  describe 'associations' do
    it 'belongs to character_shape' do
      appearance = Appearance.new(character_shape_id: character_shape.id)
      expect(appearance.character_shape.id).to eq(character_shape.id)
    end
  end

  describe 'validations' do
    it 'requires character_shape_id' do
      appearance = Appearance.new(name: 'Test')
      expect(appearance.valid?).to be false
      expect(appearance.errors[:character_shape_id]).not_to be_empty
    end

    it 'requires name' do
      appearance = Appearance.new(character_shape_id: character_shape.id)
      expect(appearance.valid?).to be false
      expect(appearance.errors[:name]).not_to be_empty
    end

    it 'validates name max length of 100' do
      appearance = Appearance.new(
        character_shape_id: character_shape.id,
        name: 'a' * 101
      )
      expect(appearance.valid?).to be false
      expect(appearance.errors[:name]).not_to be_empty
    end

    it 'validates uniqueness of name within character_shape' do
      Appearance.create(character_shape_id: character_shape.id, name: 'Test Appearance')
      duplicate = Appearance.new(character_shape_id: character_shape.id, name: 'Test Appearance')
      expect(duplicate.valid?).to be false
      # Sequel puts uniqueness errors for composite keys on the combination
      # Check that some error exists related to uniqueness
      expect(duplicate.errors.count).to be > 0
    end

    it 'allows same name for different character_shapes' do
      other_shape = create(:character_shape)
      Appearance.create(character_shape_id: character_shape.id, name: 'Same Name')
      other_appearance = Appearance.new(character_shape_id: other_shape.id, name: 'Same Name')
      expect(other_appearance.valid?).to be true
    end

    it 'is valid with all required fields' do
      appearance = Appearance.new(
        character_shape_id: character_shape.id,
        name: 'Valid Appearance'
      )
      expect(appearance.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'sets is_default to false when nil' do
      appearance = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Test Appearance'
      )
      expect(appearance.is_default).to be false
    end

    it 'preserves is_default when set to true' do
      appearance = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Default Appearance',
        is_default: true
      )
      expect(appearance.is_default).to be true
    end

    it 'preserves is_default when explicitly set to false' do
      appearance = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Not Default',
        is_default: false
      )
      expect(appearance.is_default).to be false
    end
  end

  describe '#activate!' do
    it 'sets is_active to true on the appearance' do
      appearance = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Test Appearance',
        is_active: false
      )
      appearance.activate!
      appearance.refresh

      expect(appearance.is_active).to be true
    end

    it 'deactivates other appearances for the same shape' do
      appearance1 = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Appearance 1',
        is_active: true
      )
      appearance2 = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Appearance 2',
        is_active: false
      )

      appearance2.activate!
      appearance1.refresh

      expect(appearance1.is_active).to be false
      expect(appearance2.is_active).to be true
    end

    it 'does not affect appearances for other character_shapes' do
      other_shape = create(:character_shape)
      other_appearance = Appearance.create(
        character_shape_id: other_shape.id,
        name: 'Other Appearance',
        is_active: true
      )
      appearance = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'My Appearance',
        is_active: false
      )

      appearance.activate!
      other_appearance.refresh

      expect(other_appearance.is_active).to be true
    end
  end

  describe '#disguised?' do
    it 'returns false when is_default is true' do
      appearance = Appearance.new(is_default: true)
      expect(appearance.disguised?).to be false
    end

    it 'returns true when is_default is false' do
      appearance = Appearance.new(is_default: false)
      expect(appearance.disguised?).to be true
    end

    it 'returns true when is_default is nil' do
      appearance = Appearance.new
      expect(appearance.disguised?).to be true
    end
  end

  describe '.default_for' do
    it 'returns the default appearance for a shape' do
      default_appearance = Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Default',
        is_default: true
      )
      Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Disguise',
        is_default: false
      )

      result = Appearance.default_for(character_shape)
      expect(result).to eq(default_appearance)
    end

    it 'returns nil when no default exists' do
      Appearance.create(
        character_shape_id: character_shape.id,
        name: 'Disguise Only',
        is_default: false
      )

      result = Appearance.default_for(character_shape)
      expect(result).to be_nil
    end

    it 'returns nil when shape has no appearances' do
      result = Appearance.default_for(character_shape)
      expect(result).to be_nil
    end
  end
end
