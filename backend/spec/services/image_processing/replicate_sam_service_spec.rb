# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ReplicateSamService do
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

  describe '.segment' do
    it 'returns error hash when image file missing' do
      result = described_class.segment('/nonexistent/image.png', 'furniture')
      expect(result[:success]).to be false
      expect(result[:error]).to include('not found')
    end

    it 'returns error hash when API key missing' do
      allow(AIProviderService).to receive(:api_key_for).with('replicate').and_return(nil)
      Tempfile.create(['test', '.png']) do |f|
        result = described_class.segment(f.path, 'furniture')
        expect(result[:success]).to be false
        expect(result[:error]).to include('not configured')
      end
    end
  end

  describe '.segment_with_samg_fallback' do
    it 'delegates to BattlemapV2::SamSegmentationService and returns mask result' do
      svc_double = instance_double(BattlemapV2::SamSegmentationService)
      allow(BattlemapV2::SamSegmentationService).to receive(:new).and_return(svc_double)
      allow(svc_double).to receive(:segment_object).and_return({
        success: true, mask_path: '/tmp/test_sam_mask.png', coverage: 0.05, model: :samg
      })
      allow(FileUtils).to receive(:cp)
      allow(File).to receive(:exist?).with('/tmp/test_sam_mask.png').and_return(true)
      allow(File).to receive(:exist?).and_call_original

      result = described_class.segment_with_samg_fallback('/tmp/test.png', 'table')
      expect(result[:success]).to be true
    end

    it 'falls back to direct SAM on error' do
      allow(BattlemapV2::SamSegmentationService).to receive(:new).and_raise(StandardError, 'test error')
      allow(described_class).to receive(:segment).and_return({ success: true, mask_path: '/tmp/fallback.png' })

      result = described_class.segment_with_samg_fallback('/tmp/test.png', 'table')
      expect(result[:success]).to be true
    end
  end

  describe 'MODEL' do
    it 'uses lang-segment-anything' do
      expect(described_class::MODEL).to eq('tmappdev/lang-segment-anything')
    end
  end
end
