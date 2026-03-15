# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ReplicateDepthService do
  describe '.available?' do
    it 'returns false when API key is not configured' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      expect(described_class.available?).to be false
    end

    it 'returns true when API key is configured' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return('test-key')
      expect(described_class.available?).to be true
    end
  end

  describe '.estimate' do
    it 'returns error hash when image file missing' do
      result = described_class.estimate('/nonexistent/image.png')
      expect(result[:success]).to be false
      expect(result[:error]).to include('not found')
    end

    it 'returns error hash when API key missing' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      Tempfile.create(['test', '.png']) do |f|
        result = described_class.estimate(f.path)
        expect(result[:success]).to be false
        expect(result[:error]).to include('not configured')
      end
    end
  end
end
