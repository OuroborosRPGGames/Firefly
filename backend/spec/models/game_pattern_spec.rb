# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GamePattern, type: :model do
  let(:character) { create(:character) }

  describe 'validations' do
    it 'requires name' do
      pattern = GamePattern.new(created_by: character.id)
      expect(pattern.valid?).to be false
      expect(pattern.errors[:name]).to include('is not present')
    end

    it 'requires created_by' do
      pattern = GamePattern.new(name: 'Test Game')
      expect(pattern.valid?).to be false
      expect(pattern.errors[:created_by]).to include('is not present')
    end

    it 'validates share_type inclusion' do
      pattern = GamePattern.new(name: 'Test', created_by: character.id, share_type: 'invalid')
      expect(pattern.valid?).to be false
    end

    it 'is valid with required fields' do
      pattern = GamePattern.new(name: 'Bar Darts', created_by: character.id)
      expect(pattern.valid?).to be true
    end
  end

  describe 'associations' do
    it 'belongs to creator' do
      pattern = GamePattern.create(name: 'Test', created_by: character.id)
      expect(pattern.creator).to eq(character)
    end
  end

  describe '#display_name' do
    it 'returns name' do
      pattern = GamePattern.new(name: 'Bar Darts')
      expect(pattern.display_name).to eq('Bar Darts')
    end
  end

  describe '#scoring?' do
    it 'returns true when has_scoring is true' do
      pattern = GamePattern.new(has_scoring: true)
      expect(pattern.scoring?).to be true
    end

    it 'returns false when has_scoring is false' do
      pattern = GamePattern.new(has_scoring: false)
      expect(pattern.scoring?).to be false
    end

    it 'returns false when has_scoring is nil' do
      pattern = GamePattern.new
      expect(pattern.scoring?).to be false
    end
  end

  describe '#public?' do
    it 'returns true when share_type is public' do
      pattern = GamePattern.new(share_type: 'public')
      expect(pattern.public?).to be true
    end

    it 'returns false for other share_types' do
      pattern = GamePattern.new(share_type: 'private')
      expect(pattern.public?).to be false
    end
  end

  describe '#purchasable?' do
    it 'returns true when share_type is purchasable' do
      pattern = GamePattern.new(share_type: 'purchasable')
      expect(pattern.purchasable?).to be true
    end

    it 'returns false for other share_types' do
      pattern = GamePattern.new(share_type: 'public')
      expect(pattern.purchasable?).to be false
    end
  end
end
