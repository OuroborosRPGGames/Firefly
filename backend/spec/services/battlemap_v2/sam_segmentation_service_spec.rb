# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattlemapV2::SamSegmentationService do
  let(:image_path) { 'spec/fixtures/test_battlemap.png' }
  let(:output_dir) { Dir.mktmpdir }
  let(:service) { described_class.new(image_path: image_path, output_dir: output_dir) }

  after { FileUtils.rm_rf(output_dir) }

  describe '#segment_object' do
    it 'returns a hash with success and mask_path keys' do
      allow(service).to receive(:call_samg).and_return({ success: true, mask_path: '/tmp/mask.png', coverage: 0.05 })
      result = service.segment_object('wooden table', room_id: 155)
      expect(result).to include(:success, :mask_path)
      expect(result[:success]).to be true
    end

    it 'falls back to lang-sam when samg returns no detection' do
      allow(service).to receive(:call_samg).and_return({ success: true, mask_path: nil, coverage: 0.0 })
      allow(service).to receive(:call_lang_sam).and_return({ success: true, mask_path: '/tmp/fallback.png', coverage: 0.03 })
      allow(service).to receive(:threshold_lang_sam_mask)
      allow(service).to receive(:fill_mask_holes)
      allow(File).to receive(:exist?).with('/tmp/fallback.png').and_return(true)
      result = service.segment_object('wooden table', room_id: 155)
      expect(result[:success]).to be true
      expect(result[:mask_path]).to eq('/tmp/fallback.png')
    end

    it 'rejects masks exceeding coverage threshold' do
      allow(service).to receive(:call_samg).and_return({ success: true, mask_path: '/tmp/big.png', coverage: 0.30 })
      allow(service).to receive(:call_lang_sam).and_return({ success: true, mask_path: '/tmp/big_lang.png', coverage: 0.30 })
      result = service.segment_object('wooden table', room_id: 155, max_coverage: 0.25)
      expect(result[:success]).to be true
      expect(result[:mask_path]).to be_nil
      expect(result[:rejected_coverage]).to be > 0.25
    end
  end

  describe '#segment_generic_list' do
    it 'returns high-conf and low-conf mask sets' do
      allow(service).to receive(:call_sam2grounded).and_return({
        success: true,
        high_conf: [{ label: 'barrel', mask_path: '/tmp/barrel.png', confidence: 0.8 }],
        low_conf: [{ label: 'fork', mask_path: '/tmp/fork.png', confidence: 0.18 }]
      })
      result = service.segment_generic_list(%w[barrel fork chair])
      expect(result[:high_conf]).to be_an(Array)
      expect(result[:low_conf]).to be_an(Array)
    end
  end

  describe '#segment_objects_parallel' do
    it 'runs multiple queries in parallel and returns results hash' do
      allow(service).to receive(:segment_object).and_return({ success: true, mask_path: '/tmp/m.png', coverage: 0.05 })
      results = service.segment_objects_parallel({ 'table' => 'dark wooden table', 'barrel' => 'iron barrel' }, room_id: 155)
      expect(results).to be_a(Hash)
      expect(results.keys).to contain_exactly('table', 'barrel')
    end
  end
end
