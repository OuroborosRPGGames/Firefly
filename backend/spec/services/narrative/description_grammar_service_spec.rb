# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DescriptionGrammarService do
  describe '.auto_capitalize' do
    it 'capitalizes the first letter of text' do
      expect(described_class.auto_capitalize('she has blue eyes')).to eq('She has blue eyes')
    end

    it 'capitalizes after periods' do
      input = 'she has blue eyes. they sparkle'
      expected = 'She has blue eyes. They sparkle'
      expect(described_class.auto_capitalize(input)).to eq(expected)
    end

    it 'capitalizes after exclamation marks' do
      input = 'look at her eyes! they are amazing'
      expected = 'Look at her eyes! They are amazing'
      expect(described_class.auto_capitalize(input)).to eq(expected)
    end

    it 'capitalizes after question marks' do
      input = 'are those her eyes? they look different'
      expected = 'Are those her eyes? They look different'
      expect(described_class.auto_capitalize(input)).to eq(expected)
    end

    it 'capitalizes after newlines' do
      input = "she has blue eyes.\nthey sparkle in the light"
      expected = "She has blue eyes.\nThey sparkle in the light"
      expect(described_class.auto_capitalize(input)).to eq(expected)
    end

    it 'preserves leading whitespace after newlines' do
      input = "she has blue eyes.\n  they sparkle"
      expected = "She has blue eyes.\n  They sparkle"
      expect(described_class.auto_capitalize(input)).to eq(expected)
    end

    it 'handles multiple sentences' do
      input = 'one sentence. two sentences. three sentences'
      expected = 'One sentence. Two sentences. Three sentences'
      expect(described_class.auto_capitalize(input)).to eq(expected)
    end

    it 'returns nil for nil input' do
      expect(described_class.auto_capitalize(nil)).to be_nil
    end

    it 'returns empty string for empty input' do
      expect(described_class.auto_capitalize('')).to eq('')
    end

    it 'does not alter already capitalized text' do
      input = 'She has blue eyes. They sparkle.'
      expect(described_class.auto_capitalize(input)).to eq(input)
    end
  end
end
