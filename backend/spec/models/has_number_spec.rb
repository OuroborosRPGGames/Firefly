# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HasNumber do
  let(:character1) { create(:character) }
  let(:character2) { create(:character) }

  describe '.shared?' do
    it 'returns false when no numbers exchanged' do
      expect(described_class.shared?(character1, character2)).to be false
    end

    it 'returns true when char1 has char2 number' do
      described_class.create(character_id: character1.id, target_id: character2.id)
      expect(described_class.shared?(character1, character2)).to be true
    end

    it 'returns true when char2 has char1 number' do
      described_class.create(character_id: character2.id, target_id: character1.id)
      expect(described_class.shared?(character1, character2)).to be true
    end
  end

  describe '.has_number?' do
    it 'returns false when target does not have sender number' do
      expect(described_class.has_number?(character1, character2)).to be false
    end

    it 'returns true when target has sender number' do
      described_class.create(character_id: character1.id, target_id: character2.id)
      expect(described_class.has_number?(character1, character2)).to be true
    end
  end

  describe '.give_number!' do
    it 'creates a record for target having sender number' do
      expect(described_class.give_number!(character1, character2)).to be true
      expect(described_class.has_number?(character2, character1)).to be true
    end

    it 'returns false if number already given' do
      described_class.give_number!(character1, character2)
      expect(described_class.give_number!(character1, character2)).to be false
    end
  end

  describe '.contacts_for' do
    it 'returns characters whose numbers this character has' do
      described_class.create(character_id: character1.id, target_id: character2.id)
      contacts = described_class.contacts_for(character1)
      expect(contacts).to include(character2)
    end

    it 'returns empty array when no contacts' do
      expect(described_class.contacts_for(character1)).to be_empty
    end
  end

  describe '.who_has_number' do
    it 'returns characters who have this character number' do
      described_class.create(character_id: character1.id, target_id: character2.id)
      who_has = described_class.who_has_number(character2)
      expect(who_has).to include(character1)
    end

    it 'returns empty array when no one has number' do
      expect(described_class.who_has_number(character1)).to be_empty
    end
  end
end
