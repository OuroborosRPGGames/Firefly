# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ContentConsent do
  let(:character) { create(:character) }
  let(:content_restriction) { create(:content_restriction) }

  describe 'validations' do
    it 'requires character_id' do
      consent = described_class.new(content_restriction_id: content_restriction.id)
      expect(consent.valid?).to be false
    end

    it 'requires content_restriction_id' do
      consent = described_class.new(character_id: character.id)
      expect(consent.valid?).to be false
    end

    it 'is valid with required fields' do
      consent = described_class.new(
        character_id: character.id,
        content_restriction_id: content_restriction.id
      )
      expect(consent.valid?).to be true
    end

    it 'enforces uniqueness of character and content_restriction' do
      described_class.create(character_id: character.id, content_restriction_id: content_restriction.id)
      duplicate = described_class.new(character_id: character.id, content_restriction_id: content_restriction.id)
      expect(duplicate.valid?).to be false
    end
  end

  describe '#consent!' do
    it 'updates consented to true' do
      consent = described_class.create(character_id: character.id, content_restriction_id: content_restriction.id)
      consent.consent!
      consent.refresh
      expect(consent.consented).to be true
      expect(consent.consented_at).not_to be_nil
    end
  end

  describe '#revoke!' do
    it 'updates consented to false' do
      consent = described_class.create(character_id: character.id, content_restriction_id: content_restriction.id, consented: true)
      consent.revoke!
      consent.refresh
      expect(consent.consented).to be false
    end
  end

  describe '#consenting?' do
    it 'returns true when consented is true' do
      consent = described_class.new(consented: true)
      expect(consent.consenting?).to be true
    end

    it 'returns false when consented is false' do
      consent = described_class.new(consented: false)
      expect(consent.consenting?).to be false
    end
  end
end
