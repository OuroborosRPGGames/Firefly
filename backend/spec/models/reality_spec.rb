# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Reality do
  let(:reality) { create(:reality) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(reality).to be_valid
    end

    it 'requires name' do
      reality = build(:reality, name: nil)
      expect(reality).not_to be_valid
    end

    it 'validates uniqueness of name' do
      create(:reality, name: 'Primary Reality')
      duplicate = build(:reality, name: 'Primary Reality')
      expect(duplicate).not_to be_valid
    end

    it 'validates max length of name' do
      reality = build(:reality, name: 'x' * 101)
      expect(reality).not_to be_valid
    end

    it 'validates reality_type inclusion' do
      reality = build(:reality, reality_type: 'invalid')
      expect(reality).not_to be_valid
    end

    it 'accepts valid reality types' do
      %w[primary flashback alternate dream vision memory].each do |type|
        reality = build(:reality, reality_type: type)
        expect(reality).to be_valid
      end
    end

    it 'accepts integer time_offset' do
      reality = build(:reality, time_offset: 100)
      expect(reality).to be_valid
    end
  end

  describe 'associations' do
    it 'has many character_instances' do
      expect(reality).to respond_to(:character_instances)
    end

    it 'has many messages' do
      expect(reality).to respond_to(:messages)
    end
  end

  describe '#active_characters' do
    it 'responds to active_characters' do
      expect(reality).to respond_to(:active_characters)
    end
  end

  describe '.primary' do
    let!(:primary_reality) { create(:reality, :primary) }
    let!(:flashback_reality) { create(:reality, :flashback) }

    it 'returns the primary reality' do
      expect(described_class.primary).to eq(primary_reality)
    end
  end

  describe '#is_primary?' do
    it 'returns true for primary reality type' do
      reality = create(:reality, :primary)
      expect(reality.is_primary?).to be true
    end

    it 'returns false for non-primary reality types' do
      reality = create(:reality, :flashback)
      expect(reality.is_primary?).to be false
    end
  end
end
