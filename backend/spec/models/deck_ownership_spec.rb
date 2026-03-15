# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DeckOwnership do
  let(:character) { create(:character) }
  let(:deck_pattern) { create(:deck_pattern) }

  describe 'validations' do
    it 'requires deck_pattern_id' do
      ownership = described_class.new(character_id: character.id)
      expect(ownership.valid?).to be false
    end

    it 'requires character_id' do
      ownership = described_class.new(deck_pattern_id: deck_pattern.id)
      expect(ownership.valid?).to be false
    end

    it 'is valid with required fields' do
      ownership = described_class.new(
        deck_pattern_id: deck_pattern.id,
        character_id: character.id
      )
      expect(ownership.valid?).to be true
    end
  end
end
