# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MetaplotEvent do
  # Note: Model may reference columns that don't exist in DB schema
  # Testing what's safely testable

  describe 'associations' do
    it 'belongs to a location' do
      expect(described_class.association_reflections[:location]).not_to be_nil
    end

    it 'belongs to a room' do
      expect(described_class.association_reflections[:room]).not_to be_nil
    end
  end

  describe 'constants' do
    it 'has EVENT_TYPES constant' do
      expect(described_class::EVENT_TYPES).to be_an(Array)
      expect(described_class::EVENT_TYPES).not_to be_empty
    end

    it 'has SIGNIFICANCE constant' do
      expect(described_class::SIGNIFICANCE).to be_an(Array)
      expect(described_class::SIGNIFICANCE).to include('legendary')
    end
  end

  describe '#public?' do
    it 'returns true when is_public is true' do
      event = described_class.new
      event.values[:is_public] = true
      expect(event.public?).to be true
    end

    it 'returns false when is_public is false' do
      event = described_class.new
      event.values[:is_public] = false
      expect(event.public?).to be false
    end
  end
end
