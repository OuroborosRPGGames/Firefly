# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattlemapV2::WallDoorService do
  let(:image_path) { 'spec/fixtures/test_battlemap.png' }
  let(:output_dir) { Dir.mktmpdir }
  let(:service) { described_class.new(image_path: image_path, output_dir: output_dir) }

  after { FileUtils.rm_rf(output_dir) }

  describe '#recolor_walls' do
    it 'calls Gemini and returns a colormap path string' do
      allow(service).to receive(:call_gemini_recolor).and_return('/tmp/colormap.png')
      result = service.recolor_walls(has_inner_walls: true)
      expect(result).to be_a(String)
      expect(result).to eq('/tmp/colormap.png')
    end

    it 'returns nil when recoloring fails' do
      allow(service).to receive(:call_gemini_recolor).and_return(nil)
      result = service.recolor_walls(has_inner_walls: false)
      expect(result).to be_nil
    end
  end

  describe '#analyze' do
    it 'returns a hash with connectivity key' do
      allow(service).to receive(:call_gemini_recolor).and_return('/tmp/colormap.png')
      allow(service).to receive(:run_python_analysis).and_return({
        'label_counts' => { 'outer_wall' => 5000, 'outer_door' => 200 },
        'outer_gaps' => [{ 'cx' => 100, 'cy' => 200, 'length' => 80, 'axis' => 1 }],
        'inner_gaps' => [],
        'connectivity' => { 'is_connected' => true, 'num_components' => 1 }
      })
      result = service.analyze(has_inner_walls: false)
      expect(result).to include('connectivity')
      expect(result['connectivity']['is_connected']).to be true
    end

    it 'returns error hash when no colormap produced' do
      allow(service).to receive(:recolor_walls).and_return(nil)
      result = service.analyze(has_inner_walls: false)
      expect(result).to include('error')
    end
  end

  describe '#build_pixel_mask' do
    it 'returns hash with wall_mask_path key' do
      allow(service).to receive(:analyze).and_return({
        'connectivity' => { 'is_connected' => true },
        'outer_gaps' => [], 'inner_gaps' => []
      })
      allow(service).to receive(:run_mask_build).and_return('/tmp/wall_mask.png')
      allow_any_instance_of(Vips::Image).to receive(:width).and_return(800)
      allow_any_instance_of(Vips::Image).to receive(:height).and_return(600)
      allow(Vips::Image).to receive(:new_from_file).and_return(double(width: 800, height: 600))

      result = service.build_pixel_mask(has_inner_walls: false, window_mask_path: nil)
      expect(result).to include(:wall_mask_path)
    end
  end
end
